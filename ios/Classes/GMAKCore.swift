// The pieces every ad format shares: the event contract, the dispatcher slot,
// and the JSON encoding of SDK values.
//
// These are `internal` rather than `private` because Swift's `private` is
// file-scoped — the banner and native-ad files are separate translation units
// within the same module and need to reach them.

import Foundation
import GoogleMobileAds
import UIKit

// MARK: - Event contract

/// Mirrors `AdEventStatus` in lib/src/ads_ffi_bindings.dart and `AdsBridge.kt`.
///
/// The numbers are part of the Dart↔native contract: never renumber an existing
/// case, only append (`doc/design.md` §5-3).
enum GMAKAdEventStatus: Int32 {
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
  case laidOut = 15
}

/// Mirrors `AdFormat` in lib/src/ads_ffi_bindings.dart.
enum GMAKAdFormat: Int32 {
  case interstitial = 0
  case rewarded = 1
  case rewardedInterstitial = 2
  case appOpen = 3
}

/// The error domain reported for failures this plugin raises itself, as
/// opposed to ones the SDK produced.
let gmakErrorDomain = "google_mobile_ads_kit"

private typealias GMAKAdEventDispatch = @convention(c) (Int64, Int32, UnsafePointer<CChar>) -> Void

// MARK: - Dispatcher slot

/// The Dart callback address, or 0 when no isolate owns it.
///
/// Heap-allocated rather than a plain global so the engine can zero it while
/// tearing an isolate down. Always read through [gmakFireEvent], never cached
/// (`doc/design.md` §5-2).
let gmakDispatcherSlot: UnsafeMutablePointer<Int64> = {
  let pointer = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
  pointer.pointee = 0
  return pointer
}()

/// Delivers one event to Dart on the main thread.
///
/// The slot is re-read *inside* the main-queue block, so an event queued before
/// a hot restart finds it cleared and is dropped rather than dispatched into a
/// dead isolate.
func gmakFireEvent(
  token: Int64,
  status: GMAKAdEventStatus,
  payload: [String: Any] = [:]
) {
  let json = gmakEncodeJSON(payload)
  DispatchQueue.main.async {
    let address = gmakDispatcherSlot.pointee
    guard address != 0 else { return }
    json.withCString { raw in
      unsafeBitCast(address, to: GMAKAdEventDispatch.self)(token, status.rawValue, raw)
    }
  }
}

func gmakEncodeJSON(_ payload: [String: Any]) -> String {
  guard !payload.isEmpty,
    let data = try? JSONSerialization.data(withJSONObject: payload),
    let string = String(data: data, encoding: .utf8)
  else {
    return "{}"
  }
  return string
}

// MARK: - Payloads

/// Encodes an SDK error the way `LoadAdError.fromJson` on the Dart side reads it.
func gmakErrorPayload(_ error: Error) -> [String: Any] {
  let nsError = error as NSError
  return [
    "code": nsError.code,
    "domain": nsError.domain,
    "message": nsError.localizedDescription,
  ]
}

/// Encodes a failure this plugin raised itself.
func gmakFailurePayload(_ message: String, code: Int = -1) -> [String: Any] {
  ["code": code, "domain": gmakErrorDomain, "message": message]
}

/// Encodes a paid event.
///
/// `AdValue.value` is a decimal in the account currency; Dart expects micros,
/// which is what the Android side sends too.
func gmakPaidEventPayload(_ value: AdValue) -> [String: Any] {
  [
    "valueMicros": NSDecimalNumber(decimal: value.value.decimalValue)
      .multiplying(byPowerOf10: 6).int64Value,
    "currencyCode": value.currencyCode,
    "precision": value.precision.rawValue,
  ]
}

/// Wraps a response info for the `loaded` event, or an empty payload.
func gmakResponseInfoPayload(_ info: ResponseInfo?) -> [String: Any] {
  guard let info = info else { return [:] }
  var response: [String: Any] = [:]
  if let id = info.responseIdentifier { response["responseId"] = id }
  // The adapter class, as Android's `adapterClassName`. Not `adSourceName`:
  // that is the display name of the ad source, and nil unless the server sets it.
  if let network = info.loadedAdNetworkResponseInfo?.adNetworkClassName {
    response["mediationAdapterClassName"] = network
  }
  return response.isEmpty ? [:] : ["responseInfo": response]
}

// MARK: - Requests

/// Builds an SDK request from the JSON the Dart layer sends.
///
/// A malformed body falls through to an untargeted request rather than failing
/// the load, matching the Android side.
func gmakBuildRequest(from json: String) -> Request {
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
    request.neighboringContentURLs = neighboring
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

// MARK: - Presentation

/// The view controller ads are presented from.
///
/// Walks past anything already presenting, so an ad shown while a sheet is up
/// attaches to the sheet rather than failing.
func gmakRootViewController() -> UIViewController? {
  let scene = UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .first { $0.activationState == .foregroundActive }
    ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

  var controller = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?
    .rootViewController
  while let presented = controller?.presentedViewController {
    controller = presented
  }
  return controller
}
