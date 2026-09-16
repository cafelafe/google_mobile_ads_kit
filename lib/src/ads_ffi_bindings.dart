/// The FFI boundary between Dart and the native Google Mobile Ads SDKs.
///
/// Everything crossing this boundary is either a scalar or a JSON string, and
/// every call is synchronous (`dart:ffi` has no other mode). Results that the
/// SDK produces asynchronously come back through the dispatcher described in
/// [AdsFFIBindings.loadSymbols] — see `doc/design.md` §5.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Event kinds delivered by the native dispatcher.
///
/// The numeric values are part of the Dart↔native contract and are duplicated
/// in `AdsBridge.kt` (`STATUS_*`) and `GMAKMobileAds.swift`. Never renumber an
/// existing member; append new ones.
abstract final class AdEventStatus {
  /// The SDK finished initializing. Payload: `{}`.
  static const int initialized = 0;

  /// An ad loaded. Payload: `{"responseInfo": {...}?}`.
  static const int loaded = 1;

  /// An ad failed to load. Payload: the [LoadAdError] fields.
  static const int failedToLoad = 2;

  /// A full-screen ad was shown. Payload: `{}`.
  static const int showed = 3;

  /// A full-screen ad failed to show. Payload: the [AdError] fields.
  static const int failedToShow = 4;

  /// A full-screen ad was dismissed. Payload: `{}`.
  static const int dismissed = 5;

  /// The ad recorded an impression. Payload: `{}`.
  static const int impression = 6;

  /// The ad was clicked. Payload: `{}`.
  static const int clicked = 7;

  /// The user earned a reward. Payload: `{"amount": int, "type": String}`.
  static const int userEarnedReward = 8;

  /// A paid event fired. Payload:
  /// `{"valueMicros": int, "currencyCode": String, "precision": int}`.
  static const int paidEvent = 9;

  /// An ad was preloaded into a buffer. Payload:
  /// `{"preloadId": String, "responseInfo": {...}?}`.
  static const int adPreloaded = 10;

  /// A preload buffer ran dry. Payload: `{"preloadId": String}`.
  static const int adsExhausted = 11;

  /// Preloading an ad failed. Payload: `{"preloadId": String}` plus the
  /// [LoadAdError] fields.
  static const int failedToPreload = 12;

  /// A banner opened a full-screen overlay. Payload: `{}`.
  static const int opened = 13;

  /// A banner's full-screen overlay closed. Payload: `{}`.
  static const int closed = 14;

  /// Yoga laid a native ad's container out at a width it had not reported
  /// before. Payload: `{"width": double}` in logical pixels.
  ///
  /// The width `LayoutBuilder` hands the widget is the screen's, not the
  /// slot's, so the aspect ratio derived from it reserves the wrong height
  /// whenever the ad sits inside padding. This is the real width, from which
  /// the ratio is corrected (`doc/design.md` §8-6).
  static const int laidOut = 15;
}

// Dart -> native.
typedef _SetDispatcherC = Void Function(Int64);
typedef _SetDispatcherDart = void Function(int);

typedef _InitializeC = Void Function(Int64);
typedef _InitializeDart = void Function(int);

