// Native ads.
//
// Unlike a banner, the layout is ours to build: AdMob hands over the assets and
// expects the app to arrange them, either with one of the templates this
// package ships (GMAKNativeAdTemplate) or with a factory the app registered
// (doc/design.md §8-2).
//
// The Dart→native "no child views" limit does not apply to what happens here:
// it constrains the reconciler, and this is all on the native side of the
// boundary — `NativeAdView` is a plain `UIView` subclass (§8-1).

import Foundation
import GoogleMobileAds
import UIKit

/// Builds the view for a native ad.
///
/// Apps implement this to take over the layout completely; the Dart side
/// selects an implementation by the `factoryId` it was registered under. The
/// iOS twin of Android's `NativeAdFactory` interface, and the same contract as
/// `google_mobile_ads`' `NativeAdFactory` on iOS.
@objc public protocol GMAKNativeAdFactory {
  /// Returns a view rendering [nativeAd].
  ///
  /// Assign every asset view you populate to the matching `NativeAdView`
  /// property before returning — the SDK attaches click handling and
  /// viewability measurement when the view is bound, and an unassigned asset
  /// records neither. Do **not** set `nativeAd` yourself; the plugin does that
  /// after this returns.
  ///
  /// [customOptions] is whatever the Dart side passed as `customOptions`.
  func createNativeAdView(
    nativeAd: NativeAd,
    customOptions: [String: Any]
  ) -> NativeAdView?
}

/// The registry of app-provided factories.
///
/// Registration happens from the app's own Swift (there is no Dart-side hook),
/// which is why this is public API rather than an implementation detail.
@objc public final class GMAKMobileAds: NSObject {

  private static var factories: [String: GMAKNativeAdFactory] = [:]

  /// Registers [factory] under [factoryId].
  ///
  /// Call this before mounting a `NativeAd` that names the same id — usually
  /// from `application(_:didFinishLaunchingWithOptions:)`. Registering the same
  /// id twice replaces the earlier factory.
  ///
  /// Mirrors Android's
  /// `GoogleMobileAdsKitPlugin.registerNativeAdFactory(context, id, factory)`,
  /// minus the context iOS has no use for (`doc/design.md` §8-5).
  @objc public static func registerNativeAdFactory(
    _ factoryId: String,
    factory: GMAKNativeAdFactory
  ) {
    factories[factoryId] = factory
  }

  /// Removes the factory registered under [factoryId], returning whether one
  /// was there.
  @discardableResult
  @objc public static func unregisterNativeAdFactory(_ factoryId: String) -> Bool {
    factories.removeValue(forKey: factoryId) != nil
  }

  static func factory(_ factoryId: String) -> GMAKNativeAdFactory? {
    factories[factoryId]
  }
}

