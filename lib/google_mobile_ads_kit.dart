/// Google Mobile Ads (AdMob) for DartNative apps.
///
/// Wraps the native Google Mobile Ads SDKs over `dart:ffi` — no platform
/// channels. The public API follows `google_mobile_ads` so that porting from
/// Flutter is mostly mechanical; see `doc/migration_from_flutter.md`.
///
/// Add the plugin to your pubspec and run `dn pub get`. The generated
/// `dartnative_plugin_registrant.dart` calls [initializeMobileAdsPlugin] for
/// you, so no per-app setup is needed beyond your AdMob App ID in the native
/// projects (see the README).
///
/// ```dart
/// void main() {
///   DartNativePluginRegistrant.registerAll();
///   MobileAds.instance.initialize();
///   runApp(const MyApp());
/// }
/// ```
library;

import 'src/ads_ffi_bindings.dart';
import 'src/banner_ad.dart' show registerBannerAdElementFactory;
import 'src/native_ad.dart' show registerNativeAdElementFactory;

export 'src/ad_base.dart' show Ad;
export 'src/ad_error.dart' show AdError, LoadAdError, ResponseInfo;
export 'src/ad_listener.dart'
    show
        AdEventCallback,
        AdLoadErrorCallback,
        AdWithViewListener,
        AdWithoutViewListener,
        BannerAdListener,
        FullScreenAdLoadCallback,
        FullScreenAdLoadErrorCallback,
        FullScreenContentCallback,
        GenericAdEventCallback,
        NativeAdListener,
        OnPaidEventCallback,
        OnUserEarnedRewardCallback,
        PrecisionType,
        RewardItem;
export 'src/ad_preloader.dart'
    show
        AppOpenAdPreloader,
        InterstitialAdPreloader,
        PreloadCallback,
        PreloadConfiguration,
        RewardedAdPreloader,
        RewardedInterstitialAdPreloader;
export 'src/ad_request.dart' show AdRequest;
export 'src/ad_size.dart' show AdSize, AnchoredAdaptiveBannerAdSize;
export 'src/app_open_ad.dart' show AppOpenAd, AppOpenAdLoadCallback;
export 'src/banner_ad.dart' show BannerAd;
export 'src/full_screen_ad.dart' show FullScreenAd;
export 'src/interstitial_ad.dart'
    show InterstitialAd, InterstitialAdLoadCallback;
export 'src/mobile_ads.dart'
    show
        AdapterInitializationState,
        AdapterStatus,
        InitializationStatus,
        MobileAds;
export 'src/native_ad.dart' show NativeAd;
export 'src/native_ad_options.dart'
    show
        AdChoicesPlacement,
        MediaAspectRatio,
        NativeAdOptions,
        VideoOptions;
export 'src/native_template_style.dart'
    show
        NativeTemplateFontStyle,
        NativeTemplateStyle,
        NativeTemplateTextStyle,
        TemplateType;
export 'src/rewarded_ad.dart'
    show
        RewardedAd,
        RewardedAdLoadCallback,
        RewardedInterstitialAd,
        RewardedInterstitialAdLoadCallback,
        ServerSideVerificationOptions;

/// Loads the plugin's FFI symbols and registers its widget element factories.
///
/// Invoked by the generated plugin registrant at startup — apps do not call
/// this directly. Safe to call more than once.
///
/// On platforms without a Mobile Ads SDK (web, desktop) this returns without
/// doing anything, so shared code keeps running there.
void initializeMobileAdsPlugin() {
  AdsFFIBindings.loadSymbols();
  registerBannerAdElementFactory();
  registerNativeAdElementFactory();
}
