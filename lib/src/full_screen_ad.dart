/// Shared machinery for the full-screen ad formats.
///
/// Interstitial, rewarded, rewarded interstitial and app open ads differ only
/// in their format id and in whether they grant a reward, so the load flow and
/// the event routing live here once.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'ad_base.dart';
import 'ad_error.dart';
import 'ad_listener.dart';
import 'ad_request.dart';
import 'ads_ffi_bindings.dart';

/// Base class for ads that cover the screen.
///
/// Not intended for direct use — see `InterstitialAd`, `RewardedAd`,
/// `RewardedInterstitialAd` and `AppOpenAd`.
abstract class FullScreenAd extends Ad {
  /// Creates a full-screen ad for [adUnitId].
  FullScreenAd({required super.adUnitId});

  /// Callbacks for the presentation lifecycle.
  ///
  /// Set this after the ad loads and before calling `show`.
  FullScreenContentCallback<FullScreenAd>? fullScreenContentCallback;

  /// Called when the ad is estimated to have earned money.
  ///
  /// Available for allowlisted AdMob accounts only; on other accounts it never
  /// fires.
  OnPaidEventCallback? onPaidEvent;

  /// Sets whether this ad shows in immersive mode.
  ///
  /// Android only — a no-op on every other platform, matching
  /// `google_mobile_ads`. See
  /// https://developer.android.com/training/system-ui/immersive.
  Future<void> setImmersiveMode(bool immersiveModeEnabled) {
    if (!Platform.isAndroid) return Future<void>.value();
    final int? t = token;
    if (t == null) return Future<void>.value();
    AdsFFIBindings.setImmersiveMode(t, immersiveModeEnabled);
    return Future<void>.value();
  }

  /// Presents the ad.
  ///
  /// Subclasses expose this under their format's public signature — rewarded
  /// formats take the reward callback, so they cannot share one `show()`.
  ///
  /// Call at most once per loaded ad: an ad that has been shown is spent, and
  /// showing it again does nothing. Dispose it in
  /// [FullScreenContentCallback.onAdDismissedFullScreenContent] and load
  /// another.
  Future<void> present() {
    final int? t = token;
    if (t == null) return Future<void>.value();
    AdsFFIBindings.showAd(t);
    return Future<void>.value();
  }

  /// Routes one native event to this ad's callbacks.
  ///
  /// Subclasses override this to add format-specific events (the reward, for
  /// rewarded formats) and call `super` for the rest.
  void handleEvent(int status, Map<String, Object?> payload) {
    if (status == AdEventStatus.paidEvent) {
      onPaidEvent?.call(
        this,
        (payload['valueMicros'] as num? ?? 0).toDouble(),
        _precisionFromInt(payload['precision'] as int? ?? 0),
        payload['currencyCode'] as String? ?? '',
      );
      return;
    }

    final FullScreenContentCallback<FullScreenAd>? cb =
        fullScreenContentCallback;
    if (cb == null) return;

    switch (status) {
      case AdEventStatus.showed:
        cb.onAdShowedFullScreenContent?.call(this);
      case AdEventStatus.failedToShow:
        cb.onAdFailedToShowFullScreenContent?.call(this, errorFromJson(payload));
      case AdEventStatus.dismissed:
        cb.onAdDismissedFullScreenContent?.call(this);
      case AdEventStatus.impression:
        cb.onAdImpression?.call(this);
      case AdEventStatus.clicked:
        cb.onAdClicked?.call(this);
    }
  }
}

/// Maps the native precision ordinal onto [PrecisionType].
///
/// An unknown value degrades to [PrecisionType.unknown] rather than throwing:
/// a new SDK enum member must not crash a paid-event listener.
PrecisionType _precisionFromInt(int value) =>
    value >= 0 && value < PrecisionType.values.length
        ? PrecisionType.values[value]
        : PrecisionType.unknown;

/// Builds an [AdError] from a native event payload.
///
/// Missing fields fall back to neutral values rather than throwing: an error
/// path must not itself fail.
AdError errorFromJson(Map<String, Object?> json) => AdError(
      json['code'] as int? ?? -1,
      json['domain'] as String? ?? '',
      json['message'] as String? ?? '',
    );

/// Builds a [LoadAdError] from a native event payload.
LoadAdError loadErrorFromJson(Map<String, Object?> json) => LoadAdError(
      json['code'] as int? ?? -1,
      json['domain'] as String? ?? '',
      json['message'] as String? ?? '',
      ResponseInfo.fromJson(json['responseInfo'] as Map<String, Object?>?),
    );

/// Issues a load request and wires the resulting ad to its callbacks.
///
/// [buildAd] creates the format's Dart object once the load succeeds;
/// [onLoaded] and [onFailed] report the outcome. The sink stays registered
/// after a successful load so the ad keeps receiving presentation events, and
/// is released on failure since no ad object exists to own it.
Future<void> loadFullScreenAd<T extends FullScreenAd>({
  required int format,
  required String adUnitId,
  required AdRequest request,
  required T Function() buildAd,
  required void Function(T ad) onLoaded,
  required void Function(LoadAdError error) onFailed,
}) {
  AdsFFIBindings.loadSymbols();
  if (!AdsFFIBindings.isAvailable) {
    // Unsupported platform: report a failure rather than hanging, so callers
    // fall through to their no-ad path (design.md §1-2).
    onFailed(const LoadAdError(
      -1,
      'dartnative_mobile_ads',
      'The Mobile Ads SDK is not available on this platform.',
      null,
    ));
    return Future<void>.value();
  }

  T? ad;
  late final int token;
  token = AdsFFIBindings.registerSink((int status, Map<String, Object?> p) {
    switch (status) {
      case AdEventStatus.loaded:
        final T created = buildAd()
          ..token = token
          ..responseInfo =
              ResponseInfo.fromJson(p['responseInfo'] as Map<String, Object?>?);
        ad = created;
        onLoaded(created);
      case AdEventStatus.failedToLoad:
        AdsFFIBindings.release(token);
        onFailed(loadErrorFromJson(p));
      default:
        ad?.handleEvent(status, p);
    }
  });

  AdsFFIBindings.loadAd(
    token: token,
    format: format,
    adUnitId: adUnitId,
    requestJson: request.encode(),
  );
  return Future<void>.value();
}

/// Adopts an ad that the native side already holds under [token].
///
/// Used by the preloaders, where the native object exists before any Dart
/// object does: the ad is built around the existing handle and its event sink
/// registered against that same token.
T adoptPreloadedAd<T extends FullScreenAd>({
  required int token,
  required T Function() buildAd,
  required ResponseInfo? responseInfo,
}) {
  late final T ad;
  AdsFFIBindings.replaceSink(token, (int status, Map<String, Object?> p) {
    ad.handleEvent(status, p);
  });
  ad = buildAd()
    ..token = token
    ..responseInfo = responseInfo;
  return ad;
}