/// Creates a native ad's container and starts the request.
///
/// Same view-id handover as the banner: the container is queued synchronously
/// so the `createView` that follows can take it (`doc/design.md` §7-5).
@_cdecl("GMAKNativeAdCreate")
public func GMAKNativeAdCreate(
  _ token: Int64,
  _ viewId: Int64,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJsonPtr: UnsafePointer<CChar>?,
  _ optionsJsonPtr: UnsafePointer<CChar>?
) {
  guard let adUnitIdPtr = adUnitIdPtr else { return }
  let adUnitId = String(cString: adUnitIdPtr)
  let requestJson = requestJsonPtr.map { String(cString: $0) } ?? "{}"
  let optionsJson = optionsJsonPtr.map { String(cString: $0) } ?? "{}"
  let options = gmakDecodeJSON(optionsJson)

  // Validate before registering anything. A container queued here is popped by
  // the `createView` that follows, so bailing out afterwards would leave a
  // stale entry in the queue and put every later native ad's handover off by
  // one — each ad rendering into the previous ad's view.
  let factoryId = options["factoryId"] as? String
  let hasTemplate = options["templateStyle"] is [String: Any]

  if let factoryId = factoryId, GMAKMobileAds.factory(factoryId) == nil {
    // Fail now rather than after a round trip: the request would succeed and
    // then have nothing to render it (`doc/design.md` §8-5).
    gmakFireEvent(
      token: token,
      status: .failedToLoad,
      payload: gmakFailurePayload(
        "No NativeAdFactory registered for '\(factoryId)'. Call "
          + "GMAKMobileAds.registerNativeAdFactory(_:factory:) before mounting the ad."))
    return
  }
  if factoryId == nil && !hasTemplate {
    // The Dart side asserts this, but assertions are gone in release — and
    // silently rendering the small template would hide the mistake.
    gmakFireEvent(
      token: token,
      status: .failedToLoad,
      payload: gmakFailurePayload(
        "Provide either nativeTemplateStyle or factoryId on NativeAd."))
    return
  }

  let entry = GMAKStore.shared.registerNativeAd(viewId: viewId, token: token)

  DispatchQueue.main.async {
    let delegate = GMAKNativeAdLoaderDelegate(
      token: token,
      viewId: viewId,
      options: options)

    let loader = AdLoader(
      adUnitID: adUnitId,
      rootViewController: gmakRootViewController(),
      adTypes: [.native],
      options: gmakNativeAdLoaderOptions(from: options))
    loader.delegate = delegate

    entry.loader = loader
    entry.delegate = delegate

    loader.load(gmakBuildRequest(from: requestJson))
  }
}

/// Destroys the native ad mounted at [viewId].
@_cdecl("GMAKNativeAdDispose")
public func GMAKNativeAdDispose(_ viewId: Int64) {
  DispatchQueue.main.async {
    GMAKStore.shared.disposeNativeAd(viewId: viewId)
  }
}

/// Translates the Dart `NativeAdOptions` blob into SDK loader options.
///
/// The Dart enums were ordered to match the iOS ones, so the indices pass
/// straight through — unlike Android, where `AdChoicesPlacement` needed
/// remapping (`doc/design.md` §8-3).
private func gmakNativeAdLoaderOptions(from options: [String: Any]) -> [GADAdLoaderOptions] {
  guard let native = options["nativeAdOptions"] as? [String: Any] else { return [] }
  var result: [GADAdLoaderOptions] = []

  if let placement = native["adChoicesPlacement"] as? Int,
    let position = AdChoicesPosition(rawValue: placement)
  {
    let viewOptions = NativeAdViewAdOptions()
    viewOptions.preferredAdChoicesPosition = position
    result.append(viewOptions)
  }

  if let ratio = native["mediaAspectRatio"] as? Int,
    let aspect = MediaAspectRatio(rawValue: ratio)
  {
    let mediaOptions = NativeAdMediaAdLoaderOptions()
    mediaOptions.mediaAspectRatio = aspect
    result.append(mediaOptions)
  }

  if let urlsOnly = native["shouldReturnUrlsForImageAssets"] as? Bool, urlsOnly {
    let imageOptions = NativeAdImageAdLoaderOptions()
    imageOptions.isImageLoadingDisabled = true
    result.append(imageOptions)
  }

  if let video = native["videoOptions"] as? [String: Any] {
    let videoOptions = VideoOptions()
    if let muted = video["startMuted"] as? Bool {
      videoOptions.shouldStartMuted = muted
    }
    if let custom = video["customControlsRequested"] as? Bool {
      videoOptions.areCustomControlsRequested = custom
    }
    if let expand = video["clickToExpandRequested"] as? Bool {
      videoOptions.isClickToExpandRequested = expand
    }
    result.append(videoOptions)
  }

  return result
}

/// Decodes one of the JSON blobs the Dart side sends.
///
/// A malformed body decodes to empty rather than throwing: this runs on the
/// FFI call stack, where an exception would cross the boundary.
func gmakDecodeJSON(_ json: String) -> [String: Any] {
  guard let data = json.data(using: .utf8),
    let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  else {
    return [:]
  }
  return map
}

