/// Preloading of full-screen ads.
///
/// A preloader keeps a small buffer of ads filled in the background, so that
/// showing one is instant instead of waiting on a network round trip. Start a
/// preloader once, then poll it whenever you need an ad.
library;

import 'dart:async';
import 'dart:convert';

import 'ad_error.dart';
import 'ad_request.dart';
import 'ads_ffi_bindings.dart';
import 'app_open_ad.dart';
import 'full_screen_ad.dart';
import 'interstitial_ad.dart';
import 'rewarded_ad.dart';

/// Callbacks for ad preloading events.
class PreloadCallback {
  /// Creates a preload callback; every entry is optional.
  const PreloadCallback({
    this.onAdPreloaded,
    this.onAdsExhausted,
    this.onAdFailedToPreload,
  });

  /// Called when an ad has been preloaded into the buffer.
  final void Function(String preloadId, ResponseInfo? responseInfo)?
      onAdPreloaded;

  /// Called when the buffer has been emptied.
  ///
  /// The preloader refills on its own; this is a signal that the next poll may
  /// come back empty.
  final void Function(String preloadId)? onAdsExhausted;

  /// Called when preloading an ad failed.
  final void Function(String preloadId, AdError error)? onAdFailedToPreload;
}

/// How a preloader should fill its buffer.
class PreloadConfiguration {
  /// Creates a preload configuration for [adUnitId].
  const PreloadConfiguration({
    required this.adUnitId,
    this.request = const AdRequest(),
    this.bufferSize = 2,
  });

  /// The ad unit to preload ads for.
  final String adUnitId;

  /// Targeting information used for each request.
  final AdRequest request;

  /// How many ads to keep buffered.
  ///
  /// Keep this small: every buffered ad is an impression opportunity that
  /// expires unused if you never show it.
  final int bufferSize;

  @override
  String toString() => 'PreloadConfiguration(adUnitId: $adUnitId, '
      'bufferSize: $bufferSize)';
}

/// Shared implementation behind the per-format preloaders.
///
/// Not part of the public API — use [InterstitialAdPreloader],
/// [RewardedAdPreloader], [RewardedInterstitialAdPreloader] or
/// [AppOpenAdPreloader].
abstract final class AdPreloader {
  /// The ad unit each live preload id was started with.
  ///
  /// Polled ads are built Dart-side and need their unit id, which the native
  /// poll result does not repeat.
  static final Map<String, String> _adUnitIds = <String, String>{};

  /// Starts filling the [preloadId] buffer with ads of [format].
  static Future<void> start({
    required int format,
    required String preloadId,
    required PreloadConfiguration preloadConfiguration,
    required PreloadCallback callback,
  }) {
    AdsFFIBindings.loadSymbols();
    if (!AdsFFIBindings.isAvailable) return Future<void>.value();

    _adUnitIds[preloadId] = preloadConfiguration.adUnitId;

    final int token =
        AdsFFIBindings.registerSink((int status, Map<String, Object?> p) {
      final String id = p['preloadId'] as String? ?? preloadId;
      switch (status) {
        case AdEventStatus.adPreloaded:
          callback.onAdPreloaded?.call(
            id,
            ResponseInfo.fromJson(p['responseInfo'] as Map<String, Object?>?),
          );
        case AdEventStatus.adsExhausted:
          callback.onAdsExhausted?.call(id);
        case AdEventStatus.failedToPreload:
          callback.onAdFailedToPreload?.call(id, errorFromJson(p));
      }
    });

    AdsFFIBindings.preloadStart(
      token: token,
      format: format,
      preloadId: preloadId,
      adUnitId: preloadConfiguration.adUnitId,
      requestJson: preloadConfiguration.request.encode(),
      bufferSize: preloadConfiguration.bufferSize,
    );
    return Future<void>.value();
  }

