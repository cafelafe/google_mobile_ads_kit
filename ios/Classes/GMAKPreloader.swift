// Ad preloading.
//
// The preloader API lives in the SDK's **private module**: the headers are
// under `PrivateHeaders/` as `GAD*Preloader_Beta.h`, exposed as the module
// `GoogleMobileAds_Private` rather than through the umbrella header. A plain
// `import GoogleMobileAds` does not see it — hence the second import below.
// (`google_mobile_ads` reaches the same API from Objective-C with
// `#import <GoogleMobileAds/GoogleMobileAds_Beta.h>`.)
//
// Being Beta, these types can change between SDK releases in ways the rest of
// the plugin's API cannot; the podspec's `~> 13.0` pin is what keeps that
// bounded (doc/design.md §9-1).
//
// The shape mirrors AdsBridge.kt so both platforms answer the Dart preloader
// identically — including the negative token numbering for preloaded ads.

import Foundation
import GoogleMobileAds
import GoogleMobileAds_Private

/// Which document `GMAKPreloadReadJson` should return.
///
/// Mirrors `PreloadQuery` in lib/src/ads_ffi_bindings.dart and `QUERY_*` in
/// `AdsBridge.kt`.
private enum GMAKPreloadQuery: Int32 {
  case polledResponseInfo = 0
  case configuration = 1
  case allConfigurations = 2
}

/// The delegates kept alive for each running preload buffer.
///
/// Keyed by "format:preloadId", matching the SDK's own scoping: the same id may
/// be used for two different formats.
private var gmakPreloadDelegates: [String: GMAKPreloadDelegate] = [:]

/// The response info of the most recently polled ad, per buffer.
///
/// `responseInfo(with:)` describes the *next* ad in the queue, so it is read
/// before polling and cached here for `GMAKPreloadReadJson` to hand back —
/// same reason as the Android side.
private var gmakPolledResponseInfo: [String: ResponseInfo] = [:]

/// Numbers preloaded ads from -1 downwards.
///
/// Dart allocates its own tokens from 1 upwards, and an ad that came out of a
/// buffer has no Dart object yet — counting down keeps the two ranges from ever
/// colliding (`doc/design.md` §10).
private var gmakPreloadTokenCounter: Int64 = 0

private func gmakNextPreloadToken() -> Int64 {
  gmakPreloadTokenCounter -= 1
  return gmakPreloadTokenCounter
}

private func gmakBufferKey(_ format: Int32, _ preloadId: String) -> String {
  "\(format):\(preloadId)"
}

// MARK: - Entry points

/// Starts preloading ads of [format] into the buffer named by [preloadIdPtr].
@_cdecl("GMAKPreloadStart")
public func GMAKPreloadStart(
  _ token: Int64,
  _ format: Int32,
  _ preloadIdPtr: UnsafePointer<CChar>?,
  _ adUnitIdPtr: UnsafePointer<CChar>?,
  _ requestJSONPtr: UnsafePointer<CChar>?,
  _ bufferSize: Int32
) {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  let adUnitId = adUnitIdPtr.map { String(cString: $0) } ?? ""
  let requestJSON = requestJSONPtr.map { String(cString: $0) } ?? "{}"

  guard let adFormat = GMAKAdFormat(rawValue: format) else {
    gmakFirePreloadFailure(token: token, preloadId: preloadId, message: "Unknown ad format.")
    return
  }

  let configuration = PreloadConfigurationV2(
    adUnitID: adUnitId,
    request: gmakBuildRequest(from: requestJSON))
  // 0 means "the SDK's default"; only a positive value is a real request.
  if bufferSize > 0 {
    configuration.bufferSize = UInt(bufferSize)
  }

  // Retained for the buffer's lifetime: the preloader holds its delegate
  // weakly, so otherwise no preload event would ever arrive.
  let delegate = GMAKPreloadDelegate(token: token, format: format)
  gmakPreloadDelegates[gmakBufferKey(format, preloadId)] = delegate

  let started: Bool
  switch adFormat {
  case .interstitial:
    started = InterstitialAdPreloader.shared.preload(
      for: preloadId, configuration: configuration, delegate: delegate)
  case .rewarded:
    started = RewardedAdPreloader.shared.preload(
      for: preloadId, configuration: configuration, delegate: delegate)
  case .rewardedInterstitial:
    started = RewardedInterstitialAdPreloader.shared.preload(
      for: preloadId, configuration: configuration, delegate: delegate)
  case .appOpen:
    started = AppOpenAdPreloader.shared.preload(
      for: preloadId, configuration: configuration, delegate: delegate)
  }

  // The SDK reports a refused start with `false` and a console log, not an
  // error object — surface it as a preload failure so the Dart callback fires
  // rather than the app waiting for ads that will never come.
  if !started {
    gmakPreloadDelegates.removeValue(forKey: gmakBufferKey(format, preloadId))
    gmakFirePreloadFailure(
      token: token,
      preloadId: preloadId,
      message: "The SDK refused to start preloading. Check the console for the reason.")
  }
}

