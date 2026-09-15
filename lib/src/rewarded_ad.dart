/// Rewarded and rewarded interstitial ads.
library;

import 'dart:async';

import 'ad_error.dart';
import 'ad_listener.dart';
import 'ad_request.dart';
import 'ads_ffi_bindings.dart';
import 'full_screen_ad.dart';

/// Builds a [RewardItem] from a native `userEarnedReward` payload.
RewardItem _rewardFromJson(Map<String, Object?> json) => RewardItem(
      json['amount'] as num? ?? 0,
      json['type'] as String? ?? '',
    );

/// Adds reward delivery to the shared full-screen event routing.
///
/// `show` takes the reward callback rather than the constructor, matching
/// `google_mobile_ads`, so the callback is stored until the event arrives.
mixin _RewardEvents on FullScreenAd {
  /// Called when the user earns a reward, set by `show`.
  OnUserEarnedRewardCallback? onUserEarnedRewardCallback;

  @override
  void handleEvent(int status, Map<String, Object?> payload) {
    if (status == AdEventStatus.userEarnedReward) {
      onUserEarnedRewardCallback?.call(this, _rewardFromJson(payload));
      return;
    }
    super.handleEvent(status, payload);
  }
}

/// Options for rewarded server-side verification callbacks.
///
/// See https://developers.google.com/admob/android/rewarded-video-ssv.
class ServerSideVerificationOptions {
  /// Creates verification options.
  const ServerSideVerificationOptions({this.userId, this.customData});

  /// The user id sent in the server-to-server reward callback.
  final String? userId;

  /// Custom data sent in the server-to-server reward callback.
  final String? customData;

  @override
  String toString() =>
      'ServerSideVerificationOptions(userId: $userId, customData: $customData)';
}

/// A full-screen video ad that rewards the user for watching it.
///
/// ```dart
/// RewardedAd.load(
///   adUnitId: 'ca-app-pub-3940256099942544/5224354917', // test unit
///   request: const AdRequest(),
///   rewardedAdLoadCallback: RewardedAdLoadCallback(
///     onAdLoaded: (ad) {
///       ad.show(onUserEarnedReward: (ad, reward) {
///         grantCoins(reward.amount);
///       });
///     },
///     onAdFailedToLoad: (error) => debugPrint('load failed: $error'),
///   ),
/// );
/// ```
///
/// Grant the reward only from the `onUserEarnedReward` callback — it fires when
/// the user has actually watched enough of the ad.
class RewardedAd extends FullScreenAd with _RewardEvents {
  RewardedAd._({required super.adUnitId});

  /// Requests a rewarded ad for [adUnitId].
  static Future<void> load({
    required String adUnitId,
    required AdRequest request,
    required RewardedAdLoadCallback rewardedAdLoadCallback,
  }) {
    return loadFullScreenAd<RewardedAd>(
      format: AdFormat.rewarded,
      adUnitId: adUnitId,
      request: request,
      buildAd: () => RewardedAd._(adUnitId: adUnitId),
      onLoaded: rewardedAdLoadCallback.onAdLoaded,
      onFailed: rewardedAdLoadCallback.onAdFailedToLoad,
    );
  }

  /// Builds a [RewardedAd] around an ad the preloader already holds.
  static RewardedAd fromPreloaded({
    required int token,
    required String adUnitId,
    required ResponseInfo? responseInfo,
  }) {
    return adoptPreloadedAd<RewardedAd>(
      token: token,
      responseInfo: responseInfo,
      buildAd: () => RewardedAd._(adUnitId: adUnitId),
    );
  }

  /// Presents the ad, calling [onUserEarnedReward] once the reward is granted.
  ///
  /// The reward callback fires at most once, and only if the user watches
  /// enough of the ad.
  Future<void> show({required OnUserEarnedRewardCallback onUserEarnedReward}) {
    onUserEarnedRewardCallback = onUserEarnedReward;
    return present();
  }

  /// Sets the server-side verification options for this ad.
  ///
  /// Call before [show].
  Future<void> setServerSideOptions(ServerSideVerificationOptions options) {
    final int? t = token;
    if (t == null) return Future<void>.value();
    AdsFFIBindings.setServerSideVerification(
      t,
      options.userId ?? '',
      options.customData ?? '',
    );
    return Future<void>.value();
  }
}

/// Receives the outcome of a [RewardedAd] load.
class RewardedAdLoadCallback extends FullScreenAdLoadCallback<RewardedAd> {
  /// Creates a load callback for a [RewardedAd].
  const RewardedAdLoadCallback({
    required super.onAdLoaded,
    required super.onAdFailedToLoad,
  });
}

/// A rewarded ad that can also be shown without an opt-in prompt.
///
/// Behaves like [RewardedAd]; the difference is in how AdMob serves it. You
/// must show a reward announcement before it appears — see the AdMob docs.
class RewardedInterstitialAd extends FullScreenAd with _RewardEvents {
  RewardedInterstitialAd._({required super.adUnitId});

  /// Requests a rewarded interstitial ad for [adUnitId].
  static Future<void> load({
    required String adUnitId,
    required AdRequest request,
    required RewardedInterstitialAdLoadCallback
        rewardedInterstitialAdLoadCallback,
  }) {
    return loadFullScreenAd<RewardedInterstitialAd>(
      format: AdFormat.rewardedInterstitial,
      adUnitId: adUnitId,
      request: request,
      buildAd: () => RewardedInterstitialAd._(adUnitId: adUnitId),
      onLoaded: rewardedInterstitialAdLoadCallback.onAdLoaded,
      onFailed: rewardedInterstitialAdLoadCallback.onAdFailedToLoad,
    );
  }

  /// Builds a [RewardedInterstitialAd] around an ad the preloader already holds.
  static RewardedInterstitialAd fromPreloaded({
    required int token,
    required String adUnitId,
    required ResponseInfo? responseInfo,
  }) {
    return adoptPreloadedAd<RewardedInterstitialAd>(
      token: token,
      responseInfo: responseInfo,
      buildAd: () => RewardedInterstitialAd._(adUnitId: adUnitId),
    );
  }

  /// Presents the ad, calling [onUserEarnedReward] once the reward is granted.
  Future<void> show({required OnUserEarnedRewardCallback onUserEarnedReward}) {
    onUserEarnedRewardCallback = onUserEarnedReward;
    return present();
  }

  /// Sets the server-side verification options for this ad.
  ///
  /// Call before [show].
  Future<void> setServerSideOptions(ServerSideVerificationOptions options) {
    final int? t = token;
    if (t == null) return Future<void>.value();
    AdsFFIBindings.setServerSideVerification(
      t,
      options.userId ?? '',
      options.customData ?? '',
    );
    return Future<void>.value();
  }
}

/// Receives the outcome of a [RewardedInterstitialAd] load.
class RewardedInterstitialAdLoadCallback
    extends FullScreenAdLoadCallback<RewardedInterstitialAd> {
  /// Creates a load callback for a [RewardedInterstitialAd].
  const RewardedInterstitialAdLoadCallback({
    required super.onAdLoaded,
    required super.onAdFailedToLoad,
  });
}
