/// Interstitial ads.
library;

import 'dart:async';

import 'ad_error.dart';
import 'ad_listener.dart';
import 'ad_request.dart';
import 'ads_ffi_bindings.dart';
import 'full_screen_ad.dart';

/// A full-screen ad shown at a natural break in your app.
///
/// Load an ad, then show it when the user reaches a transition point:
///
/// ```dart
/// InterstitialAd.load(
///   adUnitId: 'ca-app-pub-3940256099942544/1033173712', // test unit
///   request: const AdRequest(),
///   adLoadCallback: InterstitialAdLoadCallback(
///     onAdLoaded: (ad) {
///       ad.fullScreenContentCallback = FullScreenContentCallback(
///         onAdDismissedFullScreenContent: (ad) => ad.dispose(),
///         onAdFailedToShowFullScreenContent: (ad, error) => ad.dispose(),
///       );
///       ad.show();
///     },
///     onAdFailedToLoad: (error) => debugPrint('load failed: $error'),
///   ),
/// );
/// ```
///
/// Loading takes time, so request the ad well before you intend to show it.
/// An ad can be shown once; dispose it afterwards and load another.
///
/// To have ads ready without managing the timing yourself, see
/// [InterstitialAdPreloader].
class InterstitialAd extends FullScreenAd {
  InterstitialAd._({required super.adUnitId});

  /// Presents the ad.
  ///
  /// Call at most once per loaded ad. Dispose it from
  /// [FullScreenContentCallback.onAdDismissedFullScreenContent] and load
  /// another.
  Future<void> show() => present();

  /// Requests an interstitial ad for [adUnitId].
  ///
  /// Exactly one of [adLoadCallback]'s two callbacks fires.
  static Future<void> load({
    required String adUnitId,
    required AdRequest request,
    required InterstitialAdLoadCallback adLoadCallback,
  }) {
    return loadFullScreenAd<InterstitialAd>(
      format: AdFormat.interstitial,
      adUnitId: adUnitId,
      request: request,
      buildAd: () => InterstitialAd._(adUnitId: adUnitId),
      onLoaded: adLoadCallback.onAdLoaded,
      onFailed: adLoadCallback.onAdFailedToLoad,
    );
  }

  /// Builds an [InterstitialAd] around an ad the preloader already holds.
  static InterstitialAd fromPreloaded({
    required int token,
    required String adUnitId,
    required ResponseInfo? responseInfo,
  }) {
    return adoptPreloadedAd<InterstitialAd>(
      token: token,
      responseInfo: responseInfo,
      buildAd: () => InterstitialAd._(adUnitId: adUnitId),
    );
  }
}

/// Receives the outcome of an [InterstitialAd] load.
class InterstitialAdLoadCallback
    extends FullScreenAdLoadCallback<InterstitialAd> {
  /// Creates a load callback for an [InterstitialAd].
  const InterstitialAdLoadCallback({
    required super.onAdLoaded,
    required super.onAdFailedToLoad,
  });
}
