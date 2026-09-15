# dartnative_mobile_ads

Google Mobile Ads (AdMob) for [DartNative](https://dartnative.com) — Android and iOS.

Pure `dart:ffi` over the native Google Mobile Ads SDKs: no platform channels, no
PlatformView. A banner or native ad is a real native view mounted straight into
the native hierarchy. On Android the plugin targets the **GMA Next-Gen SDK**
(`ads-mobile-sdk`) only — see [Android SDK choice](#android-sdk-choice).

The public API follows [`google_mobile_ads`](https://pub.dev/packages/google_mobile_ads),
so porting from Flutter is mostly mechanical:
[Migrating from Flutter](doc/migration_from_flutter.md).

> **🚧 Status.** Android is complete and verified on a device — every format
> below, plus preloading. iOS is written but has **never been compiled** (that
> needs macOS + Xcode); its banner, native-ad and preload entry points are stubs
> that report a load failure, so an app's no-ad path runs instead of hanging.
> Details in [`CHANGELOG.md`](CHANGELOG.md).

---

## Supported formats

| Format | Android | iOS |
|---|---|---|
| Interstitial, Rewarded, Rewarded Interstitial, App Open | ✅ | 🚧 written, uncompiled |
| Banner (fixed + adaptive) | ✅ | ⬜ stub |
| Native Ads (built-in templates + your own factory) | ✅ | ⬜ stub |
| Preloading | ✅ | ⬜ stub |

Requires iOS 13.0+ / Android minSdk 24. On other platforms every call is a no-op
rather than an error, so shared code keeps running.

---

## Installation

_Not yet published. Once it is:_

```yaml
dependencies:
  dartnative_mobile_ads: ^0.1.0
```

Then `dn pub get`. The plugin registers itself through the generated
`lib/dartnative_plugin_registrant.dart`; nothing to add to `main()` beyond the
usual `DartNativePluginRegistrant.registerAll()`.

### ⚠️ Required: set your AdMob App ID natively

DartNative has no manifest-merge step, so **you add the App ID to both native
projects yourself.** Without it the SDK crashes on startup. Find it in the AdMob
console under **Apps → App settings** — it contains `~`; ad unit IDs contain `/`.

`ios/Runner/Info.plist`:

```xml
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-################~##########</string>
```

`android/app/src/main/AndroidManifest.xml`, inside `<application>`:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-################~##########"/>
```

On Android the plugin reads this `<meta-data>` and hands it to the Next-Gen
SDK, so the entry is the same as for Flutter and the legacy SDK. If it is
missing, `MobileAds.instance.initialize()` fails with a message naming it.

### Android app requirements

The Next-Gen SDK needs `minSdk` 24+, `compileSdk` 35+ and Kotlin 1.9+ in your
app's `android/app/build.gradle(.kts)`.

### iOS: tracking and SKAdNetwork

The SDK links `AppTrackingTransparency` and `AdSupport`. Add
`NSUserTrackingUsageDescription` and Google's `SKAdNetworkItems` to
`ios/Runner/Info.plist` per the
[AdMob iOS quick start](https://developers.google.com/admob/ios/quick-start).

---

## Usage

### Initialize

Required — the Android SDK refuses ad requests before it. The plugin runs it off
the main thread for you; do not `await` it before `runApp`, the SDK queues
requests made during startup.

```dart
import 'package:dartnative_mobile_ads/dartnative_mobile_ads.dart';

void main() {
  DartNativePluginRegistrant.registerAll();
  MobileAds.instance.initialize();
  runApp(const MyApp());
}
```

### Banner

Put `BannerAd` straight in the tree. There is **no `AdWidget` wrapper and no
manual `load()`** — the request goes out when the widget mounts.

```dart
BannerAd(
  adUnitId: 'ca-app-pub-3940256099942544/6300978111',  // test unit
  size: AdSize.banner,
  request: const AdRequest(),
  listener: BannerAdListener(
    onAdLoaded: (ad) => dnLog('loaded'),
    onAdFailedToLoad: (ad, error) => dnLog('failed: $error'),
  ),
)
```

Use the `AdSize` constants (`banner`, `largeBanner`, `mediumRectangle`,
`fullBanner`, `leaderboard`). A hand-built `AdSize(width: 320, height: 50)` is
**not** the same request: AdMob reads a custom size as a flexible slot and may
fill it with a differently shaped creative.

For an adaptive banner, compute the size from the available width first:

```dart
LayoutBuilder(
  builder: (context, constraints) {
    final size = AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
      constraints.maxWidth.truncate(),
    );
    if (size == null) return const SizedBox.shrink();   // null off Android/iOS
    return BannerAd(adUnitId: '...', size: size, listener: BannerAdListener(...));
  },
)
```

That call is **synchronous** here (it is a pure calculation; FFI has no async
mode). The `Future`-returning `AdSize.getAnchoredAdaptiveBannerAdSize(width)`
exists too, so ported code compiles unchanged.

The creative is drawn at its own size and centred in the slot — AdMob forbids
scaling or cropping ads, and the SDK returns a fixed size even for an adaptive
request.

### Native

A native ad's layout is built natively: AdMob requires every asset view to be
registered with the SDK (for click handling and viewability), which cannot be
done from Dart. Two ways to supply the layout.

**Built-in template** — two layouts ship with the plugin, styled from Dart:

```dart
NativeAd(
  adUnitId: 'ca-app-pub-3940256099942544/2247696110',  // test unit
  nativeTemplateStyle: const NativeTemplateStyle(
    templateType: TemplateType.medium,   // or .small
    mainBackgroundColor: 0xFFFFFFFF,     // 32-bit ARGB, not a dart:ui Color
    cornerRadius: 12,
    callToActionTextStyle: NativeTemplateTextStyle(
      textColor: 0xFFFFFFFF,
      backgroundColor: 0xFF2563EB,
    ),
  ),
  listener: NativeAdListener(
    onAdLoaded: (ad) => dnLog('loaded'),
    onAdFailedToLoad: (ad, error) => dnLog('failed: $error'),
  ),
)
```

**Your own layout** — register a factory natively, name it from Dart, and say
how tall your layout is. On Android, in `MainActivity.onCreate`:

```kotlin
DartNativeMobileAdsPlugin.registerNativeAdFactory(
    this, "adFactoryExample", MyNativeAdFactory(layoutInflater))
```

```dart
NativeAd(
  adUnitId: '...',
  factoryId: 'adFactoryExample',
  height: 120,
  listener: NativeAdListener(),
)
```

The factory inflates a `NativeAdView`, assigns each asset view (`headlineView`,
`iconView`, `callToActionView`, …) and calls `registerNativeAd` last. Both are
AdMob policy: an unregistered asset is not clickable and records no impression.

A native ad's height is not known before it loads, so the widget reserves one:
the template default (small 90, medium 350) or the `height` you pass.

### Interstitial

```dart
InterstitialAd.load(
  adUnitId: 'ca-app-pub-3940256099942544/1033173712',  // test unit
  request: const AdRequest(),
  adLoadCallback: InterstitialAdLoadCallback(
    onAdLoaded: (ad) {
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (ad) => ad.dispose(),
      );
      ad.show();
    },
    onAdFailedToLoad: (error) => dnLog('failed: $error'),
  ),
);
```

An ad shows once. Dispose it when it is spent — after dismissal, and after a
failed show — then load another.

### Rewarded

The reward callback goes to `show` and fires only once the user has watched
enough. Grant the reward there and nowhere else.

```dart
RewardedAd.load(
  adUnitId: 'ca-app-pub-3940256099942544/5224354917',  // test unit
  request: const AdRequest(),
  rewardedAdLoadCallback: RewardedAdLoadCallback(
    onAdLoaded: (ad) {
      ad.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (ad) => ad.dispose(),
      );
      ad.show(onUserEarnedReward: (ad, reward) => grantCoins(reward.amount));
    },
    onAdFailedToLoad: (error) => dnLog('failed: $error'),
  ),
);
```

`RewardedInterstitialAd` has the same shape; AdMob requires you to show a reward
announcement before it.

### App open

```dart
AppOpenAd.load(
  adUnitId: 'ca-app-pub-3940256099942544/9257395921',  // test unit
  request: const AdRequest(),
  adLoadCallback: AppOpenAdLoadCallback(
    onAdLoaded: (ad) => _pendingAd = ad,
    onAdFailedToLoad: (error) => dnLog('failed: $error'),
  ),
);
```

AdMob expires an app open ad four hours after it loads — record the load time
and discard a stale one. Show it on a cold start or a return to the foreground,
never over content the user is already using.

### Preloading

> **Android only.** On iOS `pollAd` returns null, so the fallback below runs.

A preloader keeps a small buffer filled in the background, so showing an ad is
instant. Start it once, then poll whenever you need one:

```dart
await InterstitialAdPreloader.start(
  preloadId: 'level-end',
  preloadConfiguration: const PreloadConfiguration(
    adUnitId: 'ca-app-pub-3940256099942544/1033173712',  // test unit
    bufferSize: 2,
  ),
  callback: PreloadCallback(
    onAdPreloaded: (id, responseInfo) => dnLog('ready: $id'),
    onAdsExhausted: (id) => dnLog('empty: $id'),
    onAdFailedToPreload: (id, error) => dnLog('failed: $error'),
  ),
);