/// Takes one preloaded ad out of the buffer, returning its token or 0.
@_cdecl("GMAKPreloadPoll")
public func GMAKPreloadPoll(_ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?) -> Int64 {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  guard let adFormat = GMAKAdFormat(rawValue: format) else { return 0 }
  let key = gmakBufferKey(format, preloadId)

  // Read before polling: this describes the ad about to come out, and after the
  // poll it would describe the one behind it.
  let info: ResponseInfo?
  let ad: NSObject?
  switch adFormat {
  case .interstitial:
    info = InterstitialAdPreloader.shared.responseInfo(with: preloadId)
    ad = InterstitialAdPreloader.shared.ad(with: preloadId)
  case .rewarded:
    info = RewardedAdPreloader.shared.responseInfo(with: preloadId)
    ad = RewardedAdPreloader.shared.ad(with: preloadId)
  case .rewardedInterstitial:
    info = RewardedInterstitialAdPreloader.shared.responseInfo(with: preloadId)
    ad = RewardedInterstitialAdPreloader.shared.ad(with: preloadId)
  case .appOpen:
    info = AppOpenAdPreloader.shared.responseInfo(with: preloadId)
    ad = AppOpenAdPreloader.shared.ad(with: preloadId)
  }

  guard let ad = ad else { return 0 }

  if let info = info {
    gmakPolledResponseInfo[key] = info
  } else {
    gmakPolledResponseInfo.removeValue(forKey: key)
  }

  // Hand it straight to the full-screen store, which is where show and dispose
  // look — and which attaches the presentation-event delegate the buffer did
  // not. Nothing is kept here: a polled ad is an ordinary ad from that point on.
  let token = gmakNextPreloadToken()
  gmakAdoptPreloadedAd(token: token, ad: ad)
  return token
}

/// Whether the buffer currently holds at least one ad.
@_cdecl("GMAKPreloadIsAdAvailable")
public func GMAKPreloadIsAdAvailable(
  _ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?
) -> Int32 {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  guard let adFormat = GMAKAdFormat(rawValue: format) else { return 0 }

  let available: Bool
  switch adFormat {
  case .interstitial:
    available = InterstitialAdPreloader.shared.isAdAvailable(with: preloadId)
  case .rewarded:
    available = RewardedAdPreloader.shared.isAdAvailable(with: preloadId)
  case .rewardedInterstitial:
    available = RewardedInterstitialAdPreloader.shared.isAdAvailable(with: preloadId)
  case .appOpen:
    available = AppOpenAdPreloader.shared.isAdAvailable(with: preloadId)
  }
  return available ? 1 : 0
}

/// How many ads the buffer currently holds.
@_cdecl("GMAKPreloadNumAdsAvailable")
public func GMAKPreloadNumAdsAvailable(
  _ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?
) -> Int32 {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  guard let adFormat = GMAKAdFormat(rawValue: format) else { return 0 }

  let count: UInt
  switch adFormat {
  case .interstitial:
    count = InterstitialAdPreloader.shared.numberOfAdsAvailable(with: preloadId)
  case .rewarded:
    count = RewardedAdPreloader.shared.numberOfAdsAvailable(with: preloadId)
  case .rewardedInterstitial:
    count = RewardedInterstitialAdPreloader.shared.numberOfAdsAvailable(with: preloadId)
  case .appOpen:
    count = AppOpenAdPreloader.shared.numberOfAdsAvailable(with: preloadId)
  }
  return Int32(clamping: count)
}

