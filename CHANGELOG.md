# Changelog

## 0.1.0

First release. Every ad format works end to end on Android and is verified
on a device; the iOS half is written but has never been compiled.

### Added

- **Banner ads.** `BannerAd` goes straight into the widget tree — no `AdWidget`
  wrapper and no manual `load()`, since DartNative mounts native views directly.
  Fixed sizes plus adaptive sizing via
  `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)`, which is
  synchronous here (it is a pure calculation, and FFI has no async mode); the
  `Future`-returning form is provided too so ported code compiles unchanged.
  The standard sizes (`AdSize.banner`, `largeBanner`, `mediumRectangle`,
  `fullBanner`, `leaderboard`) request the SDK's standard slots; a hand-built
  `AdSize` is treated by AdMob as a flexible slot and may be filled with a
  differently shaped creative, so prefer the constants. **Android only.**
- **Native ads.** `NativeAd` goes straight into the widget tree, rendered either
  by one of two built-in templates (`TemplateType.small` / `.medium`, styled from
  Dart with `NativeTemplateStyle`) or by a `NativeAdFactory` you register
  natively and name with `factoryId` — the same two routes as
  `google_mobile_ads`. Request options via `NativeAdOptions`. **Android only.**

  Two differences from upstream, both forced by the platform:

  - Registration takes a `Context` rather than a `FlutterEngine`
    (`DartNativeMobileAdsPlugin.registerNativeAdFactory`), since DartNative has
    no engine object. The factory interface and the Dart call are unchanged.
  - Template colors are 32-bit ARGB `int`s rather than `dart:ui` `Color`s, so
    the style classes stay usable from code that does not depend on `dart:ui`.

  The templates are this plugin's own: the Next-Gen SDK ships none, and
  upstream's are Apache-2.0 while this package is MIT (`doc/design.md` §8-4).
  `shouldRequestMultipleImages` and `requestCustomMuteThisAd` are not exposed —
  the Next-Gen request builder has no equivalent.
- **Interstitial, rewarded, rewarded interstitial and app open ads.** Load,
  show, the full presentation-event set (showed / failed-to-show / dismissed /
  impression / clicked), rewards, and paid events.
- **Ad preloading** — `InterstitialAdPreloader`, `RewardedAdPreloader`,
  `AppOpenAdPreloader` and (beyond `google_mobile_ads`)
  `RewardedInterstitialAdPreloader`, with `start` / `pollAd` /
  `isAdAvailable` / `getNumAdsAvailable` / `getConfiguration` /
  `getConfigurations` / `destroy` / `destroyAll`. **Android only** — on iOS
  `pollAd` returns null, so callers fall back to a normal load.
- `MobileAds.instance.initialize()` and `setAppMuted()`.
- `AdRequest` targeting: keywords, content URL, neighbouring content URLs,
  non-personalized ads, and adapter extras.
- `Ad.responseInfo`, `onPaidEvent` with `PrecisionType`, `setImmersiveMode`
  (Android only) and `setServerSideOptions` on the rewarded formats.
- An `example/` app exercising every format and preloading against Google's
  test ad units, and an agent skill (`skills/dartnative-mobile-ads-usage`)
  installable with `dart run skills@ get`.

### API compatibility with `google_mobile_ads`

Call shapes match, so ported code compiles unchanged:

- `load`, `show`, `dispose` and the preloader calls all return `Future`. The
  work behind them is synchronous — FFI has no other mode — but `await`ing them
  is what existing code does.
- `InterstitialAdLoadCallback` and friends are subclasses of
  `FullScreenAdLoadCallback<T>`, not typedefs.

File layout deliberately differs: upstream keeps every ad class in one 1,400-line
`ad_containers.dart` alongside a `MethodChannel` instance manager, neither of
which applies here (`doc/design.md` §2-1).

### Notes

- Android targets the GMA Next-Gen SDK (`ads-mobile-sdk`) only; there is no
  legacy `play-services-ads` switch (`doc/design.md` §12-9). The SDK's
  background-thread callbacks are marshalled to the main thread inside the plugin.
- Unmounting a `BannerAd` / `NativeAd` destroys the native view one frame later,
  unless the element was mounted again in between — so a list cell recycled
  straight back in keeps its ad, while a cell that scrolls away and returns
  issues a new request. Prefer non-recycling containers for ad slots.
- Hot restart is handled through `DNViewRegistry.registerResetHook`: the
  dispatcher slot is zeroed and live ads released before the old isolate is torn
  down, so late SDK events cannot reach a dead isolate.
- On web and desktop every call is inert rather than throwing, so shared code
  keeps running there. On iOS the unimplemented formats report a load failure
  immediately rather than staying silent.

### Not yet implemented

- iOS banners, native ads and preloading — all stubs (`doc/design.md` §1-1,
  §12-1). The iOS full-screen bridge exists but is uncompiled (needs macOS + Xcode).
- Mediation (`doc/design.md` §1-3).