final ad = await InterstitialAdPreloader.pollAd('level-end');
if (ad != null) {
  ad.fullScreenContentCallback = FullScreenContentCallback(
    onAdDismissedFullScreenContent: (ad) => ad.dispose(),
  );
  await ad.show();
} else {
  // buffer empty — it refills on its own; fall back to a normal load
}
```

Keep `bufferSize` small: a buffered ad that is never shown is a wasted
impression opportunity, and AdMob measures that. `RewardedAdPreloader`,
`RewardedInterstitialAdPreloader` and `AppOpenAdPreloader` work the same way
(`google_mobile_ads` has no rewarded-interstitial preloader; the Next-Gen SDK
does, so it is offered here).

---

## Banners inside scrolling lists

> ⚠️ Read this before putting a banner or native ad in a list.

`FastList`, `FastGrid` and `MasonryFastGrid` recycle their cells (they are
backed by `RecyclerView` / `UITableView`). A recycled ad is unmounted and
remounted as it scrolls out and back, and **each remount issues a new ad
request** — wasted inventory, a lower match rate, and an invalid-traffic risk.

Teardown is deferred by one frame so a cell that is recycled straight back in
keeps its ad, but a cell that scrolls away and returns is a new request. Prefer
a non-recycling container:

```dart
SingleChildScrollView(
  child: Column(children: [ ...content, BannerAd(...) ]),
)
```

If you must use a recycling list, leave `keepAliveCount` unset.

---

## Test ad units

Never use production ad units during development — it can get your account
suspended. Google's always-fill test units:

| Format | Android | iOS |
|---|---|---|
| Banner | `ca-app-pub-3940256099942544/6300978111` | `ca-app-pub-3940256099942544/2934735716` |
| Interstitial | `ca-app-pub-3940256099942544/1033173712` | `ca-app-pub-3940256099942544/4411468910` |
| Rewarded | `ca-app-pub-3940256099942544/5224354917` | `ca-app-pub-3940256099942544/1712485313` |
| Rewarded interstitial | `ca-app-pub-3940256099942544/5354046379` | `ca-app-pub-3940256099942544/6978759866` |
| App open | `ca-app-pub-3940256099942544/9257395921` | `ca-app-pub-3940256099942544/5575463023` |
| Native | `ca-app-pub-3940256099942544/2247696110` | `ca-app-pub-3940256099942544/3986624511` |

---

## Differences from `google_mobile_ads`

| | `google_mobile_ads` | `dartnative_mobile_ads` |
|---|---|---|
| Banner / native placement | `AdWidget(ad: ...)` after `load()` | The widget goes directly in the tree; the lifecycle owns load and dispose |
| Adaptive banner size | `await AdSize.getAnchoredAdaptiveBannerAdSize(orientation, width)` | `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)` — synchronous, so it fits inside `LayoutBuilder` (the `Future` form is kept too) |
| Native ad factory registration | `registerNativeAdFactory(engine, id, factory)` | `registerNativeAdFactory(context, id, factory)` — no `FlutterEngine` exists; the factory itself is unchanged |
| Template colors | `dart:ui` `Color` | 32-bit ARGB `int` |
| Native ad height | Comes from the platform view | Reserved by you (template default or `height:`) |
| Rendering / transport | PlatformView / MethodChannel | Native view in the native hierarchy / `dart:ffi` |
| Ad Manager (GAM), mediation | Supported | Out of scope for 1.0 |
| Android SDK | Legacy by default, `USE_NEXT_GEN_SDK` flag | **Next-Gen only** |

Full list with before/after code: [doc/migration_from_flutter.md](doc/migration_from_flutter.md).

## Android SDK choice

Flutter's plugin compiles from source inside your app, so a `--dart-define` can
pick the SDK. A DartNative plugin ships as one prebuilt `.aar`, so the choice is
made here, once: the **GMA Next-Gen SDK**, which Google documents as the default
and labels `play-services-ads` as legacy. Consequences: minSdk 24 / compileSdk
35+; mediation is AdMob-only (out of scope for 1.0 anyway); nothing changes in
your Dart code — the SDK's background-thread callbacks are marshalled back to
the main thread inside the plugin.

---

## Documentation

- [Migrating from Flutter](doc/migration_from_flutter.md)
- [Design specification](doc/design.md) — architecture and decisions (JA)
- [Research notes](doc/research.md) — the SDK internals this is built on (JA; repository only)
- **AI agent skill:** `dart run skills@ get` in an app that depends on this
  package installs `dartnative-mobile-ads-usage`, a compact reference for
  coding agents — setup, every format, and the pitfalls above.

## Contributing

`.claude/skills/dartnative-plugin/SKILL.md` documents the plugin-authoring
patterns this repository relies on (FFI, the dispatcher-slot callback contract,
the JNI bridge, `NativeElement`). Read it before touching native code.

## License

MIT — see [LICENSE](LICENSE). The public API surface follows `google_mobile_ads`
(Apache-2.0) to ease migration; no code is derived from it.