/// Destroys one buffer and the ads still in it.
@_cdecl("GMAKPreloadDestroy")
public func GMAKPreloadDestroy(_ format: Int32, _ preloadIdPtr: UnsafePointer<CChar>?) {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  guard let adFormat = GMAKAdFormat(rawValue: format) else { return }

  switch adFormat {
  case .interstitial:
    InterstitialAdPreloader.shared.stopPreloadingAndRemoveAds(for: preloadId)
  case .rewarded:
    RewardedAdPreloader.shared.stopPreloadingAndRemoveAds(for: preloadId)
  case .rewardedInterstitial:
    RewardedInterstitialAdPreloader.shared.stopPreloadingAndRemoveAds(for: preloadId)
  case .appOpen:
    AppOpenAdPreloader.shared.stopPreloadingAndRemoveAds(for: preloadId)
  }

  let key = gmakBufferKey(format, preloadId)
  gmakPreloadDelegates.removeValue(forKey: key)
  gmakPolledResponseInfo.removeValue(forKey: key)
}

/// Destroys every buffer of [format].
@_cdecl("GMAKPreloadDestroyAll")
public func GMAKPreloadDestroyAll(_ format: Int32) {
  guard let adFormat = GMAKAdFormat(rawValue: format) else { return }

  switch adFormat {
  case .interstitial:
    InterstitialAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  case .rewarded:
    RewardedAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  case .rewardedInterstitial:
    RewardedInterstitialAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  case .appOpen:
    AppOpenAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  }

  let prefix = "\(format):"
  gmakPreloadDelegates = gmakPreloadDelegates.filter { !$0.key.hasPrefix(prefix) }
  gmakPolledResponseInfo = gmakPolledResponseInfo.filter { !$0.key.hasPrefix(prefix) }
}

/// Writes one JSON document into a caller-owned buffer.
///
/// Returns the bytes written, or the negative size required when [capacity] is
/// too small so the caller can retry — it never truncates (`doc/design.md` §5-3).
@_cdecl("GMAKPreloadReadJson")
public func GMAKPreloadReadJson(
  _ format: Int32,
  _ query: Int32,
  _ preloadIdPtr: UnsafePointer<CChar>?,
  _ buffer: UnsafeMutablePointer<UInt8>?,
  _ capacity: Int32
) -> Int32 {
  let preloadId = preloadIdPtr.map { String(cString: $0) } ?? ""
  guard let adFormat = GMAKAdFormat(rawValue: format),
    let selector = GMAKPreloadQuery(rawValue: query)
  else {
    return 0
  }

  let json: String
  switch selector {
  case .polledResponseInfo:
    let info = gmakPolledResponseInfo[gmakBufferKey(format, preloadId)]
    json = info.map { gmakEncodeJSON(gmakResponseInfoFields($0)) } ?? ""

  case .configuration:
    let configuration: PreloadConfigurationV2?
    switch adFormat {
    case .interstitial:
      configuration = InterstitialAdPreloader.shared.configuration(with: preloadId)
    case .rewarded:
      configuration = RewardedAdPreloader.shared.configuration(with: preloadId)
    case .rewardedInterstitial:
      configuration = RewardedInterstitialAdPreloader.shared.configuration(with: preloadId)
    case .appOpen:
      configuration = AppOpenAdPreloader.shared.configuration(with: preloadId)
    }
    json = configuration.map { gmakEncodeJSON(gmakConfigurationFields($0)) } ?? ""

  case .allConfigurations:
    let configurations: [String: PreloadConfigurationV2]
    switch adFormat {
    case .interstitial:
      configurations = InterstitialAdPreloader.shared.configurations()
    case .rewarded:
      configurations = RewardedAdPreloader.shared.configurations()
    case .rewardedInterstitial:
      configurations = RewardedInterstitialAdPreloader.shared.configurations()
    case .appOpen:
      configurations = AppOpenAdPreloader.shared.configurations()
    }
    json = configurations.isEmpty
      ? ""
      : gmakEncodeJSON(configurations.mapValues { gmakConfigurationFields($0) })
  }

  return gmakWrite(json, into: buffer, capacity: capacity)
}

