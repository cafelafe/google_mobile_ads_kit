/// Listener types, mirroring `google_mobile_ads`.
library;

import 'ad_error.dart';
import 'ad_base.dart';

/// Called when an ad event occurs that carries only the ad itself.
typedef AdEventCallback = void Function(Ad ad);

/// Called when an ad fails to load.
typedef AdLoadErrorCallback = void Function(Ad ad, LoadAdError error);

/// Called when the user earns a reward from a rewarded ad.
typedef OnUserEarnedRewardCallback = void Function(
    Ad ad, RewardItem rewardItem);

/// Called when an ad is estimated to have earned money.
///
/// Available for allowlisted AdMob accounts only.
typedef OnPaidEventCallback = void Function(
  Ad ad,
  double valueMicros,
  PrecisionType precision,
  String currencyCode,
);

/// How precise the value reported by an [OnPaidEventCallback] is.
enum PrecisionType {
  /// An ad value with unknown precision.
  unknown,

  /// An ad value estimated from aggregated data.
  estimated,

  /// A publisher-provided ad value, such as manual CPMs in a mediation group.
  publisherProvided,

  /// The precise value paid for this ad.
  precise,
}

/// A reward granted by a rewarded or rewarded interstitial ad.
class RewardItem {
  /// Creates a reward of [amount] units of [type].
  const RewardItem(this.amount, this.type);

  /// How many units of [type] the user earned.
  ///
  /// Configured on the ad unit in the AdMob console.
  final num amount;

  /// The name of the reward, for example `coins`.
  final String type;

  @override
  String toString() => 'RewardItem(amount: $amount, type: $type)';
}

/// Callbacks for the lifecycle of an ad that has an in-line view.
///
/// Subclassed by [BannerAdListener]; not used directly.
abstract class AdWithViewListener {
  /// Creates a listener, used by subclasses. Every callback is optional.
  const AdWithViewListener({
    this.onAdLoaded,
    this.onAdFailedToLoad,
    this.onAdOpened,
    this.onAdWillDismissScreen,
    this.onAdClosed,
    this.onAdImpression,
    this.onAdClicked,
    this.onPaidEvent,
  });

  /// Called when an ad is received and ready to display.
  final AdEventCallback? onAdLoaded;

  /// Called when the request failed. Dispose the ad here.
  final AdLoadErrorCallback? onAdFailedToLoad;

  /// Called when the ad opens a full-screen overlay over your app.
  ///
  /// Pause animations and anything time-sensitive.
  final AdEventCallback? onAdOpened;

  /// Called before that overlay is dismissed. iOS only.
  final AdEventCallback? onAdWillDismissScreen;

  /// Called once the overlay has closed. Resume whatever [onAdOpened] paused.
  final AdEventCallback? onAdClosed;

  /// Called when the ad records an impression.
  final AdEventCallback? onAdImpression;

  /// Called when the user clicks the ad.
  final AdEventCallback? onAdClicked;

  /// Called when the ad is estimated to have earned money.
  ///
  /// Available for allowlisted AdMob accounts only.
  final OnPaidEventCallback? onPaidEvent;
}

/// Callbacks for the lifecycle of a banner ad.
///
/// Typically you handle [onAdLoaded] and [onAdFailedToLoad]:
///
/// ```dart
/// BannerAdListener(
///   onAdLoaded: (ad) => debugPrint('loaded'),
///   onAdFailedToLoad: (ad, error) {
///     ad.dispose();
///     debugPrint('failed: $error');
///   },
/// )
/// ```
class BannerAdListener extends AdWithViewListener {
  /// Creates a banner listener; every callback is optional.
  const BannerAdListener({
    super.onAdLoaded,
    super.onAdFailedToLoad,
    super.onAdOpened,
    super.onAdWillDismissScreen,
    super.onAdClosed,
    super.onAdImpression,
    super.onAdClicked,
    super.onPaidEvent,
  });
}

/// Callbacks for the lifecycle of a native ad.
///
/// Same shape as [BannerAdListener] — a native ad is also an ad with an
/// in-line view — so the two are interchangeable at the call site:
///
/// ```dart
/// NativeAdListener(
///   onAdLoaded: (ad) => debugPrint('loaded'),
///   onAdFailedToLoad: (ad, error) => debugPrint('failed: $error'),
/// )
/// ```
class NativeAdListener extends AdWithViewListener {
  /// Creates a native ad listener; every callback is optional.
  const NativeAdListener({
    super.onAdLoaded,
    super.onAdFailedToLoad,
    super.onAdOpened,
    super.onAdWillDismissScreen,
    super.onAdClosed,
    super.onAdImpression,
    super.onAdClicked,
    super.onPaidEvent,
  });
}

/// Callbacks shared by every ad format.
class AdWithoutViewListener {
  /// Creates a listener; every callback is optional.
  const AdWithoutViewListener({
    this.onAdImpression,
    this.onAdClicked,
  });

  /// Called when the ad records an impression.
  final AdEventCallback? onAdImpression;

  /// Called when the user clicks the ad.
  final AdEventCallback? onAdClicked;
}

/// Callbacks for the lifecycle of a full-screen ad, after it has loaded.
///
/// Set this on the ad object itself via
/// [InterstitialAd.fullScreenContentCallback]. Loading is reported separately,
/// through the callback passed to `load`.
class FullScreenContentCallback<T extends Ad> {
  /// Creates a callback set; every entry is optional.
  const FullScreenContentCallback({
    this.onAdShowedFullScreenContent,
    this.onAdFailedToShowFullScreenContent,
    this.onAdDismissedFullScreenContent,
    this.onAdImpression,
    this.onAdClicked,
  });

  /// Called when the ad has covered the screen.
  final void Function(T ad)? onAdShowedFullScreenContent;

  /// Called when the ad could not be shown.
  ///
  /// The ad is spent either way: dispose it and load a new one.
  final void Function(T ad, AdError error)? onAdFailedToShowFullScreenContent;

  /// Called when the user dismissed the ad and returned to the app.
  ///
  /// Dispose the ad here and preload the next one.
  final void Function(T ad)? onAdDismissedFullScreenContent;

  /// Called when the ad records an impression.
  final void Function(T ad)? onAdImpression;

  /// Called when the user clicks the ad.
  final void Function(T ad)? onAdClicked;
}

/// Called when an ad of type `T` finishes loading.
typedef GenericAdEventCallback<T> = void Function(T ad);

/// Called when a full-screen ad fails to load.
typedef FullScreenAdLoadErrorCallback = void Function(LoadAdError error);

/// Receives the outcome of a full-screen ad load.
///
/// Exactly one of the two callbacks fires per load attempt. Each format has its
/// own subclass so that `onAdLoaded` receives that format's concrete type.
abstract class FullScreenAdLoadCallback<T> {
  /// Creates a load callback, used by subclasses.
  const FullScreenAdLoadCallback({
    required this.onAdLoaded,
    required this.onAdFailedToLoad,
  });

  /// Called with the loaded ad, which is now ready to show.
  final GenericAdEventCallback<T> onAdLoaded;

  /// Called when the request failed. No ad object is produced.
  final FullScreenAdLoadErrorCallback onAdFailedToLoad;
}
