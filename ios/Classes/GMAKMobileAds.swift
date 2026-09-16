// The full-screen ad formats: interstitial, rewarded, rewarded interstitial and
// app open.
//
// Dart calls land on the @_cdecl functions below — one hop, no JNI shim, unlike
// Android. Events go back through the dispatcher slot in GMAKCore.swift, which
// is re-read immediately before every fire so a hot restart cannot dispatch into
// a dead isolate (doc/design.md §5-2).
//
// Written against the Google Mobile Ads SDK v13 Swift names (`MobileAds`,
// `InterstitialAd`, …); v12 renamed these from the old `GAD*` spelling. The
// shared event contract, request building and payload encoding live in
// GMAKCore.swift; the view-backed formats are in GMAKBannerAd.swift and
// GMAKNativeAd.swift.

import Foundation
import GoogleMobileAds
import UIKit

// MARK: - Ad store

/// Live full-screen ads, keyed by the Dart token that owns each one.
///
/// Confined to the main thread: every mutation happens inside a
/// `DispatchQueue.main.async` block or on a Dart-originated call, which already
/// runs on the platform's main thread.
private var ads: [Int64: NSObject] = [:]

/// Retains the per-ad delegate for as long as the ad lives.
///
/// The SDK holds its delegate weakly, so without this the event handler would
/// deallocate immediately after `load` returns and no callback would fire.
private var delegates: [Int64: AdEventHandler] = [:]

// MARK: - Entry points

/// Hands the native side the one Dart callback pointer, and registers the view
/// provider.
///
/// Called once from `AdsFFIBindings.loadSymbols()`.
@_cdecl("GMAKSetDispatcher")
public func GMAKSetDispatcher(_ callbackPtr: Int64) {
  // A second dispatcher means a second isolate: a hot restart. The ads from the
  // previous one are still mounted with no Dart owner left to dispose them —
  // a banner would keep auto-refreshing and recording impressions — and the
  // container handover queues still hold entries the dead reconciler never
  // collected, which would put every later createView off by one. Drop it all
  // before adopting the new dispatcher.
  //
  // This is the only hook available. Android registers a teardown callback with
  // `DNViewRegistry.registerResetHook`; iOS exports no such plugin-facing
  // symbol, and the engine zeroes the dispatcher slot directly rather than
  // calling back in — so the arrival of a *new* pointer is what betrays the
  // restart, not the clearing of the old one.
  if gmakDispatcherIsInstalled {
    GMAKStore.shared.releaseAll()
    gmakReleasePreloadState()
    ads.removeAll()
    delegates.removeAll()
  }
  gmakDispatcherIsInstalled = true

  gmakDispatcherSlot.pointee = callbackPtr

  // Hand the slot to the engine so it can zero it before tearing the isolate
  // down. Resolved dynamically, like every other engine symbol here: the
  // engine binary is not linked against this pod (see GMAKMobileAdsProvider).
  typealias RegisterSlot = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
  if let sym = dlsym(dlopen(nil, RTLD_NOLOAD), "DNRegisterAsyncDispatcherSlot") {
    unsafeBitCast(sym, to: RegisterSlot.self)(gmakDispatcherSlot)
  }
}

/// Whether a dispatcher has been installed since the process started.
///
/// Main-thread only, like the rest of the plugin's state.
private var gmakDispatcherIsInstalled = false

@_cdecl("GMAKInitialize")
public func GMAKInitialize(_ token: Int64) {
  // Unlike Android, the iOS SDK reads the App ID from Info.plist
  // (GADApplicationIdentifier) and its start method is safe on the main thread.
  MobileAds.shared.start { _ in
    // Mediation is out of scope for v1.0 (doc/design.md §1-3), so the adapter
    // map is reported empty rather than half-populated.
    gmakFireEvent(token: token, status: .initialized, payload: ["adapterStatuses": [:]])
  }
}

@_cdecl("GMAKLoadAd")
public func GMAKLoadAd(
  _ token: Int64,
  _ format: Int32,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJSONPtr: UnsafePointer<CChar>?
) {
  guard let adUnitIdPtr = adUnitIdPtr else { return }
  let adUnitId = String(cString: adUnitIdPtr)
  let requestJSON = requestJSONPtr.map { String(cString: $0) } ?? "{}"
  let request = gmakBuildRequest(from: requestJSON)

  guard let format = GMAKAdFormat(rawValue: format) else {
    gmakFireEvent(
      token: token,
      status: .failedToLoad,
      payload: gmakFailurePayload("Unknown ad format: \(format)"))
    return
  }

  switch format {
  case .interstitial:
    InterstitialAd.load(with: adUnitId, request: request) { ad, error in
      finishLoad(token: token, ad: ad, error: error)
    }
  case .rewarded:
    RewardedAd.load(with: adUnitId, request: request) { ad, error in
      finishLoad(token: token, ad: ad, error: error)
    }
  case .rewardedInterstitial:
    RewardedInterstitialAd.load(with: adUnitId, request: request) { ad, error in
      finishLoad(token: token, ad: ad, error: error)
    }
  case .appOpen:
    AppOpenAd.load(with: adUnitId, request: request) { ad, error in
      finishLoad(token: token, ad: ad, error: error)
    }
  }
}

