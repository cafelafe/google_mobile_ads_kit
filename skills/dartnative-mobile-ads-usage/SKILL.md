---
name: dartnative-mobile-ads-usage
description: "Use dartnative_mobile_ads (AdMob for DartNative): initialization, App ID setup, banner, native, interstitial, rewarded, rewarded interstitial and app open ads, preloading, test ad units, and the differences from google_mobile_ads. Use when adding or debugging ads in a DartNative app, or porting google_mobile_ads code."
---

# dartnative_mobile_ads

Google Mobile Ads (AdMob) for **DartNative** apps. The public API follows
Flutter's `google_mobile_ads`, so most ported code compiles unchanged — but the
internals are `dart:ffi`, not platform channels, and a few call shapes differ.
This skill covers what to write and what to avoid.

## Platform status — check before promising anything

| Format | Android | iOS | web / desktop |
|---|---|---|---|
| Interstitial, Rewarded, Rewarded interstitial, App open | ✅ verified on device | 🚧 written, never compiled | no-op |
| Banner (fixed + adaptive) | ✅ | ❌ stub | no-op |
| Native (templates + factory) | ✅ | ❌ stub | no-op |
| Preloading | ✅ | ❌ stub | no-op |

- **iOS stubs are not silent.** A banner or native ad reports `onAdFailedToLoad`
  immediately; a preloader's `pollAd` returns `null`. Write the failure path and
  the app degrades cleanly.
- **web / desktop:** every call is inert rather than throwing, so shared code
  keeps running. `MobileAds.instance.initialize()` completes with an empty status.

## Setup (all three steps are required)

1. **Dependency** — then run `dn pub get` (not `dart pub get`). The plugin
   registers itself through the generated `dartnative_plugin_registrant.dart`.

   ```yaml
   dependencies:
     dartnative_mobile_ads: ^0.1.0
   ```

2. **AdMob App ID, natively, on both platforms.** DartNative has no manifest
   merge, so this is manual. Without it the SDK crashes at startup; on Android
   `initialize()` fails with a message naming the entry.

   `android/app/src/main/AndroidManifest.xml`, inside `<application>`:
   ```xml
   <meta-data
       android:name="com.google.android.gms.ads.APPLICATION_ID"
       android:value="ca-app-pub-################~##########"/>
   ```
   `ios/Runner/Info.plist`:
   ```xml
   <key>GADApplicationIdentifier</key>
   <string>ca-app-pub-################~##########</string>
   ```
   The App ID (`~`) is not an ad unit ID (`/`). Android also needs `minSdk` 24,
   `compileSdk` 35+, Kotlin 1.9+ in the app's `build.gradle`.

3. **Initialize** in `main()`. Required — the Android SDK refuses ad requests
   before it. Do not `await` it before `runApp`; the SDK queues requests.

   ```dart
   import 'package:dartnative_mobile_ads/dartnative_mobile_ads.dart';

   void main() {
     DartNativePluginRegistrant.registerAll();   // not WidgetsFlutterBinding
     MobileAds.instance.initialize();
     runApp(const MyApp());
   }
   ```

## How this differs from google_mobile_ads

| | `google_mobile_ads` | `dartnative_mobile_ads` |
|---|---|---|
| Banner / native placement | `AdWidget(ad: myAd)` after `await ad.load()` | Put `BannerAd(...)` / `NativeAd(...)` **directly in the tree**. No `AdWidget`, no `load()` — the request goes out on mount |
| Adaptive size | `await AdSize.getAnchoredAdaptiveBannerAdSize(orientation, width)` | `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)` — **synchronous**, call it inside `LayoutBuilder`. The `Future` form `getAnchoredAdaptiveBannerAdSize(width)` also exists for ported code |
| Native ad factory registration (Android) | `GoogleMobileAdsPlugin.registerNativeAdFactory(engine, id, factory)` | `DartNativeMobileAdsPlugin.registerNativeAdFactory(context, id, factory)` — takes a `Context`; there is no `FlutterEngine`. The factory body is unchanged |
| Template colors | `dart:ui` `Color` | 32-bit ARGB `int`, e.g. `0xFFFFFFFF` |
| Native ad height | from the platform view | **You reserve it**: template default (small 90 / medium 350) or `height:` — required in practice with `factoryId` |
| `load` / `show` / `dispose` / preloader calls | `Future` | Still `Future` (the work is synchronous underneath) — `await` them as before |
| Android SDK | legacy, `USE_NEXT_GEN_SDK` flag | **Next-Gen only**, no flag |
| Not available | — | `NativeAdOptions.shouldRequestMultipleImages`, `requestCustomMuteThisAd` (no Next-Gen equivalent); rewarded-interstitial **preloader** is *extra* here |