/// Receives the loaded ad and builds its view.
///
/// Retained by the store for the ad's lifetime: `AdLoader` holds its delegate
/// weakly, so otherwise it would deallocate before the response arrives.
private final class GMAKNativeAdLoaderDelegate: NSObject, NativeAdLoaderDelegate,
  NativeAdDelegate
{
  private let token: Int64
  private let viewId: Int64
  private let options: [String: Any]

  init(token: Int64, viewId: Int64, options: [String: Any]) {
    self.token = token
    self.viewId = viewId
    self.options = options
  }

  func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
    // The element may have unmounted while the request was in flight, in which
    // case the entry is gone and the ad is simply dropped.
    guard let entry = GMAKStore.shared.nativeAd(viewId) else { return }

    nativeAd.delegate = self
    nativeAd.rootViewController = gmakRootViewController()
    nativeAd.paidEventHandler = { [token] value in
      gmakFireEvent(token: token, status: .paidEvent, payload: gmakPaidEventPayload(value))
    }

    guard let adView = buildView(for: nativeAd) else {
      gmakFireEvent(
        token: token,
        status: .failedToLoad,
        payload: gmakFailurePayload("The NativeAdFactory returned no view."))
      return
    }

    entry.nativeAd = nativeAd
    entry.adView = adView
    // Sized and laid out *before* it enters the window. The SDK measures the
    // media view the moment the ad becomes visible, and a view that is added
    // first and laid out on the next pass is measured at 0x0 in between —
    // "media view size has been detected to be 0x0", and the native ad
    // validator fails the ad even though the layout is right one frame later.
    // Only an ad that is on screen when it loads hits this, which is exactly
    // the common case. The container already has its size: Yoga applied the
    // reserved height at mount, well before the request came back.
    adView.frame = entry.container.bounds
    adView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    adView.layoutIfNeeded()
    entry.container.addSubview(adView)

    gmakFireEvent(
      token: token,
      status: .loaded,
      payload: gmakResponseInfoPayload(nativeAd.responseInfo))
  }

  func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
    gmakFireEvent(token: token, status: .failedToLoad, payload: gmakErrorPayload(error))
  }

  /// Renders with the app's factory when one was named, else with a template.
  ///
  /// `nativeAd` is bound here rather than in the factory, so that a factory
  /// implementation cannot forget it and silently lose click tracking.
  private func buildView(for nativeAd: NativeAd) -> NativeAdView? {
    if let factoryId = options["factoryId"] as? String {
      guard let factory = GMAKMobileAds.factory(factoryId) else { return nil }
      let custom = options["customOptions"] as? [String: Any] ?? [:]
      guard
        let view = factory.createNativeAdView(nativeAd: nativeAd, customOptions: custom)
      else {
        return nil
      }
      view.nativeAd = nativeAd
      return view
    }

    let style = options["templateStyle"] as? [String: Any] ?? [:]
    return GMAKNativeAdTemplate.render(ad: nativeAd, style: style)
  }

  // MARK: - NativeAdDelegate

  func nativeAdDidRecordImpression(_ nativeAd: NativeAd) {
    gmakFireEvent(token: token, status: .impression)
  }

  func nativeAdDidRecordClick(_ nativeAd: NativeAd) {
    gmakFireEvent(token: token, status: .clicked)
  }

  /// A tap is about to cover the app — the Dart listener's `onAdOpened`.
  func nativeAdWillPresentScreen(_ nativeAd: NativeAd) {
    gmakFireEvent(token: token, status: .opened)
  }

  /// Reported on *did* dismiss so the listener runs once the app is back.
  func nativeAdDidDismissScreen(_ nativeAd: NativeAd) {
    gmakFireEvent(token: token, status: .closed)
  }
}
