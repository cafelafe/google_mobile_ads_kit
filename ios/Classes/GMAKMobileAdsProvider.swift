// The iOS plugin view provider — the half of the plugin that hands the
// reconciler a native view.
//
// Android implements the `DNAndroidPluginProvider` interface; iOS has no such
// protocol. Instead the engine exports four C entry points that this file
// resolves at runtime and calls:
//
//   DNRegisterPluginProvider(createView, handleMutation)  registration
//   DNViewTypeClaim(key) -> Int32                         the ViewType.claim twin
//   DNViewRegistryGetView(viewId) -> Int64                viewId -> UIView
//
// Every one was confirmed present in dartnative_ios.xcframework with `nm`
// before this file was written (doc/design.md §12-1).
//
// The symbols are resolved with dlsym rather than by importing dartnative_ios:
// the engine framework loads plugins, so a plugin pod that linked it back would
// be a circular CocoaPods dependency. Every official view plugin does this.

import Foundation
import GoogleMobileAds
import UIKit

// MARK: - View types

/// The reconciler's view type for banners, or -1 when the engine is absent.
///
/// The same key the Dart side passes to `ViewType.claim`; claiming is
/// idempotent per key, so both sides land on the same number without either
/// hard-coding one.
let gmakBannerViewType: Int32 = gmakClaimViewType("google_mobile_ads_kit/banner")

/// The reconciler's view type for native ads. See [gmakBannerViewType].
let gmakNativeAdViewType: Int32 = gmakClaimViewType("google_mobile_ads_kit/native")

private func gmakClaimViewType(_ key: String) -> Int32 {
  typealias ClaimFn = @convention(c) (UnsafePointer<CChar>) -> Int32
  guard let symbol = dlsym(dlopen(nil, RTLD_NOLOAD), "DNViewTypeClaim") else {
    return -1
  }
  return key.withCString { unsafeBitCast(symbol, to: ClaimFn.self)($0) }
}

// MARK: - Container

/// Holds one ad view and keeps it at the size Yoga gave the container.
///
/// The reconciler needs a view the moment the element mounts, but an ad only
/// exists once the network request comes back, so what gets mounted is this
/// empty container and the ad view is added later.
final class GMAKAdContainer: UIView {
  /// Sizes the ad to the ad's own dimensions rather than the container's.
  ///
  /// AdMob forbids scaling or cropping a creative, and the SDK returns a fixed
  /// size even for an adaptive request, so a banner is centred at its natural
  /// size and any slack is left as margin. Native ads set this to nil and fill
  /// the container instead — their layout is ours to decide, and the templates
  /// are written to stretch.
  var adSize: CGSize?

  /// Called with the new width each time Yoga lays the container out at a
  /// width it has not seen before.
  ///
  /// Native ads use this to hand Dart the real width, from which it corrects
  /// the aspect ratio it guessed from `LayoutBuilder` — that reports the screen
  /// width, not the slot's, so an ad inside padding is reserved too short
  /// (`doc/design.md` §8-6). Firing only on a *change* is what keeps the
  /// correction from looping: the corrected ratio leaves the width alone.
  var onWidthChange: ((CGFloat) -> Void)?
  private var reportedWidth: CGFloat = -1

  override func layoutSubviews() {
    super.layoutSubviews()
    if let ad = subviews.first {
      if let size = adSize {
        ad.frame = CGRect(
          x: ((bounds.width - size.width) / 2).rounded(),
          y: ((bounds.height - size.height) / 2).rounded(),
          width: size.width,
          height: size.height)
      } else {
        ad.frame = bounds
      }
    }
    if bounds.width > 0, bounds.width != reportedWidth {
      reportedWidth = bounds.width
      onWidthChange?(bounds.width)
    }
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    setNeedsLayout()
  }
}

// MARK: - Provider callbacks

/// Builds the container for a view type this plugin owns.
///
/// ⚠️ Returns 0 for anything else. The registry walks every registered provider
/// and takes the first non-zero result, so returning a placeholder here would
/// hijack every other plugin's views — and this plugin's own second view type
/// (`doc/design.md` §5-1). The bug stays invisible until a second view type
/// exists, which is exactly the situation here.
private let gmakCreateView: @convention(c) (Int32) -> Int64 = { typeIndex in
  // A claim that failed leaves both types at -1, which would otherwise make
  // every banner and native ad answer to the same index — and to each other's.
  guard typeIndex >= 0 else { return 0 }

  switch typeIndex {
  case gmakBannerViewType:
    return GMAKStore.shared.takeContainer(kind: .banner)
  case gmakNativeAdViewType:
    return GMAKStore.shared.takeContainer(kind: .nativeAd)
  default:
    return 0
  }
}

/// Receives plugin mutations for a view.
///
/// Neither format sends any: a banner's size travels through Yoga as an aspect
/// ratio, and a native ad's style is fixed at request time because restyling a
/// live ad would mean re-registering its asset views with the SDK. The hook is
/// still required — the engine broadcasts mutations to *every* provider, so
/// this must ignore what it does not recognise rather than assume ownership.
private let gmakHandleMutation:
  @convention(c) (Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void = {
    _, _, _, _ in
  }

/// Registers the provider with the engine.
///
/// Called from Dart's `loadSymbols()`, not automatically: Android gets a
/// registration hook from the generated plugin registrant, iOS has no
/// equivalent and the pod is otherwise never entered.
@_cdecl("GMAKRegisterProvider")
public func GMAKRegisterProvider() {
  guard let symbol = dlsym(dlopen(nil, RTLD_NOLOAD), "DNRegisterPluginProvider")
  else {
    // Only reachable if the app is built without the engine framework, in
    // which case there is no reconciler to serve and the full-screen formats
    // still work.
    NSLog("[google_mobile_ads_kit] DNRegisterPluginProvider missing — is dartnative_ios linked?")
    return
  }
  typealias RegisterFn = @convention(c) (Int64, Int64) -> Void
  unsafeBitCast(symbol, to: RegisterFn.self)(
    unsafeBitCast(gmakCreateView, to: Int64.self),
    unsafeBitCast(gmakHandleMutation, to: Int64.self))
}

// MARK: - View lookup

/// Returns the mounted view the engine filed under [viewId].
///
/// Unused by the ad formats — both keep their own container references — but
/// kept because it is the only way to reach a view the engine owns, and any
/// future mutation handler needs it.
func gmakViewFor(_ viewId: Int64) -> UIView? {
  typealias GetViewFn = @convention(c) (Int64) -> Int64
  guard let symbol = dlsym(dlopen(nil, RTLD_NOLOAD), "DNViewRegistryGetView")
  else {
    return nil
  }
  let pointer = unsafeBitCast(symbol, to: GetViewFn.self)(viewId)
  guard pointer != 0, let raw = UnsafeRawPointer(bitPattern: Int(pointer))
  else {
    return nil
  }
  return Unmanaged<UIView>.fromOpaque(raw).takeUnretainedValue()
}
