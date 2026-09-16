// Banner ads.
//
// A banner is one `BannerView` that the SDK draws entirely on its own, so the
// work here is plumbing: hand the reconciler a container it can mount now, load
// into it, and forward the events. Nothing lays out ad content — that is what
// separates a banner from a native ad (doc/design.md §8).
//
// The iOS spelling differs from Android's: `BannerView` rather than `AdView`,
// assigned properties rather than setters, and a `rootViewController` the SDK
// needs in order to present the tap-through.

import Foundation
import GoogleMobileAds
import UIKit

/// Creates a banner's container and starts the request.
///
/// Called from the Dart element's `mount`, before the reconciler asks the
/// provider for a view — the container has to be queued before `createView`
/// runs, which is why the queueing part is synchronous (`doc/design.md` §7-5).
@_cdecl("GMAKBannerCreate")
public func GMAKBannerCreate(
  _ token: Int64,
  _ viewId: Int64,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJsonPtr: UnsafePointer<CChar>?,
  _ widthDp: Int32,
  _ heightDp: Int32
) {
  guard let adUnitIdPtr = adUnitIdPtr else { return }
  let adUnitId = String(cString: adUnitIdPtr)
  let requestJson = requestJsonPtr.map { String(cString: $0) } ?? "{}"

  let adSize = gmakResolveAdSize(width: Int(widthDp), height: Int(heightDp))
  let entry = GMAKStore.shared.registerBanner(
    viewId: viewId,
    token: token,
    adSize: adSize.size)

  // The view hierarchy work is deferred so the container is queued before
  // anything can fail, but it stays on the main thread — the SDK requires it,
  // and so does the reconciler.
  DispatchQueue.main.async {
    let bannerView = BannerView(adSize: adSize)
    bannerView.adUnitID = adUnitId
    // Without a root view controller the SDK cannot present the click-through
    // and refuses to load.
    bannerView.rootViewController = gmakRootViewController()

    let delegate = GMAKBannerAdDelegate(token: token)
    bannerView.delegate = delegate
    bannerView.paidEventHandler = { value in
      gmakFireEvent(token: token, status: .paidEvent, payload: gmakPaidEventPayload(value))
    }

    entry.bannerView = bannerView
    entry.delegate = delegate
    entry.container.addSubview(bannerView)

    bannerView.load(gmakBuildRequest(from: requestJson))
  }
}

/// Destroys the banner mounted at [viewId].
@_cdecl("GMAKBannerDispose")
public func GMAKBannerDispose(_ viewId: Int64) {
  DispatchQueue.main.async {
    GMAKStore.shared.disposeBanner(viewId: viewId)
  }
}

/// Returns the Google-optimized anchored banner height for [widthDp], or 0.
///
/// A pure calculation with no network round trip, so Dart calls it
/// synchronously while laying out (`doc/design.md` §7-3). The iOS twin of
/// Android's `getLargeAnchoredAdaptiveBannerAdSize`.
@_cdecl("GMAKAdaptiveBannerHeight")
public func GMAKAdaptiveBannerHeight(_ widthDp: Int32) -> Int32 {
  let size = largeAnchoredAdaptiveBanner(width: CGFloat(widthDp))
  // An invalid width yields AdSizeInvalid, whose height is 0 — which is also
  // what Dart reads as "no size available", so it needs no special case.
  return Int32(size.size.height.rounded())
}

/// Maps a requested size onto the SDK's own constant where one matches.
///
/// A freshly built 320x50 is *not* the same request as `AdSizeBanner`: AdMob
/// reads a custom size as a flexible slot and may fill it with a differently
/// shaped creative (on Android a 320x50 request came back 468x60). Passing the
/// canonical constant asks for the standard slot, which is what the Dart-side
/// `AdSize.banner` means. Anything genuinely custom — an adaptive height, or a
/// size the caller invented — falls through unchanged (`doc/design.md` §7-3).
private func gmakResolveAdSize(width: Int, height: Int) -> AdSize {
  switch (width, height) {
  case (320, 50): return AdSizeBanner
  case (320, 100): return AdSizeLargeBanner
  case (300, 250): return AdSizeMediumRectangle
  case (468, 60): return AdSizeFullBanner
  case (728, 90): return AdSizeLeaderboard
  default:
    return adSizeFor(cgSize: CGSize(width: width, height: height))
  }
}

/// Forwards one banner's events to Dart.
///
/// Retained by the store for the banner's lifetime: the SDK holds its delegate
/// weakly, so otherwise it would deallocate before the first callback.
private final class GMAKBannerAdDelegate: NSObject, BannerViewDelegate {
  private let token: Int64

  init(token: Int64) {
    self.token = token
  }

  func bannerViewDidReceiveAd(_ bannerView: BannerView) {
    gmakFireEvent(
      token: token,
      status: .loaded,
      payload: gmakResponseInfoPayload(bannerView.responseInfo))
  }

  func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
    gmakFireEvent(token: token, status: .failedToLoad, payload: gmakErrorPayload(error))
  }

  func bannerViewDidRecordImpression(_ bannerView: BannerView) {
    gmakFireEvent(token: token, status: .impression)
  }

  func bannerViewDidRecordClick(_ bannerView: BannerView) {
    gmakFireEvent(token: token, status: .clicked)
  }

  /// A tap is about to cover the app — the Dart listener's `onAdOpened`.
  func bannerViewWillPresentScreen(_ bannerView: BannerView) {
    gmakFireEvent(token: token, status: .opened)
  }

  /// The overlay is gone; `onAdClosed`. Reported on *did* dismiss rather than
  /// *will*, so the listener runs when the app is actually back in front.
  func bannerViewDidDismissScreen(_ bannerView: BannerView) {
    gmakFireEvent(token: token, status: .closed)
  }
}