## Full-screen formats

Same pattern for all four. Load with a format-specific callback, keep the ad,
set `fullScreenContentCallback`, `show()`, dispose on dismiss and load the next.

```dart
InterstitialAd? _interstitial;

InterstitialAd.load(
  adUnitId: 'ca-app-pub-3940256099942544/1033173712',   // Android test unit
  request: const AdRequest(),
  adLoadCallback: InterstitialAdLoadCallback(
    onAdLoaded: (InterstitialAd ad) {
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (ad) { ad.dispose(); _interstitial = null; },
        onAdFailedToShowFullScreenContent: (ad, error) { ad.dispose(); _interstitial = null; },
      );
      _interstitial = ad;
    },
    onAdFailedToLoad: (LoadAdError error) => debugPrint('$error'),
  ),
);

// later
await _interstitial?.show();
```

- `RewardedAd` / `RewardedInterstitialAd`: `load(...)` is identical with
  `RewardedAdLoadCallback` / `RewardedInterstitialAdLoadCallback`;
  **`show` requires the reward callback**:
  `await ad.show(onUserEarnedReward: (ad, RewardItem reward) { ... })`.
  Optional `await ad.setServerSideOptions(ServerSideVerificationOptions(userId: ..., customData: ...))` before showing.
- `AppOpenAd`: `load(...)` with `AppOpenAdLoadCallback`, then `show()`.
- `ad.setImmersiveMode(bool)` — Android only. `ad.onPaidEvent` and
  `ad.responseInfo` are available on every format.
- Show each loaded ad **once**. Reloading a spent ad object is not possible.

## Banner

```dart
BannerAd(
  adUnitId: 'ca-app-pub-3940256099942544/6300978111',   // Android test unit
  size: AdSize.banner,                                   // 320x50
  request: const AdRequest(),
  listener: BannerAdListener(
    onAdLoaded: (ad) {},
    onAdFailedToLoad: (ad, error) {},
  ),
)
```

- Use the constants `AdSize.banner`, `largeBanner`, `mediumRectangle`,
  `fullBanner`, `leaderboard`. **Do not build `AdSize(width: 320, height: 50)`
  yourself** — AdMob treats a custom size as a flexible slot and may return a
  differently shaped creative (a 320x50 request came back 468x60, letterboxed).
- Adaptive (fills the width with a Google-optimized height):

  ```dart
  LayoutBuilder(builder: (context, constraints) {
    final size = AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
      constraints.maxWidth.truncate(),
    );
    if (size == null) return const SizedBox.shrink();   // null off Android/iOS
    return BannerAd(adUnitId: ..., size: size, listener: ...);
  })
  ```
- The creative is drawn at its own size and centred; it is never stretched
  (AdMob forbids scaling/cropping).

## Native ads

The layout is built **natively** — AdMob requires each asset view to be
registered with the SDK, which cannot happen from Dart. Two routes; exactly one
of `nativeTemplateStyle` / `factoryId` is required.

**Built-in template** (no native code):
```dart
NativeAd(
  adUnitId: 'ca-app-pub-3940256099942544/2247696110',   // Android test unit
  nativeTemplateStyle: const NativeTemplateStyle(
    templateType: TemplateType.medium,        // or .small
    mainBackgroundColor: 0xFFFFFFFF,
    cornerRadius: 12,
    primaryTextStyle: NativeTemplateTextStyle(textColor: 0xFF111111, style: NativeTemplateFontStyle.bold),
    callToActionTextStyle: NativeTemplateTextStyle(textColor: 0xFFFFFFFF, backgroundColor: 0xFF2563EB),
  ),
  nativeAdOptions: const NativeAdOptions(mediaAspectRatio: MediaAspectRatio.landscape),
  listener: NativeAdListener(onAdLoaded: (ad) {}, onAdFailedToLoad: (ad, error) {}),
)
```