typedef _LoadAdC = Void Function(Int64, Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _LoadAdDart = void Function(int, int, Pointer<Utf8>, Pointer<Utf8>);

typedef _ShowAdC = Void Function(Int64);
typedef _ShowAdDart = void Function(int);

typedef _DisposeAdC = Void Function(Int64);
typedef _DisposeAdDart = void Function(int);

typedef _SetBoolC = Void Function(Int32);
typedef _SetBoolDart = void Function(int);

typedef _SetAdBoolC = Void Function(Int64, Int32);
typedef _SetAdBoolDart = void Function(int, int);

typedef _SetSsvC = Void Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetSsvDart = void Function(int, Pointer<Utf8>, Pointer<Utf8>);

// Banners. The native AdView is created by the plugin provider's createView,
// which only receives the view type — so the ad's configuration is handed over
// beforehand, keyed by the view id the reconciler will assign.
typedef _BannerCreateC = Void Function(
    Int64, Int64, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32);
typedef _BannerCreateDart = void Function(
    int, int, Pointer<Utf8>, Pointer<Utf8>, int, int);

typedef _BannerDisposeC = Void Function(Int64);
typedef _BannerDisposeDart = void Function(int);

// Native ads. Same view-id-keyed handover as banners, plus an options blob
// saying which renderer to use (a built-in template, or a registered factory)
// and how to configure it.
typedef _NativeCreateC = Void Function(
    Int64, Int64, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeCreateDart = void Function(
    int, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _NativeDisposeC = Void Function(Int64);
typedef _NativeDisposeDart = void Function(int);

typedef _AdaptiveHeightC = Int32 Function(Int32);
typedef _AdaptiveHeightDart = int Function(int);

// Preloading. `GMAKPreloadStart` mirrors GMAKLoadAd plus a preload id and
// buffer size; the query calls are synchronous because the Next-Gen preloader
// answers them from its local buffer without a network round trip.
typedef _PreloadStartC = Void Function(
    Int64, Int32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _PreloadStartDart = void Function(
    int, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);

typedef _PreloadPollC = Int64 Function(Int32, Pointer<Utf8>);
typedef _PreloadPollDart = int Function(int, Pointer<Utf8>);

typedef _PreloadQueryC = Int32 Function(Int32, Pointer<Utf8>);
typedef _PreloadQueryDart = int Function(int, Pointer<Utf8>);

typedef _PreloadDestroyC = Void Function(Int32, Pointer<Utf8>);
typedef _PreloadDestroyDart = void Function(int, Pointer<Utf8>);

typedef _PreloadDestroyAllC = Void Function(Int32);
typedef _PreloadDestroyAllDart = void Function(int);

/// Reads a JSON string out of native into a caller-owned buffer.
///
/// Takes the format, a [PreloadQuery] selector, a preload id, and the buffer.
/// Returns the number of bytes written, or the negative required size when the
/// buffer is too small, so the caller can retry with a bigger one. Keeps
/// ownership of the memory on the Dart side, which avoids a free-across-FFI
/// contract.
typedef _ReadJsonC = Int32 Function(
    Int32, Int32, Pointer<Utf8>, Pointer<Uint8>, Int32);
typedef _ReadJsonDart = int Function(
    int, int, Pointer<Utf8>, Pointer<Uint8>, int);

// Native -> Dart.
typedef _DispatchC = Void Function(Int64, Int32, Pointer<Utf8>);

/// Ad format identifiers passed to `GMAKLoadAd`.
///
/// Shared with `AdsBridge.kt` (`FORMAT_*`); see [AdEventStatus] for the
/// numbering rule.
abstract final class AdFormat {
  /// A full-screen interstitial ad.
  static const int interstitial = 0;

  /// A rewarded video ad.
  static const int rewarded = 1;

  /// A rewarded interstitial ad.
  static const int rewardedInterstitial = 2;

  /// An app open ad.
  static const int appOpen = 3;
}

/// Which document [AdsFFIBindings.preloadReadJson] should return.
///
/// Mirrors `QUERY_*` in `AdsBridge.kt`.
abstract final class PreloadQuery {
  /// The response info of the ad most recently polled out of the buffer.
  static const int polledResponseInfo = 0;

  /// One buffer's configuration, named by the preload id.
  static const int configuration = 1;

  /// Every live configuration of the format, keyed by preload id.
  static const int allConfigurations = 2;
}

/// Receives every asynchronous ad event for one token.
///
/// [status] is an [AdEventStatus] value and [payload] the decoded JSON body,
/// which is empty for events that carry no data.
typedef AdEventSink = void Function(int status, Map<String, Object?> payload);

/// The plugin's FFI symbol table and event router.
///
/// Call [loadSymbols] once at startup — the generated plugin registrant does
/// this via `initializeMobileAdsPlugin()`. On platforms without a Mobile Ads
/// SDK every method here is a no-op, so shared code keeps running on web and
/// desktop (`doc/design.md` §1-2).
abstract final class AdsFFIBindings {
  static late final _SetDispatcherDart _setDispatcher;
  static late final _InitializeDart _initialize;
  static late final _LoadAdDart _loadAd;
  static late final _ShowAdDart _showAd;
  static late final _DisposeAdDart _disposeAd;
  static late final _SetBoolDart _setMuted;
  static late final _SetAdBoolDart _setImmersiveMode;
  static late final _SetSsvDart _setServerSideVerification;
  static late final _BannerCreateDart _bannerCreate;
  static late final _BannerDisposeDart _bannerDispose;
  static late final _NativeCreateDart _nativeAdCreate;
  static late final _NativeDisposeDart _nativeAdDispose;
  static late final _AdaptiveHeightDart _adaptiveBannerHeight;
  static late final _PreloadStartDart _preloadStart;
  static late final _PreloadPollDart _preloadPoll;
  static late final _PreloadQueryDart _preloadIsAvailable;
  static late final _PreloadQueryDart _preloadNumAvailable;
  static late final _PreloadDestroyDart _preloadDestroy;
  static late final _PreloadDestroyAllDart _preloadDestroyAll;
  static late final _ReadJsonDart _preloadReadJson;

  static bool _loaded = false;

  /// Whether the native symbols resolved and the platform supports ads.
  ///
  /// False on web and desktop, and on a mobile platform where the native
  /// library failed to load.
  static bool get isAvailable => _loaded;

  static int _nextToken = 1;
  static final Map<int, AdEventSink> _sinks = <int, AdEventSink>{};

  /// Resolves the native symbols and hands the native side its dispatcher.
  ///
  /// Idempotent, and a no-op on unsupported platforms. On Android the plugin
  /// class has already run `System.loadLibrary`, so `DynamicLibrary.open` finds
  /// the library already mapped; on iOS the Swift `@_cdecl` symbols are linked
  /// into the app binary, hence `DynamicLibrary.process`.
  static void loadSymbols() {
    if (_loaded) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final DynamicLibrary lib = Platform.isAndroid
        ? DynamicLibrary.open('libgoogle_mobile_ads_kit.so')
        : DynamicLibrary.process();

    _setDispatcher = lib.lookupFunction<_SetDispatcherC, _SetDispatcherDart>(
        'GMAKSetDispatcher');
    _initialize =
        lib.lookupFunction<_InitializeC, _InitializeDart>('GMAKInitialize');
    _loadAd = lib.lookupFunction<_LoadAdC, _LoadAdDart>('GMAKLoadAd');
    _showAd = lib.lookupFunction<_ShowAdC, _ShowAdDart>('GMAKShowAd');
    _disposeAd =
        lib.lookupFunction<_DisposeAdC, _DisposeAdDart>('GMAKDisposeAd');
    _setMuted =
        lib.lookupFunction<_SetBoolC, _SetBoolDart>('GMAKSetAppMuted');
    _setImmersiveMode = lib.lookupFunction<_SetAdBoolC, _SetAdBoolDart>(
        'GMAKSetImmersiveMode');
    _setServerSideVerification = lib.lookupFunction<_SetSsvC, _SetSsvDart>(
        'GMAKSetServerSideVerification');

    _bannerCreate = lib.lookupFunction<_BannerCreateC, _BannerCreateDart>(
        'GMAKBannerCreate');
    _bannerDispose = lib.lookupFunction<_BannerDisposeC, _BannerDisposeDart>(
        'GMAKBannerDispose');
    _nativeAdCreate = lib.lookupFunction<_NativeCreateC, _NativeCreateDart>(
        'GMAKNativeAdCreate');
    _nativeAdDispose = lib.lookupFunction<_NativeDisposeC, _NativeDisposeDart>(
        'GMAKNativeAdDispose');
    _adaptiveBannerHeight =
        lib.lookupFunction<_AdaptiveHeightC, _AdaptiveHeightDart>(
            'GMAKAdaptiveBannerHeight');

    _preloadStart = lib.lookupFunction<_PreloadStartC, _PreloadStartDart>(
        'GMAKPreloadStart');
    _preloadPoll =
        lib.lookupFunction<_PreloadPollC, _PreloadPollDart>('GMAKPreloadPoll');
    _preloadIsAvailable = lib.lookupFunction<_PreloadQueryC, _PreloadQueryDart>(
        'GMAKPreloadIsAdAvailable');
    _preloadNumAvailable =
        lib.lookupFunction<_PreloadQueryC, _PreloadQueryDart>(
            'GMAKPreloadNumAdsAvailable');
    _preloadDestroy =
        lib.lookupFunction<_PreloadDestroyC, _PreloadDestroyDart>(
            'GMAKPreloadDestroy');
    _preloadDestroyAll =
        lib.lookupFunction<_PreloadDestroyAllC, _PreloadDestroyAllDart>(
            'GMAKPreloadDestroyAll');
    _preloadReadJson =
        lib.lookupFunction<_ReadJsonC, _ReadJsonDart>('GMAKPreloadReadJson');

    // Register the view provider that backs banners and native ads.
    //
    // iOS only. Android registers its providers from the plugin class, which
    // the generated registrant instantiates; iOS has no such hook, so the pod
    // is never entered unless Dart calls into it (`doc/design.md` §12-1).
    if (Platform.isIOS) {
      lib.lookupFunction<Void Function(), void Function()>(
        'GMAKRegisterProvider',
      )();
    }

    _loaded = true;

    // Hand over the single callback pointer. The native side stores it in a
    // slot and re-reads that slot before every fire, so a hot restart that
    // zeroes the slot cannot dispatch into a dead isolate (design.md §5-2).
    _setDispatcher(_dispatchPtr.address);
  }

  /// Reserves a token and routes that token's events to [sink].
  ///
  /// The token identifies one ad object for its whole lifetime — load, show and
  /// dispose all take it — so the caller must [release] it when done.
  static int registerSink(AdEventSink sink) {
    final int token = _nextToken++;
    _sinks[token] = sink;
    return token;
  }

  /// Stops routing events for [token].
  ///
  /// Late events for a released token are dropped, which is exactly what should
  /// happen after the Dart-side ad object is disposed.
  static void release(int token) => _sinks.remove(token);

  /// Initializes the Mobile Ads SDK, reporting completion to [token].
  ///
  /// On Android the native side moves this onto a background thread, because
  /// GMA Next-Gen's `MobileAds.initialize` ANRs when called on the main thread
  /// (`doc/design.md` §6).
  static void initialize(int token) {
    if (!_loaded) return;
    _initialize(token);
  }

  /// Requests an ad of [format] for [adUnitId], reporting events to [token].
  static void loadAd({
    required int token,
    required int format,
    required String adUnitId,
    required String requestJson,
  }) {
    if (!_loaded) return;
    final Pointer<Utf8> unitPtr = adUnitId.toNativeUtf8();
    final Pointer<Utf8> reqPtr = requestJson.toNativeUtf8();
    try {
      _loadAd(token, format, unitPtr, reqPtr);
    } finally {
      calloc.free(unitPtr);
      calloc.free(reqPtr);
    }
  }

  /// Presents the loaded full-screen ad held by [token].
  static void showAd(int token) {
    if (!_loaded) return;
    _showAd(token);
  }

  /// Releases the native ad object held by [token].
  static void disposeAd(int token) {
    if (!_loaded) return;
    _disposeAd(token);
    release(token);
  }

  /// Mutes or unmutes ad audio app-wide.
  static void setAppMuted(bool muted) {
    if (!_loaded) return;
    _setMuted(muted ? 1 : 0);
  }

  /// Sets immersive mode on the ad held by [token]. Android only.
  static void setImmersiveMode(int token, bool enabled) {
    if (!_loaded) return;
    _setImmersiveMode(token, enabled ? 1 : 0);
  }

  /// Sets server-side verification options on the rewarded ad held by [token].
  static void setServerSideVerification(
    int token,
    String userId,
    String customData,
  ) {
    if (!_loaded) return;
    final Pointer<Utf8> userPtr = userId.toNativeUtf8();
    final Pointer<Utf8> dataPtr = customData.toNativeUtf8();
    try {
      _setServerSideVerification(token, userPtr, dataPtr);
    } finally {
      calloc.free(userPtr);
      calloc.free(dataPtr);
    }
  }

  // ---------------------------------------------------------------------------
  // Banners
  // ---------------------------------------------------------------------------

  /// Registers a banner's configuration against [viewId] and requests the ad.
  ///
  /// Called from the element's `mount`, before the reconciler asks the native
  /// provider to build the view: `createView` is handed only a view type, so
  /// everything else has to be in place first, filed under the view id.
  static void bannerCreate({
    required int token,
    required int viewId,
    required String adUnitId,
    required String requestJson,
    required int widthDp,
    required int heightDp,
  }) {
    if (!_loaded) return;
    final Pointer<Utf8> unitPtr = adUnitId.toNativeUtf8();
    final Pointer<Utf8> reqPtr = requestJson.toNativeUtf8();
    try {
      _bannerCreate(token, viewId, unitPtr, reqPtr, widthDp, heightDp);
    } finally {
      calloc.free(unitPtr);
      calloc.free(reqPtr);
    }
  }

  /// Destroys the banner attached to [viewId] and releases its native AdView.
  static void bannerDispose(int viewId) {
    if (!_loaded) return;
    _bannerDispose(viewId);
  }

  // ---------------------------------------------------------------------------
  // Native ads
  // ---------------------------------------------------------------------------

  /// Registers a native ad's configuration against [viewId] and requests it.
  ///
  /// Same handover as [bannerCreate] — `createView` is given only a view type,
  /// so everything else is filed under the view id first. [optionsJson] carries
  /// whatever is not targeting: the template style or factory id, the request
  /// options, and any custom options bound for the factory.
  static void nativeAdCreate({
    required int token,
    required int viewId,
    required String adUnitId,
    required String requestJson,
    required String optionsJson,
  }) {
    if (!_loaded) return;
    final Pointer<Utf8> unitPtr = adUnitId.toNativeUtf8();
    final Pointer<Utf8> reqPtr = requestJson.toNativeUtf8();
    final Pointer<Utf8> optPtr = optionsJson.toNativeUtf8();
    try {
      _nativeAdCreate(token, viewId, unitPtr, reqPtr, optPtr);
    } finally {
      calloc.free(unitPtr);
      calloc.free(reqPtr);
      calloc.free(optPtr);
    }
  }

  /// Destroys the native ad attached to [viewId] and releases its views.
  static void nativeAdDispose(int viewId) {
    if (!_loaded) return;
    _nativeAdDispose(viewId);
  }

  /// Encodes [value] as JSON for one of the `*Json` parameters here.
  ///
  /// Exists so callers building a payload do not each import `dart:convert`,
  /// and so the encoding stays identical across them.
  static String encodeJson(Map<String, Object?> value) => jsonEncode(value);

  /// Returns the Google-optimized banner height for [widthDp], or 0.
  static int adaptiveBannerHeight(int widthDp) {
    if (!_loaded) return 0;
    return _adaptiveBannerHeight(widthDp);
  }

  // ---------------------------------------------------------------------------
  // Preloading
  //
  // The Next-Gen preloader keys everything on a caller-chosen preload id and a
  // format, so these take that pair rather than a token. An ad polled out of a
  // buffer is numbered by the native side — it exists before any Dart object
  // does — and [preloadPoll] returns that token for [replaceSink] to bind.
  // ---------------------------------------------------------------------------

  /// Points [token] at [sink], replacing any sink already registered.
  ///
  /// Used when adopting a preloaded ad: the token was reserved earlier, and the
  /// ad object that will receive its events is built afterwards.
  static void replaceSink(int token, AdEventSink sink) => _sinks[token] = sink;

  /// Starts preloading ads of [format] into the buffer named [preloadId].
  ///
  /// Preload lifecycle events are reported to [token].
  static void preloadStart({
    required int token,
    required int format,
    required String preloadId,
    required String adUnitId,
    required String requestJson,
    required int bufferSize,
  }) {
    if (!_loaded) return;
    final Pointer<Utf8> idPtr = preloadId.toNativeUtf8();
    final Pointer<Utf8> unitPtr = adUnitId.toNativeUtf8();
    final Pointer<Utf8> reqPtr = requestJson.toNativeUtf8();
    try {
      _preloadStart(token, format, idPtr, unitPtr, reqPtr, bufferSize);
    } finally {
      calloc.free(idPtr);
      calloc.free(unitPtr);
      calloc.free(reqPtr);
    }
  }

  /// Takes one preloaded ad out of the [preloadId] buffer.
  ///
  /// Returns the token the native side filed the ad under, or 0 when the buffer
  /// is empty. Synchronous, because the preloader answers from its local buffer.
  static int preloadPoll(int format, String preloadId) {
    if (!_loaded) return 0;
    final Pointer<Utf8> idPtr = preloadId.toNativeUtf8();
    try {
      return _preloadPoll(format, idPtr);
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Whether the [preloadId] buffer currently holds at least one ad.
  static bool preloadIsAdAvailable(int format, String preloadId) {
    if (!_loaded) return false;
    final Pointer<Utf8> idPtr = preloadId.toNativeUtf8();
    try {
      return _preloadIsAvailable(format, idPtr) != 0;
    } finally {
      calloc.free(idPtr);
    }
  }

  /// How many ads the [preloadId] buffer currently holds.
  static int preloadNumAdsAvailable(int format, String preloadId) {
    if (!_loaded) return 0;
    final Pointer<Utf8> idPtr = preloadId.toNativeUtf8();
    try {
      return _preloadNumAvailable(format, idPtr);
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Destroys the [preloadId] buffer and the ads still in it.
  static void preloadDestroy(int format, String preloadId) {
    if (!_loaded) return;
    final Pointer<Utf8> idPtr = preloadId.toNativeUtf8();
    try {
      _preloadDestroy(format, idPtr);
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Destroys every buffer for [format].
  static void preloadDestroyAll(int format) {
    if (!_loaded) return;
    _preloadDestroyAll(format);
  }

  /// Reads a JSON document out of the preloader.
  ///
  /// [query] says which document: see [PreloadQuery]. Returns an empty string
  /// when there is nothing to report.
  ///
  /// Grows the buffer once if the first attempt was too small — the native side
  /// reports the size it needs as a negative result rather than truncating.
  static String preloadReadJson(int format, int query, String preloadId) {
    if (!_loaded) return '';
    final Pointer<Utf8> idPtr = preloadId.toNativeUtf8();
    try {
      int capacity = 1024;
      for (int attempt = 0; attempt < 2; attempt++) {
        final Pointer<Uint8> buffer = calloc<Uint8>(capacity);
        try {
          final int written =
              _preloadReadJson(format, query, idPtr, buffer, capacity);
          if (written >= 0) {
            return written == 0
                ? ''
                : utf8.decode(buffer.asTypedList(written), allowMalformed: true);
          }
          capacity = -written;
        } finally {
          calloc.free(buffer);
        }
      }
      return '';
    } finally {
      calloc.free(idPtr);
    }
  }

  /// Routes one native event to the sink registered for [token].
  ///
  /// Called only from [_dispatch]. A malformed or absent payload is treated as
  /// an empty map rather than thrown, because this runs on the native call
  /// stack where an exception would cross the FFI boundary.
  static void _deliver(int token, int status, String raw) {
    final AdEventSink? sink = _sinks[token];
    if (sink == null) return;

    Map<String, Object?> payload = const <String, Object?>{};
    if (raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, Object?>) payload = decoded;
      } on FormatException {
        // Keep the empty payload: an event with a bad body is still an event,
        // and listeners handle missing fields.
      }
    }
    sink(status, payload);
  }
}

/// Routes an event as if it had arrived from the native dispatcher.
///
/// Exists so the token routing and payload decoding can be tested without a
/// device: everything below this point is FFI and needs real native symbols.
/// Test-only — not exported from the package's public library.
void deliverForTest(int token, int status, String payload) =>
    AdsFFIBindings._deliver(token, status, payload);

/// The one callback pointer the native side is ever given.
///
/// Must be a top-level function: `Pointer.fromFunction` cannot take a closure
/// or an instance method.
void _dispatch(int token, int status, Pointer<Utf8> raw) {
  AdsFFIBindings._deliver(
    token,
    status,
    raw == nullptr ? '' : raw.toDartString(),
  );
}

final Pointer<NativeFunction<_DispatchC>> _dispatchPtr =
    Pointer.fromFunction<_DispatchC>(_dispatch);
