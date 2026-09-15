// The iOS half of the plugin.
//
// Dart calls land on the @_cdecl functions below — one hop, no JNI shim, unlike
// Android. Events go back through a dispatcher slot that is re-read immediately
// before every fire, so a hot restart cannot dispatch into a dead isolate
// (doc/design.md §5-2).
//
// Written against the Google Mobile Ads SDK v13 Swift names (`MobileAds`,
// `InterstitialAd`, …). v12 renamed these from the old `GAD*` spelling.

import Foundation
import GoogleMobileAds
import UIKit

// MARK: - Event contract

// Mirrors AdEventStatus in lib/src/ads_ffi_bindings.dart and AdsBridge.kt.
// Never renumber an existing value; append new ones.
private enum AdEventStatus: Int32 {
  case initialized = 0
  case loaded = 1
  case failedToLoad = 2
  case showed = 3
  case failedToShow = 4
  case dismissed = 5
  case impression = 6
  case clicked = 7
  case userEarnedReward = 8
  case paidEvent = 9
  case adPreloaded = 10
  case adsExhausted = 11
  case failedToPreload = 12
  case opened = 13
  case closed = 14
}

// Mirrors AdFormat in lib/src/ads_ffi_bindings.dart.
private enum AdFormat: Int32 {
  case interstitial = 0
  case rewarded = 1
  case rewardedInterstitial = 2
  case appOpen = 3
}

private typealias AdEventDispatch = @convention(c) (Int64, Int32, UnsafePointer<CChar>) -> Void

// MARK: - Dispatcher slot

/// The Dart callback address, or 0 when no isolate owns it.
///
/// Heap-allocated rather than a plain global so the framework can zero it
/// during hot-restart teardown. Always read through `fireEvent`, never cached.
private let dispatcherSlot: UnsafeMutablePointer<Int64> = {
  let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
  p.pointee = 0
  return p
}()

/// Delivers one event to Dart on the main thread.
///
/// The slot is re-read inside the main-queue block, so an event queued before a
/// hot restart sees the cleared slot and is dropped.
private func fireEvent(token: Int64, status: AdEventStatus, payload: [String: Any] = [:]) {
  let json = encodeJSON(payload)
  DispatchQueue.main.async {
    let address = dispatcherSlot.pointee
    guard address != 0 else { return }
    json.withCString { raw in
      unsafeBitCast(address, to: AdEventDispatch.self)(token, status.rawValue, raw)
    }
  }
}

private func encodeJSON(_ payload: [String: Any]) -> String {
  guard !payload.isEmpty,
    let data = try? JSONSerialization.data(withJSONObject: payload),
    let string = String(data: data, encoding: .utf8)
  else {
    return "{}"
  }
  return string
}

// MARK: - Ad store

/// Live ads, keyed by the Dart token that owns each one.
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

@_cdecl("DNAdsSetDispatcher")
public func DNAdsSetDispatcher(_ callbackPtr: Int64) {
  dispatcherSlot.pointee = callbackPtr

  // Hand the slot to the engine so it can zero it before tearing the isolate
  // down. Resolved dynamically: the symbol lives in the engine binary, which
  // this plugin does not link against.
  typealias RegisterSlot = @convention(c) (UnsafeMutablePointer<Int64>) -> Void
  if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "DNRegisterAsyncDispatcherSlot") {
    unsafeBitCast(sym, to: RegisterSlot.self)(dispatcherSlot)
  }
}

@_cdecl("DNAdsInitialize")
public func DNAdsInitialize(_ token: Int64) {
  // Unlike Android, the iOS SDK reads the App ID from Info.plist
  // (GADApplicationIdentifier) and its start method is safe on the main thread.
  MobileAds.shared.start { _ in
    // Mediation is out of scope for v1.0 (doc/design.md §1-3), so the adapter
    // map is reported empty rather than half-populated.
    fireEvent(token: token, status: .initialized, payload: ["adapterStatuses": [:]])
  }
}