  /// Takes one ad out of the [preloadId] buffer, or null when it is empty.
  ///
  /// [build] wraps the native handle in the format's Dart object.
  static Future<T?> pollAd<T extends FullScreenAd>({
    required int format,
    required String preloadId,
    required T Function(int token, String adUnitId, ResponseInfo? info) build,
  }) {
    AdsFFIBindings.loadSymbols();
    if (!AdsFFIBindings.isAvailable) return Future<T?>.value();

    final int token = AdsFFIBindings.preloadPoll(format, preloadId);
    if (token == 0) return Future<T?>.value();

    // Read the response info before building: it belongs to the ad that was
    // just removed, and the next peek would describe a different one.
    final ResponseInfo? info = _decodeResponseInfo(
      AdsFFIBindings.preloadReadJson(
          format, PreloadQuery.polledResponseInfo, preloadId),
    );

    return Future<T?>.value(
      build(token, _adUnitIds[preloadId] ?? '', info),
    );
  }

  /// Whether the [preloadId] buffer currently holds an ad.
  static Future<bool> isAdAvailable(int format, String preloadId) {
    AdsFFIBindings.loadSymbols();
    return Future<bool>.value(
        AdsFFIBindings.preloadIsAdAvailable(format, preloadId));
  }

  /// How many ads the [preloadId] buffer currently holds.
  static Future<int> getNumAdsAvailable(int format, String preloadId) {
    AdsFFIBindings.loadSymbols();
    return Future<int>.value(
        AdsFFIBindings.preloadNumAdsAvailable(format, preloadId));
  }

  /// Destroys the [preloadId] buffer and everything still in it.
  static Future<void> destroy(int format, String preloadId) {
    AdsFFIBindings.loadSymbols();
    _adUnitIds.remove(preloadId);
    AdsFFIBindings.preloadDestroy(format, preloadId);
    return Future<void>.value();
  }

  /// Destroys every buffer of [format].
  static Future<void> destroyAll(int format) {
    AdsFFIBindings.loadSymbols();
    _adUnitIds.clear();
    AdsFFIBindings.preloadDestroyAll(format);
    return Future<void>.value();
  }

  /// Returns the configuration the [preloadId] buffer was started with.
  static Future<PreloadConfiguration?> getConfiguration(
    int format,
    String preloadId,
  ) {
    AdsFFIBindings.loadSymbols();
    final Map<String, Object?>? json = _decodeObject(
      AdsFFIBindings.preloadReadJson(
          format, PreloadQuery.configuration, preloadId),
    );
    if (json == null) return Future<PreloadConfiguration?>.value();
    return Future<PreloadConfiguration?>.value(_configFromJson(json));
  }

  /// Returns every live configuration of [format], keyed by preload id.
  static Future<Map<String, PreloadConfiguration>> getConfigurations(
    int format,
  ) {
    AdsFFIBindings.loadSymbols();
    final Map<String, Object?>? json = _decodeObject(
      AdsFFIBindings.preloadReadJson(
          format, PreloadQuery.allConfigurations, ''),
    );
    final Map<String, PreloadConfiguration> result =
        <String, PreloadConfiguration>{};
    if (json != null) {
      json.forEach((String key, Object? value) {
        if (value is Map<String, Object?>) {
          result[key] = _configFromJson(value);
        }
      });
    }
    return Future<Map<String, PreloadConfiguration>>.value(result);
  }

  static PreloadConfiguration _configFromJson(Map<String, Object?> json) =>
      PreloadConfiguration(
        adUnitId: json['adUnitId'] as String? ?? '',
        bufferSize: json['bufferSize'] as int? ?? 0,
      );