@_cdecl("GMAKShowAd")
public func GMAKShowAd(_ token: Int64) {
  DispatchQueue.main.async {
    guard let root = gmakRootViewController() else {
      gmakFireEvent(
        token: token,
        status: .failedToShow,
        payload: gmakFailurePayload("No view controller is available to present from."))
      return
    }
    switch ads[token] {
    case let ad as InterstitialAd:
      ad.present(from: root)
    case let ad as AppOpenAd:
      ad.present(from: root)
    case let ad as RewardedAd:
      ad.present(from: root) {
        let reward = ad.adReward
        gmakFireEvent(
          token: token,
          status: .userEarnedReward,
          payload: ["amount": reward.amount, "type": reward.type])
      }
    case let ad as RewardedInterstitialAd:
      ad.present(from: root) {
        let reward = ad.adReward
        gmakFireEvent(
          token: token,
          status: .userEarnedReward,
          payload: ["amount": reward.amount, "type": reward.type])
      }
    default:
      break
    }
  }
}

@_cdecl("GMAKDisposeAd")
public func GMAKDisposeAd(_ token: Int64) {
  DispatchQueue.main.async {
    ads.removeValue(forKey: token)
    delegates.removeValue(forKey: token)
  }
}

/// Adopts an ad that came out of a preload buffer.
///
/// A preloaded ad exists before any Dart object does, so it arrives with a
/// token the native side allocated (negative, to stay clear of Dart's own) and
/// no event delegate attached. This gives it the same treatment a freshly
/// loaded ad gets in `finishLoad`, so `show` and `dispose` find it and its
/// presentation events reach Dart.
///
/// Called from the preloader rather than exported: Dart's `preloadPoll` gets
/// the token back from `GMAKPreloadPoll` and needs nothing else.
func gmakAdoptPreloadedAd(token: Int64, ad: NSObject) {
  attachHandler(token: token, to: ad)
}

@_cdecl("GMAKSetAppMuted")
public func GMAKSetAppMuted(_ muted: Int32) {
  MobileAds.shared.isApplicationMuted = muted != 0
}

/// Immersive mode is an Android concept; this exists so the symbol resolves.
@_cdecl("GMAKSetImmersiveMode")
public func GMAKSetImmersiveMode(_ token: Int64, _ enabled: Int32) {
  // Deliberately empty. The Dart layer already skips this off Android, so
  // reaching here is harmless.
}

@_cdecl("GMAKSetServerSideVerification")
public func GMAKSetServerSideVerification(
  _ token: Int64,
  _ userIdPtr: UnsafePointer<CChar>?,
  _ customDataPtr: UnsafePointer<CChar>?
) {
  let userId = userIdPtr.map { String(cString: $0) } ?? ""
  let customData = customDataPtr.map { String(cString: $0) } ?? ""

  DispatchQueue.main.async {
    let options = ServerSideVerificationOptions()
    if !userId.isEmpty { options.userIdentifier = userId }
    if !customData.isEmpty { options.customRewardText = customData }

    switch ads[token] {
    case let ad as RewardedAd:
      ad.serverSideVerificationOptions = options
    case let ad as RewardedInterstitialAd:
      ad.serverSideVerificationOptions = options
    default:
      break
    }
  }
}

// MARK: - Helpers

/// Stores a freshly loaded ad and reports the outcome to Dart.
private func finishLoad(token: Int64, ad: NSObject?, error: Error?) {
  if let error = error {
    gmakFireEvent(token: token, status: .failedToLoad, payload: gmakErrorPayload(error))
    return
  }
  guard let ad = ad else { return }

  DispatchQueue.main.async {
    let responseInfo = attachHandler(token: token, to: ad)
    gmakFireEvent(
      token: token, status: .loaded, payload: gmakResponseInfoPayload(responseInfo))
  }
}

/// Files [ad] under [token] and wires its event delegate, returning its
/// response info.
///
/// Every full-screen format exposes the same two hooks, but through concrete
/// types rather than a shared protocol, so they are attached per type. Shared
/// by the normal load path and by ads adopted from a preload buffer.
///
/// Main-thread only: `ads` and `delegates` are read there by show and dispose.
@discardableResult
private func attachHandler(token: Int64, to ad: NSObject) -> ResponseInfo? {
  let handler = AdEventHandler(token: token)
  delegates[token] = handler
  ads[token] = ad

  switch ad {
  case let ad as InterstitialAd:
    ad.fullScreenContentDelegate = handler
    ad.paidEventHandler = handler.paidEventHandler
    return ad.responseInfo
  case let ad as RewardedAd:
    ad.fullScreenContentDelegate = handler
    ad.paidEventHandler = handler.paidEventHandler
    return ad.responseInfo
  case let ad as RewardedInterstitialAd:
    ad.fullScreenContentDelegate = handler
    ad.paidEventHandler = handler.paidEventHandler
    return ad.responseInfo
  case let ad as AppOpenAd:
    ad.fullScreenContentDelegate = handler
    ad.paidEventHandler = handler.paidEventHandler
    return ad.responseInfo
  default:
    return nil
  }
}

/// Forwards one ad's presentation events to Dart.
///
/// The SDK holds this weakly, so it is retained in `delegates` for the ad's
/// lifetime.
private final class AdEventHandler: NSObject, FullScreenContentDelegate {
  private let token: Int64

  init(token: Int64) {
    self.token = token
  }

  var paidEventHandler: ((AdValue) -> Void) {
    return { [token] value in
      gmakFireEvent(token: token, status: .paidEvent, payload: gmakPaidEventPayload(value))
    }
  }

  func adDidRecordImpression(_ ad: FullScreenPresentingAd) {
    gmakFireEvent(token: token, status: .impression)
  }

  func adDidRecordClick(_ ad: FullScreenPresentingAd) {
    gmakFireEvent(token: token, status: .clicked)
  }

  func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
    gmakFireEvent(token: token, status: .failedToShow, payload: gmakErrorPayload(error))
  }

  func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
    gmakFireEvent(token: token, status: .showed)
  }

  func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
    gmakFireEvent(token: token, status: .dismissed)
  }
}