/// Drops every buffer, for a hot restart.
///
/// The buffers have to go, not just the delegates. The SDK refuses to start a
/// preload ID that already exists — it logs "reusing an existing preload ID
/// results in failure" and returns `false` — and has no way to swap the
/// delegate on a running buffer. Keeping the inventory across a restart would
/// therefore mean the new isolate's `start()` for the same id is refused, its
/// delegate dropped with it, and no preload event ever reaches Dart again.
/// The buffers belong to SDK singletons that outlive the isolate, so nothing
/// else clears them.
func gmakReleasePreloadState() {
  InterstitialAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  RewardedAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  RewardedInterstitialAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  AppOpenAdPreloader.shared.stopPreloadingAndRemoveAllAds()
  gmakPreloadDelegates.removeAll()
  gmakPolledResponseInfo.removeAll()
}

// MARK: - Helpers

/// Copies [json] into [buffer], or reports the size needed.
private func gmakWrite(
  _ json: String,
  into buffer: UnsafeMutablePointer<UInt8>?,
  capacity: Int32
) -> Int32 {
  if json.isEmpty { return 0 }
  let bytes = Array(json.utf8)
  guard let buffer = buffer, bytes.count <= Int(capacity) else {
    // Negative: "too small, and this is how much you need" — the Dart side
    // grows its buffer and calls again.
    return Int32(clamping: -bytes.count)
  }
  buffer.update(from: bytes, count: bytes.count)
  return Int32(bytes.count)
}

/// The `ResponseInfo` fields the Dart side reads, unwrapped.
///
/// `gmakResponseInfoPayload` nests these under "responseInfo" for an event
/// payload; the preload queries return the object on its own.
private func gmakResponseInfoFields(_ info: ResponseInfo) -> [String: Any] {
  var fields: [String: Any] = [:]
  if let id = info.responseIdentifier { fields["responseId"] = id }
  // The adapter class, as Android's `adapterClassName`. Not `adSourceName`:
  // that is the display name of the ad source, and nil unless the server sets it.
  if let network = info.loadedAdNetworkResponseInfo?.adNetworkClassName {
    fields["mediationAdapterClassName"] = network
  }
  return fields
}

/// Mirrors `configJson` in AdsBridge.kt, which is what
/// `PreloadConfiguration._configFromJson` parses.
private func gmakConfigurationFields(_ configuration: PreloadConfigurationV2) -> [String: Any] {
  ["adUnitId": configuration.adUnitID, "bufferSize": Int(configuration.bufferSize)]
}

private func gmakFirePreloadFailure(token: Int64, preloadId: String, message: String) {
  var payload = gmakFailurePayload(message)
  payload["preloadId"] = preloadId
  gmakFireEvent(token: token, status: .failedToPreload, payload: payload)
}

/// Forwards one buffer's preload events to Dart.
///
/// Retained in `gmakPreloadDelegates`: the preloader holds its delegate weakly.
private final class GMAKPreloadDelegate: NSObject, PreloadDelegate {
  private let token: Int64
  private let format: Int32

  init(token: Int64, format: Int32) {
    self.token = token
    self.format = format
  }

  func adAvailable(forPreloadID preloadID: String, responseInfo: ResponseInfo) {
    var payload: [String: Any] = ["preloadId": preloadID]
    let fields = gmakResponseInfoFields(responseInfo)
    if !fields.isEmpty { payload["responseInfo"] = fields }
    gmakFireEvent(token: token, status: .adPreloaded, payload: payload)
  }

  func adsExhausted(forPreloadID preloadID: String) {
    gmakFireEvent(token: token, status: .adsExhausted, payload: ["preloadId": preloadID])
  }

  func adFailedToPreload(forPreloadID preloadID: String, error: Error) {
    var payload = gmakErrorPayload(error)
    payload["preloadId"] = preloadID
    gmakFireEvent(token: token, status: .failedToPreload, payload: payload)
  }
}