  /// Decodes a JSON object, or null when the payload is empty or malformed.
  static Map<String, Object?>? _decodeObject(String raw) {
    if (raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static ResponseInfo? _decodeResponseInfo(String raw) =>
      ResponseInfo.fromJson(_decodeObject(raw));
}

/// Keeps a buffer of [InterstitialAd]s ready to show.
///
/// ```dart
/// await InterstitialAdPreloader.start(
///   preloadId: 'level-end',
///   preloadConfiguration: const PreloadConfiguration(
///     adUnitId: 'ca-app-pub-3940256099942544/1033173712', // test unit
///   ),
///   callback: PreloadCallback(
///     onAdPreloaded: (id, info) => debugPrint('ready: $id'),
///   ),
/// );
///
/// // Later, where an ad would otherwise have to be loaded:
/// final ad = await InterstitialAdPreloader.pollAd('level-end');
/// await ad?.show();
/// ```
abstract final class InterstitialAdPreloader {
  /// Starts filling the [preloadId] buffer.
  static Future<void> start({
    required String preloadId,
    required PreloadConfiguration preloadConfiguration,
    required PreloadCallback callback,
  }) =>
      AdPreloader.start(
        format: AdFormat.interstitial,
        preloadId: preloadId,
        preloadConfiguration: preloadConfiguration,
        callback: callback,
      );

  /// Takes one ad out of the buffer, or null when it is empty.
  static Future<InterstitialAd?> pollAd(String preloadId) =>
      AdPreloader.pollAd<InterstitialAd>(
        format: AdFormat.interstitial,
        preloadId: preloadId,
        build: (int token, String adUnitId, ResponseInfo? info) =>
            InterstitialAd.fromPreloaded(
          token: token,
          adUnitId: adUnitId,
          responseInfo: info,
        ),
      );

  /// Whether the buffer currently holds an ad.
  static Future<bool> isAdAvailable(String preloadId) =>
      AdPreloader.isAdAvailable(AdFormat.interstitial, preloadId);

  /// How many ads the buffer currently holds.
  static Future<int> getNumAdsAvailable(String preloadId) =>
      AdPreloader.getNumAdsAvailable(AdFormat.interstitial, preloadId);

  /// Destroys the [preloadId] buffer.
  static Future<void> destroy(String preloadId) =>
      AdPreloader.destroy(AdFormat.interstitial, preloadId);

  /// Destroys every interstitial buffer.
  static Future<void> destroyAll() =>
      AdPreloader.destroyAll(AdFormat.interstitial);

  /// Returns the configuration the [preloadId] buffer was started with.
  static Future<PreloadConfiguration?> getConfiguration(String preloadId) =>
      AdPreloader.getConfiguration(AdFormat.interstitial, preloadId);

  /// Returns every live interstitial configuration, keyed by preload id.
  static Future<Map<String, PreloadConfiguration>> getConfigurations() =>
      AdPreloader.getConfigurations(AdFormat.interstitial);
}

/// Keeps a buffer of [RewardedAd]s ready to show.
abstract final class RewardedAdPreloader {
  /// Starts filling the [preloadId] buffer.
  static Future<void> start({
    required String preloadId,
    required PreloadConfiguration preloadConfiguration,
    required PreloadCallback callback,
  }) =>
      AdPreloader.start(
        format: AdFormat.rewarded,
        preloadId: preloadId,
        preloadConfiguration: preloadConfiguration,
        callback: callback,
      );

  /// Takes one ad out of the buffer, or null when it is empty.
  static Future<RewardedAd?> pollAd(String preloadId) =>
      AdPreloader.pollAd<RewardedAd>(
        format: AdFormat.rewarded,
        preloadId: preloadId,
        build: (int token, String adUnitId, ResponseInfo? info) =>
            RewardedAd.fromPreloaded(
          token: token,
          adUnitId: adUnitId,
          responseInfo: info,
        ),
      );

  /// Whether the buffer currently holds an ad.
  static Future<bool> isAdAvailable(String preloadId) =>
      AdPreloader.isAdAvailable(AdFormat.rewarded, preloadId);

  /// How many ads the buffer currently holds.
  static Future<int> getNumAdsAvailable(String preloadId) =>
      AdPreloader.getNumAdsAvailable(AdFormat.rewarded, preloadId);

  /// Destroys the [preloadId] buffer.
  static Future<void> destroy(String preloadId) =>
      AdPreloader.destroy(AdFormat.rewarded, preloadId);

  /// Destroys every rewarded buffer.
  static Future<void> destroyAll() => AdPreloader.destroyAll(AdFormat.rewarded);

  /// Returns the configuration the [preloadId] buffer was started with.
  static Future<PreloadConfiguration?> getConfiguration(String preloadId) =>
      AdPreloader.getConfiguration(AdFormat.rewarded, preloadId);

  /// Returns every live rewarded configuration, keyed by preload id.
  static Future<Map<String, PreloadConfiguration>> getConfigurations() =>
      AdPreloader.getConfigurations(AdFormat.rewarded);
}

/// Keeps a buffer of [RewardedInterstitialAd]s ready to show.
///
/// `google_mobile_ads` has no equivalent — the Next-Gen SDK supports it, so it
/// is offered here too.
abstract final class RewardedInterstitialAdPreloader {
  /// Starts filling the [preloadId] buffer.
  static Future<void> start({
    required String preloadId,
    required PreloadConfiguration preloadConfiguration,
    required PreloadCallback callback,
  }) =>
      AdPreloader.start(
        format: AdFormat.rewardedInterstitial,
        preloadId: preloadId,
        preloadConfiguration: preloadConfiguration,
        callback: callback,
      );

  /// Takes one ad out of the buffer, or null when it is empty.
  static Future<RewardedInterstitialAd?> pollAd(String preloadId) =>
      AdPreloader.pollAd<RewardedInterstitialAd>(
        format: AdFormat.rewardedInterstitial,
        preloadId: preloadId,
        build: (int token, String adUnitId, ResponseInfo? info) =>
            RewardedInterstitialAd.fromPreloaded(
          token: token,
          adUnitId: adUnitId,
          responseInfo: info,
        ),
      );

  /// Whether the buffer currently holds an ad.
  static Future<bool> isAdAvailable(String preloadId) =>
      AdPreloader.isAdAvailable(AdFormat.rewardedInterstitial, preloadId);

  /// How many ads the buffer currently holds.
  static Future<int> getNumAdsAvailable(String preloadId) =>
      AdPreloader.getNumAdsAvailable(AdFormat.rewardedInterstitial, preloadId);

  /// Destroys the [preloadId] buffer.
  static Future<void> destroy(String preloadId) =>
      AdPreloader.destroy(AdFormat.rewardedInterstitial, preloadId);

  /// Destroys every rewarded interstitial buffer.
  static Future<void> destroyAll() =>
      AdPreloader.destroyAll(AdFormat.rewardedInterstitial);

  /// Returns the configuration the [preloadId] buffer was started with.
  static Future<PreloadConfiguration?> getConfiguration(String preloadId) =>
      AdPreloader.getConfiguration(AdFormat.rewardedInterstitial, preloadId);

  /// Returns every live rewarded interstitial configuration.
  static Future<Map<String, PreloadConfiguration>> getConfigurations() =>
      AdPreloader.getConfigurations(AdFormat.rewardedInterstitial);
}

/// Keeps a buffer of [AppOpenAd]s ready to show.
abstract final class AppOpenAdPreloader {
  /// Starts filling the [preloadId] buffer.
  static Future<void> start({
    required String preloadId,
    required PreloadConfiguration preloadConfiguration,
    required PreloadCallback callback,
  }) =>
      AdPreloader.start(
        format: AdFormat.appOpen,
        preloadId: preloadId,
        preloadConfiguration: preloadConfiguration,
        callback: callback,
      );

  /// Takes one ad out of the buffer, or null when it is empty.
  static Future<AppOpenAd?> pollAd(String preloadId) =>
      AdPreloader.pollAd<AppOpenAd>(
        format: AdFormat.appOpen,
        preloadId: preloadId,
        build: (int token, String adUnitId, ResponseInfo? info) =>
            AppOpenAd.fromPreloaded(
          token: token,
          adUnitId: adUnitId,
          responseInfo: info,
        ),
      );

  /// Whether the buffer currently holds an ad.
  static Future<bool> isAdAvailable(String preloadId) =>
      AdPreloader.isAdAvailable(AdFormat.appOpen, preloadId);

  /// How many ads the buffer currently holds.
  static Future<int> getNumAdsAvailable(String preloadId) =>
      AdPreloader.getNumAdsAvailable(AdFormat.appOpen, preloadId);

  /// Destroys the [preloadId] buffer.
  static Future<void> destroy(String preloadId) =>
      AdPreloader.destroy(AdFormat.appOpen, preloadId);

  /// Destroys every app open buffer.
  static Future<void> destroyAll() => AdPreloader.destroyAll(AdFormat.appOpen);

  /// Returns the configuration the [preloadId] buffer was started with.
  static Future<PreloadConfiguration?> getConfiguration(String preloadId) =>
      AdPreloader.getConfiguration(AdFormat.appOpen, preloadId);

  /// Returns every live app open configuration, keyed by preload id.
  static Future<Map<String, PreloadConfiguration>> getConfigurations() =>
      AdPreloader.getConfigurations(AdFormat.appOpen);
}