@_cdecl("DNAdsLoadAd")
public func DNAdsLoadAd(
  _ token: Int64,
  _ format: Int32,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJSONPtr: UnsafePointer<CChar>?
) {
  guard let adUnitIdPtr = adUnitIdPtr else { return }
  let adUnitId = String(cString: adUnitIdPtr)
  let requestJSON = requestJSONPtr.map { String(cString: $0) } ?? "{}"
  let request = buildRequest(from: requestJSON)

  guard let format = AdFormat(rawValue: format) else {
    fireEvent(
      token: token,
      status: .failedToLoad,
      payload: [
        "code": -1,
        "domain": "dartnative_mobile_ads",
        "message": "Unknown ad format: \(format)",
      ])
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

@_cdecl("DNAdsShowAd")
public func DNAdsShowAd(_ token: Int64) {
  DispatchQueue.main.async {
    guard let root = rootViewController() else { return }
    switch ads[token] {
    case let ad as InterstitialAd:
      ad.present(from: root)
    case let ad as AppOpenAd:
      ad.present(from: root)
    case let ad as RewardedAd:
      ad.present(from: root) {
        let reward = ad.adReward
        fireEvent(
          token: token,
          status: .userEarnedReward,
          payload: ["amount": reward.amount, "type": reward.type])
      }
    case let ad as RewardedInterstitialAd:
      ad.present(from: root) {
        let reward = ad.adReward
        fireEvent(
          token: token,
          status: .userEarnedReward,
          payload: ["amount": reward.amount, "type": reward.type])
      }
    default:
      break
    }
  }
}

@_cdecl("DNAdsDisposeAd")
public func DNAdsDisposeAd(_ token: Int64) {
  DispatchQueue.main.async {
    ads.removeValue(forKey: token)
    delegates.removeValue(forKey: token)
  }
}

@_cdecl("DNAdsSetAppMuted")
public func DNAdsSetAppMuted(_ muted: Int32) {
  MobileAds.shared.applicationMuted = muted != 0
}

/// Immersive mode is an Android concept; this exists so the symbol resolves.
@_cdecl("DNAdsSetImmersiveMode")
public func DNAdsSetImmersiveMode(_ token: Int64, _ enabled: Int32) {
  // Deliberately empty. The Dart layer already skips this off Android, so
  // reaching here is harmless.
}

@_cdecl("DNAdsSetServerSideVerification")
public func DNAdsSetServerSideVerification(
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

// MARK: - Preloading
//
// ⚠️ UNIMPLEMENTED on iOS. The Dart preloader API is backed by the Android
// Next-Gen SDK's *AdPreloader classes, whose iOS counterparts have not been
// verified against the real SDK headers — that needs macOS + Xcode, which this
// plugin's iOS half has never been built on (doc/design.md §11).
//
// These stubs exist so that `lib.lookupFunction` resolves every symbol at
// startup: a missing one throws and would take down the whole plugin, including
// the ad formats that do work. Each reports "nothing preloaded", so
// `pollAd` returns null and callers fall back to a normal load.
//
// To finish this on a Mac: check whether GMA v13 for iOS exposes
// InterstitialAdPreloader / RewardedAdPreloader / AppOpenAdPreloader with the
// same start/pollAd/isAdAvailable shape, then mirror AdsBridge.kt.

@_cdecl("DNAdsPreloadStart")
public func DNAdsPreloadStart(
  _ token: Int64,
  _ format: Int32,
  _ preloadIdPtr: UnsafePointer<CChar>?,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJSONPtr: UnsafePointer<CChar>?,
  _ bufferSize: Int32
) {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  fireEvent(
    token: token,
    status: .failedToPreload,
    payload: [
      "preloadId": preloadId,
      "code": -1,
      "domain": "dartnative_mobile_ads",
      "message": "Ad preloading is not implemented on iOS yet.",
    ])
}

@_cdecl("DNAdsPreloadPoll")
public func DNAdsPreloadPoll(_ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?) -> Int64 {
  return 0
}

@_cdecl("DNAdsPreloadIsAdAvailable")
public func DNAdsPreloadIsAdAvailable(
  _ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?
) -> Int32 {
  return 0
}

@_cdecl("DNAdsPreloadNumAdsAvailable")
public func DNAdsPreloadNumAdsAvailable(
  _ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?
) -> Int32 {
  return 0
}

@_cdecl("DNAdsPreloadDestroy")
public func DNAdsPreloadDestroy(_ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?) {
}

@_cdecl("DNAdsPreloadDestroyAll")
public func DNAdsPreloadDestroyAll(_ format: Int32) {
}

@_cdecl("DNAdsPreloadReadJson")
public func DNAdsPreloadReadJson(
  _ format: Int32,
  _ query: Int32,
  _ preloadIdPtr: UnsafePointer<CChar>?,
  _ buffer: UnsafeMutablePointer<UInt8>?,
  _ capacity: Int32
) -> Int32 {
  return 0
}

// MARK: - Banners and native ads (unimplemented on iOS)

// ⚠️ UNIMPLEMENTED on iOS, for the same reason as the preload stubs above: the
// iOS plugin-provider contract has not been confirmed, so there is no verified
// way to hand the reconciler a view (doc/design.md §12-1). The Android
// contract *is* confirmed, and both formats work there.
//
// As with preloading, these exist so that `lib.lookupFunction` resolves every
// symbol at startup — one missing symbol throws and takes down the whole
// plugin, including the full-screen formats that do work on iOS.
//
// Each reports a load failure rather than staying silent, so an app's
// onAdFailedToLoad path runs and it can lay out without an ad, instead of
// waiting forever for a callback that never comes.

@_cdecl("DNAdsBannerCreate")
public func DNAdsBannerCreate(
  _ token: Int64,
  _ viewId: Int64,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJsonPtr: UnsafePointer<CChar>?,
  _ widthDp: Int32,
  _ heightDp: Int32
) {
  fireEvent(
    token: token,
    status: .failedToLoad,
    payload: [
      "code": -1,
      "domain": "dartnative_mobile_ads",
      "message": "Banner ads are not implemented on iOS yet.",
    ])
}

@_cdecl("DNAdsBannerDispose")
public func DNAdsBannerDispose(_ viewId: Int64) {
}

@_cdecl("DNAdsAdaptiveBannerHeight")
public func DNAdsAdaptiveBannerHeight(_ widthDp: Int32) -> Int32 {
  // 0 means "no size available", which the Dart side turns into a null AdSize
  // so the caller skips the banner rather than reserving space for nothing.
  return 0
}

@_cdecl("DNAdsNativeAdCreate")
public func DNAdsNativeAdCreate(
  _ token: Int64,
  _ viewId: Int64,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJsonPtr: UnsafePointer<CChar>?,
  _ optionsJsonPtr: UnsafePointer<CChar>?
) {
  fireEvent(
    token: token,
    status: .failedToLoad,
    payload: [
      "code": -1,
      "domain": "dartnative_mobile_ads",
      "message": "Native ads are not implemented on iOS yet.",
    ])
}

@_cdecl("DNAdsNativeAdDispose")
public func DNAdsNativeAdDispose(_ viewId: Int64) {
}

// MARK: - Helpers

/// Stores a freshly loaded ad and reports the outcome to Dart.
private func finishLoad(token: Int64, ad: NSObject?, error: Error?) {
  if let error = error {
    fireEvent(token: token, status: .failedToLoad, payload: errorPayload(error))
    return
  }
  guard let ad = ad else { return }

  DispatchQueue.main.async {
    let handler = AdEventHandler(token: token)
    delegates[token] = handler
    ads[token] = ad

    // Every full-screen format exposes the same two hooks, but through
    // concrete types rather than a shared protocol, so attach them per type.
    switch ad {
    case let ad as InterstitialAd:
      ad.fullScreenContentDelegate = handler
      ad.paidEventHandler = handler.paidEventHandler
    case let ad as RewardedAd:
      ad.fullScreenContentDelegate = handler
      ad.paidEventHandler = handler.paidEventHandler
    case let ad as RewardedInterstitialAd:
      ad.fullScreenContentDelegate = handler
      ad.paidEventHandler = handler.paidEventHandler
    case let ad as AppOpenAd:
      ad.fullScreenContentDelegate = handler
      ad.paidEventHandler = handler.paidEventHandler
    default:
      break
    }

    fireEvent(token: token, status: .loaded)
  }
}

private func errorPayload(_ error: Error) -> [String: Any] {
  let nsError = error as NSError
  return [
    "code": nsError.code,
    "domain": nsError.domain,
    "message": nsError.localizedDescription,
  ]
}

/// Builds an SDK request from the JSON the Dart layer sends.
///
/// A malformed body falls through to an untargeted request rather than failing
/// the load, matching the Android side.
private func buildRequest(from json: String) -> Request {
  let request = Request()
  guard let data = json.data(using: .utf8),
    let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  else {
    return request
  }

  if let keywords = map["keywords"] as? [String] {
    request.keywords = keywords
  }
  if let contentURL = map["contentUrl"] as? String {
    request.contentURL = contentURL
  }
  if let neighboring = map["neighboringContentUrls"] as? [String] {
    request.neighboringContentURLStrings = neighboring
  }

  var extras: [String: String] = map["extras"] as? [String: String] ?? [:]
  if map["nonPersonalizedAds"] as? Bool == true {
    // "npa=1" is the documented signal for a non-personalized request.
    extras["npa"] = "1"
  }
  if !extras.isEmpty {
    let networkExtras = Extras()
    networkExtras.additionalParameters = extras
    request.register(networkExtras)
  }

  return request
}

/// The view controller ads are presented from.
///
/// Walks past any controller already presenting, so an ad shown while a sheet
/// is up attaches to the sheet rather than failing.
private func rootViewController() -> UIViewController? {
  let scene = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .first { $0.activationState == .foregroundActive }

  var controller = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?
    .rootViewController
  while let presented = controller?.presentedViewController {
    controller = presented
  }
  return controller
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
      fireEvent(
        token: token,
        status: .paidEvent,
        payload: [
          "valueMicros": NSDecimalNumber(decimal: value.value.decimalValue)
            .multiplying(byPowerOf10: 6).int64Value,
          "currencyCode": value.currencyCode,
          "precision": value.precision.rawValue,
        ])
    }
  }

  func adDidRecordImpression(_ ad: FullScreenPresentingAd) {
    fireEvent(token: token, status: .impression)
  }

  func adDidRecordClick(_ ad: FullScreenPresentingAd) {
    fireEvent(token: token, status: .clicked)
  }

  func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
    fireEvent(token: token, status: .failedToShow, payload: errorPayload(error))
  }

  func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
    fireEvent(token: token, status: .showed)
  }

  func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
    fireEvent(token: token, status: .dismissed)
  }
}