**Your own layout** — register a factory in `MainActivity.onCreate`, name it
from Dart, and pass the height your layout needs:
```kotlin
// android/app/src/main/kotlin/.../MainActivity.kt
DartNativeMobileAdsPlugin.registerNativeAdFactory(this, "adFactoryExample", MyNativeAdFactory(layoutInflater))
```
```kotlin
class MyNativeAdFactory(private val inflater: LayoutInflater) : com.dartnative.mobile_ads.NativeAdFactory {
    override fun createNativeAdView(nativeAd: NativeAd, customOptions: Map<String, Any?>): NativeAdView {
        val view = inflater.inflate(R.layout.my_native_ad, null) as NativeAdView
        view.findViewById<TextView>(R.id.headline).also { it.text = nativeAd.headline; view.headlineView = it }
        // ...assign EVERY displayed asset (iconView, bodyView, callToActionView, ...)...
        view.registerNativeAd(nativeAd, view.findViewById(R.id.media))   // last
        return view
    }
}
```
```dart
NativeAd(adUnitId: ..., factoryId: 'adFactoryExample', height: 120, listener: NativeAdListener())
```
SDK classes are the Next-Gen ones: `com.google.android.libraries.ads.mobile.sdk.nativead.*`,
not `com.google.android.gms.ads.nativead.*`. `customOptions:` (a JSON-able map)
reaches the factory's second argument.

## Preloading (Android)

```dart
await InterstitialAdPreloader.start(
  preloadId: 'level-end',
  preloadConfiguration: const PreloadConfiguration(
    adUnitId: 'ca-app-pub-3940256099942544/1033173712',
    bufferSize: 2,                                  // keep small: unused buffered ads expire
  ),
  callback: PreloadCallback(
    onAdPreloaded: (id, responseInfo) {},
    onAdsExhausted: (id) {},
    onAdFailedToPreload: (id, error) {},
  ),
);

final ad = await InterstitialAdPreloader.pollAd('level-end');   // null when empty
if (ad != null) {
  ad.fullScreenContentCallback = FullScreenContentCallback(onAdDismissedFullScreenContent: (ad) => ad.dispose());
  await ad.show();
} else {
  // fall back to a normal load — this is also the path iOS takes today
}
```

Also: `isAdAvailable(id)`, `getNumAdsAvailable(id)`, `getConfiguration(id)`,
`getConfigurations()`, `destroy(id)`, `destroyAll()`. Same surface on
`RewardedAdPreloader`, `RewardedInterstitialAdPreloader`, `AppOpenAdPreloader`.

## Targeting and global settings

- `AdRequest(keywords:, contentUrl:, neighboringContentUrls:, nonPersonalizedAds:, extras:)`.
  Set `nonPersonalizedAds: true` when the user has not consented — obtaining
  consent is the app's job; this only forwards the decision.
- `MobileAds.instance.setAppMuted(bool)`.

## Rules that protect the AdMob account

- **Never use production ad units during development.** Test units:

  | Format | Android | iOS |
  |---|---|---|
  | Banner | `…2544/6300978111` | `…2544/2934735716` |
  | Interstitial | `…2544/1033173712` | `…2544/4411468910` |
  | Rewarded | `…2544/5224354917` | `…2544/1712485313` |
  | Rewarded interstitial | `…2544/5354046379` | `…2544/6978759866` |
  | App open | `…2544/9257395921` | `…2544/5575463023` |
  | Native | `…2544/2247696110` | `…2544/3986624511` |

  (prefix `ca-app-pub-3940256099942544`)
- **Do not put `BannerAd` / `NativeAd` in `FastList`, `FastGrid` or
  `MasonryFastGrid`.** Those recycle cells; each remount re-requests an ad —
  wasted inventory and an invalid-traffic risk. Use `SingleChildScrollView` +
  `Column` (or any non-recycling parent). If unavoidable, leave `keepAliveCount`
  unset.
- Register every displayed asset in a native factory and call
  `registerNativeAd` last, or the ad is unclickable and records no impression.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No DartNative license found.` on screen | The DartNative trial only covers its own samples. `dn config --license-key=dnk_...` (never paste the key into chat or source). |
| `initialize()` fails naming `APPLICATION_ID` | App ID `<meta-data>` missing from the Android manifest (Setup step 2). |
| `Theme.Material3.* not found` at Android link | `dartnative_android` / `dartnative_ios` were stripped from the app's `pubspec.yaml` (running `dn pub get` from a plugin root does this). Restore them. |
| Banner shows a different size than requested | A hand-built `AdSize` — use the `AdSize.*` constants. |
| Native ad with `factoryId` loads but is invisible | No `height:` given, or the factory did not `registerNativeAd`. |
| iOS: banner / native fail immediately, `pollAd` null | Expected today — iOS stubs. Not a configuration error. |
