# Migrating from `google_mobile_ads`

This plugin's public API follows
[`google_mobile_ads`](https://pub.dev/packages/google_mobile_ads) closely, so
most call sites port unchanged. This page lists what differs — almost all of it
follows from one fact: DartNative mounts **real native views** instead of
compositing them through a PlatformView, and most differences make the code
shorter.

> **🚧 Status:** everything below works on Android and is verified on a device.
> iOS is written but has never been compiled; see the
> [README status table](../README.md#supported-formats).

---

## 1. Banner placement — `AdWidget` is gone

The biggest change, and it removes code.

**Flutter:**

```dart
late BannerAd _banner;

@override
void initState() {
  super.initState();
  _banner = BannerAd(adUnitId: '...', size: AdSize.banner,
      request: const AdRequest(), listener: BannerAdListener(...))
    ..load();                                   // manual load
}

@override
void dispose() { _banner.dispose(); super.dispose(); }   // manual dispose

@override
Widget build(BuildContext context) => SizedBox(
  width: _banner.size.width.toDouble(),
  height: _banner.size.height.toDouble(),
  child: AdWidget(ad: _banner),                 // PlatformView wrapper
);
```

**DartNative:**

```dart
@override
Widget build(BuildContext context) => BannerAd(
  adUnitId: '...',
  size: AdSize.banner,
  request: const AdRequest(),
  listener: BannerAdListener(...),
);
```

The widget owns the ad's lifecycle: it loads on mount, and the native ad is
destroyed one frame after unmount — unless the element was mounted again in
between, which is what a recycling list does (see §6).

## 2. Adaptive banners — use `LayoutBuilder`

Flutter's `AdSize.getAnchoredAdaptiveBannerAdSize` returns a `Future` because it
crosses a MethodChannel. Here the size is a synchronous FFI calculation, so
`AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)` can be called
straight from a `LayoutBuilder`, which also gives the real width of the slot
rather than a `MediaQuery` guess:

```dart
LayoutBuilder(
  builder: (context, constraints) {
    final size = AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
      constraints.maxWidth.truncate(),
    );
    if (size == null) return const SizedBox.shrink();
    return BannerAd(adUnitId: '...', size: size, listener: BannerAdListener(...));
  },
)
```

The `Future`-returning `AdSize.getAnchoredAdaptiveBannerAdSize(width)` is kept
so an `await`ing call site compiles unchanged; it completes immediately. Both
return null when no height is available.

## 3. Full-screen formats — unchanged

`InterstitialAd`, `RewardedAd`, `RewardedInterstitialAd` and `AppOpenAd` keep the
same static `load()` + `show()` shape, the same load-callback classes and the
same `FullScreenContentCallback`. The SDK presents these itself, so nothing about
rendering differs.

## 4. Native Ads — your native layouts carry over

Both plugins require the layout to be written natively (Android XML / iOS xib)
and registered by `factoryId` — an AdMob SDK requirement, not a framework one.
**Existing `NativeAdFactory` implementations and layout resources port with only
the registration call changing**, because DartNative has no `FlutterEngine`:

```kotlin
// Flutter
GoogleMobileAdsPlugin.registerNativeAdFactory(engine, "adFactoryExample", factory)
// DartNative
DartNativeMobileAdsPlugin.registerNativeAdFactory(this, "adFactoryExample", factory)
```

The Dart call is identical (`NativeAd(adUnitId: ..., factoryId: 'adFactoryExample', ...)`).
Inside the factory: change the import to `com.dartnative.mobile_ads.NativeAdFactory`,
and note the SDK classes come from the Next-Gen package
(`com.google.android.libraries.ads.mobile.sdk.nativead.*`), not
`com.google.android.gms.ads.nativead.*`.

**Templates** (`NativeTemplateStyle`, `TemplateType.small` / `.medium`) work the
same way, with one difference: colours are 32-bit ARGB `int`s rather than
`dart:ui` `Color`s, so the style classes do not depend on `dart:ui`:

```dart
mainBackgroundColor: Colors.white,   // Flutter
mainBackgroundColor: 0xFFFFFFFF,     // DartNative
```

**Height:** a native ad's height is not known before it loads, so `NativeAd`
reserves one — the template default, or the `height` you pass. Pass it
explicitly with `factoryId`; only you know how tall your layout is.

Not exposed: `shouldRequestMultipleImages`, `requestCustomMuteThisAd` (the
Next-Gen request builder has no equivalent). **Android only** for now.

## 5. Preloading — same shape, one extra preloader

`InterstitialAdPreloader`, `RewardedAdPreloader` and `AppOpenAdPreloader` keep
the `start` / `pollAd` / `isAdAvailable` / `getNumAdsAvailable` /
`getConfiguration` / `getConfigurations` / `destroy` / `destroyAll` surface, so
preloading code ports unchanged. `RewardedInterstitialAdPreloader` is added
(the Next-Gen SDK supports it). **Android only** for now: on iOS `pollAd`
returns null, so a call site that falls back to `load()` keeps working.

## 6. Lists — check your placement

A recycled cell unmounts and remounts the ad, and each remount is a new request.
See [the README warning](../README.md#banners-inside-scrolling-lists); prefer a
non-recycling `SingleChildScrollView` + `Column` for ad slots.

## 7. Initialization

```dart
WidgetsFlutterBinding.ensureInitialized();   // Flutter
DartNativePluginRegistrant.registerAll();    // DartNative
MobileAds.instance.initialize();             // both
```

## 8. App ID configuration — unchanged

`Info.plist` / `AndroidManifest.xml` entries are identical to the Flutter setup;
copy them as-is. This holds even though the Android Next-Gen SDK takes the App
ID in code rather than from the manifest — the plugin reads the `<meta-data>`
for you.

---

## Things that do not exist here

| `google_mobile_ads` | Why |
|---|---|
| `AdWidget` | No PlatformView — the widget mounts the native view itself |
| `ad.load()` on banners / native ads | Handled by the widget lifecycle |
| `AdManagerBannerAd` etc., mediation adapters | Ad Manager and mediation are out of scope for 1.0 |
| `USE_NEXT_GEN_SDK` dart-define | Android is always the Next-Gen SDK; a prebuilt plugin cannot switch at app build time |
