/// App open ads.
library;

import 'dart:async';

import 'ad_error.dart';
import 'ad_listener.dart';
import 'ad_request.dart';
import 'ads_ffi_bindings.dart';
import 'full_screen_ad.dart';

/// A full-screen ad shown while your app is loading, or on return to the
/// foreground.
///
/// ```dart
/// AppOpenAd.load(
///   adUnitId: 'ca-app-pub-3940256099942544/9257395921', // test unit
///   request: const AdRequest(),
///   adLoadCallback: AppOpenAdLoadCallback(
///     onAdLoaded: (ad) => _pendingAd = ad,
///     onAdFailedToLoad: (error) => debugPrint('load failed: $error'),
///   ),
/// );
/// ```
///
/// AdMob expires an app open ad four hours after it loads. Record the load time
/// and discard an ad older than that rather than showing a stale one.
///
/// Show it only on a cold start or a foreground return — never over content the
/// user is already interacting with.
class AppOpenAd extends FullScreenAd {
  AppOpenAd._({required super.adUnitId});

  /// Requests an app open ad for [adUnitId].
  static Future<void> load({
    required String adUnitId,
    required AdRequest request,
    required AppOpenAdLoadCallback adLoadCallback,
  }) {
    return loadFullScreenAd<AppOpenAd>(
      format: AdFormat.appOpen,
      adUnitId: adUnitId,
      request: request,
      buildAd: () => AppOpenAd._(adUnitId: adUnitId),
      onLoaded: adLoadCallback.onAdLoaded,
      onFailed: adLoadCallback.onAdFailedToLoad,
    );
  }

  /// Builds an [AppOpenAd] around an ad the preloader already holds.
  static AppOpenAd fromPreloaded({
    required int token,
    required String adUnitId,
    required ResponseInfo? responseInfo,
  }) {
    return adoptPreloadedAd<AppOpenAd>(
      token: token,
      responseInfo: responseInfo,
      buildAd: () => AppOpenAd._(adUnitId: adUnitId),
    );
  }

  /// Presents the ad.
  ///
  /// Call at most once per loaded ad. Dispose it from
  /// [FullScreenContentCallback.onAdDismissedFullScreenContent] and preload the
  /// next one.
  Future<void> show() => present();
}

/// Receives the outcome of an [AppOpenAd] load.
class AppOpenAdLoadCallback extends FullScreenAdLoadCallback<AppOpenAd> {
  /// Creates a load callback for an [AppOpenAd].
  const AppOpenAdLoadCallback({
    required super.onAdLoaded,
    required super.onAdFailedToLoad,
  });
}
