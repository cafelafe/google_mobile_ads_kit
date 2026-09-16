# CHANGELOG

## 0.1.0

Initial release: Google Mobile Ads (AdMob) for DartNative, over `dart:ffi`. The public API follows `google_mobile_ads`.

- `BannerAd` goes straight into the widget tree — no `AdWidget`, no manual `load()`. Fixed sizes (`AdSize.banner`, `largeBanner`, `mediumRectangle`, `fullBanner`, `leaderboard`) and anchored adaptive sizing via the synchronous `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)`; the `Future` form `getAnchoredAdaptiveBannerAdSize(width)` is kept so ported code compiles.
- `NativeAd` in the widget tree, rendered by a built-in template (`TemplateType.small` / `.medium`, styled with `NativeTemplateStyle`) or by a `NativeAdFactory` registered natively and named with `factoryId`. `NativeAdOptions` for media aspect ratio, AdChoices placement and video options; `customOptions` reaches the factory.
- Native ad factory registration takes a `Context` (`GoogleMobileAdsKitPlugin.registerNativeAdFactory(context, id, factory)`) on Android and `GMAKMobileAds.registerNativeAdFactory(_:factory:)` on iOS. The factory body and the Dart call are unchanged from `google_mobile_ads`.
- Template colours are 32-bit ARGB `int`s rather than `dart:ui` `Color`s. The templates are this plugin's own (MIT); the Next-Gen SDK ships none.
- `InterstitialAd`, `RewardedAd`, `RewardedInterstitialAd`, `AppOpenAd`: `load` / `show` / `dispose`, `FullScreenContentCallback`, rewards, `onPaidEvent`, `responseInfo`, `setImmersiveMode` (Android) and `setServerSideOptions`.
- Preloading: `InterstitialAdPreloader`, `RewardedAdPreloader`, `AppOpenAdPreloader` and `RewardedInterstitialAdPreloader` (also on iOS, which upstream does not wire) with `start` / `pollAd` / `isAdAvailable` / `getNumAdsAvailable` / `getConfiguration` / `getConfigurations` / `destroy` / `destroyAll`. iOS uses the SDK's Beta preloader module (`GoogleMobileAds_Private`); the podspec pins `~> 13.0`.
- `MobileAds.instance.initialize()` and `setAppMuted()`. `AdRequest` with keywords, content URL, neighbouring content URLs, non-personalized ads and adapter extras.
- Android targets the GMA Next-Gen SDK (`ads-mobile-sdk`) only. The SDK's background-thread callbacks are marshalled to the main thread inside the plugin. The AdMob App ID is read from the usual `<meta-data>` manifest entry.
- Unmounting a `BannerAd` / `NativeAd` destroys the native view one frame later unless it was mounted again in between, so a recycled list cell keeps its ad. Prefer non-recycling containers for ad slots.
- Hot restart is safe: the dispatcher slot is zeroed and live ads released before the old isolate is torn down.
- Formats unavailable on a platform report `onAdFailedToLoad` immediately rather than staying silent. On web and desktop every call is a no-op.
- The iOS SDK log line *"User interactions must be disabled on the asset view"* is expected with the built-in templates and harmless.
- Not implemented: mediation, Ad Manager (GAM), `NativeAdOptions.shouldRequestMultipleImages`, `requestCustomMuteThisAd`.
- `example/` app covering every format and preloading, and an agent skill (`skills/google-mobile-ads-kit-usage`) installable with `dart run skills@ get`.
