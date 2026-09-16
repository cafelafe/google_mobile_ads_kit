// Ownership of the view-backed ad formats: banners and native ads.
//
// The reconciler asks for a view synchronously and tells us nothing about
// which ad it is for — `createView` receives only a view type. So the Dart
// element calls `GMAKBannerCreate` / `GMAKNativeAdCreate` *first*, which
// files a container under the view id and queues it; the `createView` that
// immediately follows pops that queue (doc/design.md §7-5).
//
// Everything here is main-thread confined. Dart runs on the platform main
// thread and the GMA iOS delegates fire there too, so no locking is needed —
// but that invariant is why the few asynchronous paths hop back explicitly.

import Foundation
import GoogleMobileAds
import UIKit

/// Which format a queued container belongs to.
enum GMAKAdKind {
  case banner
  case nativeAd
}

/// The live banners and native ads, keyed by the reconciler's view id.
final class GMAKStore {
  static let shared = GMAKStore()

  private init() {}

  /// One mounted banner and the SDK objects behind it.
  final class BannerEntry {
    let container: GMAKAdContainer
    let token: Int64
    var bannerView: BannerView?
    /// Retains the delegate, which the SDK holds weakly.
    var delegate: NSObject?

    init(container: GMAKAdContainer, token: Int64) {
      self.container = container
      self.token = token
    }
  }

  /// One mounted native ad and the SDK objects behind it.
  final class NativeAdEntry {
    let container: GMAKAdContainer
    let token: Int64
    /// Retained for the ad's lifetime: `AdLoader` holds its delegate weakly.
    var loader: AdLoader?
    var delegate: NSObject?
    var nativeAd: NativeAd?
    var adView: NativeAdView?

    init(container: GMAKAdContainer, token: Int64) {
      self.container = container
      self.token = token
    }
  }

  private var banners: [Int64: BannerEntry] = [:]
  private var nativeAds: [Int64: NativeAdEntry] = [:]

  /// Containers built but not yet claimed by `createView`.
  ///
  /// A queue rather than a single slot because two elements can mount in one
  /// frame; `createView` always follows its own create call in order.
  private var pendingBanners: [GMAKAdContainer] = []
  private var pendingNativeAds: [GMAKAdContainer] = []

  // MARK: - Container handover

  /// Files a container under [viewId] and queues it for `createView`.
  func registerBanner(viewId: Int64, token: Int64, adSize: CGSize) -> BannerEntry {
    let container = GMAKAdContainer()
    container.adSize = adSize
    let entry = BannerEntry(container: container, token: token)
    banners[viewId] = entry
    pendingBanners.append(container)
    return entry
  }

  /// Files a native ad container under [viewId]. See [registerBanner].
  func registerNativeAd(viewId: Int64, token: Int64) -> NativeAdEntry {
    let container = GMAKAdContainer()
    // nil means "fill the container": a native ad's layout is ours, unlike a
    // banner creative, which must keep its exact size.
    container.adSize = nil
    // Dart corrects its reserved height from this; see GMAKAdContainer.
    container.onWidthChange = { width in
      gmakFireEvent(token: token, status: .laidOut, payload: ["width": Double(width)])
    }
    let entry = NativeAdEntry(container: container, token: token)
    nativeAds[viewId] = entry
    pendingNativeAds.append(container)
    return entry
  }

  /// Pops the container prepared for the next `createView` of [kind].
  ///
  /// Returns a retained opaque pointer, which is what the engine's `createView`
  /// contract expects: the registry takes ownership of that +1 reference.
  /// Returns 0 when the queue is empty — that would mean a view was requested
  /// without a create call, so there is nothing to hand over.
  func takeContainer(kind: GMAKAdKind) -> Int64 {
    let container: GMAKAdContainer?
    switch kind {
    case .banner:
      container = pendingBanners.isEmpty ? nil : pendingBanners.removeFirst()
    case .nativeAd:
      container = pendingNativeAds.isEmpty ? nil : pendingNativeAds.removeFirst()
    }
    guard let view = container else { return 0 }
    return Int64(Int(bitPattern: Unmanaged.passRetained(view).toOpaque()))
  }

  // MARK: - Lookup

  func banner(_ viewId: Int64) -> BannerEntry? { banners[viewId] }
  func nativeAd(_ viewId: Int64) -> NativeAdEntry? { nativeAds[viewId] }

  // MARK: - Teardown

  /// Destroys the banner mounted at [viewId].
  ///
  /// Only ever reached from an explicit Dart-side dispose, which is deferred a
  /// microtask and skipped when the element remounted — so a recycled list cell
  /// does not re-request an ad (`doc/design.md` §7-4).
  func disposeBanner(viewId: Int64) {
    guard let entry = banners.removeValue(forKey: viewId) else { return }
    tearDown(entry)
  }

  /// Destroys the native ad mounted at [viewId]. See [disposeBanner].
  func disposeNativeAd(viewId: Int64) {
    guard let entry = nativeAds.removeValue(forKey: viewId) else { return }
    tearDown(entry)
  }

  private func tearDown(_ entry: BannerEntry) {
    entry.bannerView?.delegate = nil
    entry.bannerView?.removeFromSuperview()
    entry.bannerView = nil
    entry.delegate = nil
  }

  private func tearDown(_ entry: NativeAdEntry) {
    entry.loader?.delegate = nil
    entry.loader = nil
    entry.adView?.nativeAd = nil
    entry.adView?.removeFromSuperview()
    entry.adView = nil
    entry.nativeAd = nil
    entry.delegate = nil
  }

  /// Releases every live ad, for a hot restart.
  ///
  /// The Dart objects that owned these died with the old isolate, so nothing
  /// will ever dispose them individually. Called from the dispatcher-slot reset
  /// (`doc/design.md` §5-2).
  func releaseAll() {
    for entry in banners.values { tearDown(entry) }
    for entry in nativeAds.values { tearDown(entry) }
    banners.removeAll()
    nativeAds.removeAll()
    pendingBanners.removeAll()
    pendingNativeAds.removeAll()
  }
}
