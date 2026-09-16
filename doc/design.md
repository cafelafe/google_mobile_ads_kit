# google_mobile_ads_kit design specification

The design of the Google Mobile Ads (AdMob) plugin for DartNative, and the
facts that were settled during implementation.

- Status: Android is verified on a device; iOS is verified on the simulator (§10)
- Target SDKs: DartNative 3.45.0-0.1.pre / Dart 3.12.0-192.0.dev /
  GMA Next-Gen 1.4.0 (Android) / Google-Mobile-Ads-SDK 13.9.0 (iOS)
- License: MIT
- Evidence: [`research.md`](research.md) (repository only; not shipped)

> Section numbers are cited from `///` comments in the code, from `CLAUDE.md`
> and from the skills, so **they never change**. The content has been updated to
> the shipped state. Where the implementation overturned a design-time
> assumption, the difference is recorded at the end of the section as an
> **implementation note**.

---

## 1. Scope

### 1-1. Formats and status

| Format | Mechanism | Android | iOS |
|---|---|---|---|
| Interstitial / Rewarded / Rewarded Interstitial / App Open | pure FFI (no view) | ✅ device | 🟢 simulator (not yet on hardware) |
| Banner (fixed and adaptive) | `NativeElement` | ✅ device | 🟢 simulator (not yet on hardware) |
| Native Ads (templates and factory) | `NativeElement` + native layout | ✅ device (AdMob validator passed) | 🟢 simulator, **validator passed** (not yet on hardware). §8-6-1 |
| Preloading | pure FFI | ✅ builds (buffer behaviour not verified on device) | 🟢 loads on the simulator (buffer behaviour not verified). Beta module, below |

**The iOS preloader lives in the SDK's Beta module.** Its headers are not under
`Headers/` but under `PrivateHeaders/` (`GAD*Preloader_Beta.h`), and the module
is called `GoogleMobileAds_Private`. **A plain `import GoogleMobileAds` does not
see it**, so `import GoogleMobileAds_Private` is added alongside.
(`google_mobile_ads` reaches the same thing from Objective-C via
`#import <GoogleMobileAds/GoogleMobileAds_Beta.h>`.) All four formats are
implemented, including `RewardedInterstitialAdPreloader`, which the Flutter
plugin does not wire on iOS.

⚠️ Being Beta, the API can change with an SDK update. The podspec's `~> 13.0`
pin bounds that (§9-1).

Stubs **report a load failure rather than staying silent** (`onAdFailedToLoad`
/ `pollAd → null`). `loadSymbols` resolves every symbol at startup in one go, so
a single missing symbol would take the working formats down with it — stubs are
mandatory.

> **What "type-checks" means for iOS:** `swiftc -typecheck` against the real
> Google-Mobile-Ads-SDK 13.9.0 framework reports 0 errors across all Swift
> files. That rules out mistaken v13 Swift names (`MobileAds` / `BannerView` /
> `NativeAdView` …). It says nothing about display on real hardware.

### 1-2. Supported platforms

iOS 15.0+ / Android minSdk 24. Elsewhere (web, desktop) every call is
**inert rather than throwing**, so shared code keeps running.

### 1-3. Not supported

Mediation (Next-Gen is AdMob-only; out of scope for v1.0) and Ad Manager (GAM)
specific features.

---

## 2. Design principles

### 2-1. The public API follows `google_mobile_ads`

This is the DartNative ecosystem's convention (the bundled plugins advertise
themselves as drop-in replacements for their Flutter counterparts), and it
lowers migration cost. **What we follow:** class names, method names, parameter
names, enums, listeners, error structures and the factory registration flow.
**What we do not follow:** the internal implementation, which depends on
MethodChannel / PlatformView and cannot be ported. The file layout also differs:
one file per format instead of upstream's monolithic `ad_containers.dart`.

### 2-2. Deliberate differences from the Flutter plugin

| Item | Flutter | This plugin | Why |
|---|---|---|---|
| Banner / native ad placement | `AdWidget(ad:)` + manual `load()` | The widget goes directly in the tree; loads on mount | There is no PlatformView; `NativeElement` mounts the view directly |
| Adaptive size | `await AdSize.getAnchoredAdaptiveBannerAdSize(orientation, width)` | `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)` (synchronous); the `Future` form is kept | FFI is synchronous; callable directly inside `LayoutBuilder` |
| Factory registration (Android) | First argument `FlutterEngine` | First argument `Context` | No `FlutterEngine` exists. The factory body is identical |
| Template colours | `dart:ui` `Color` | 32-bit ARGB `int` | Keeps the style types independent of `dart:ui` |
| Native ad height | From the platform view | Reserved by the user (with defaults) | §8-6 |
| Android SDK | Legacy by default + `USE_NEXT_GEN_SDK` | Next-Gen only | A prebuilt `.aar` cannot let the app choose an SDK (§12-9) |

The differences are spelled out in the README table and in
`migration_from_flutter.md`.

### 2-3. License

**MIT.** `google_mobile_ads` is Apache-2.0, but there is effectively no
implementation to transcribe (research.md §13-3). The template layout XML is
written from scratch as well (§8-4).

---

## 3. Architecture

### 3-1. Overview

```
Dart    BannerAd / NativeAd ──→ NativeElement (has a view)
        Interstitial / Rewarded / AppOpen / Preloader ──→ AdsFFIBindings (no view)
                │ dart:ffi (C ABI, synchronous) / reverse direction: dispatcher slot (§5-2)
Bridge  iOS: @_cdecl Swift (1 hop)   Android: C++ JNI → Kotlin AdsBridge (2 hops)
                │
SDK     Google Mobile Ads   iOS 13.9.0 (Swift names) / Android Next-Gen (ads-mobile-sdk)
```

### 3-2. Directory layout (as shipped)

```
google_mobile_ads_kit/
├── lib/
│   ├── google_mobile_ads_kit.dart      # exports + initializeMobileAdsPlugin()
│   └── src/
│       ├── ads_ffi_bindings.dart       # typedefs, loadSymbols, dispatcher, event kinds
│       ├── mobile_ads.dart  ad_request.dart  ad_error.dart  ad_listener.dart  ad_base.dart
│       ├── full_screen_ad.dart         # shared load / event path for the 4 full-screen formats
│       ├── interstitial_ad.dart  rewarded_ad.dart  app_open_ad.dart
│       ├── ad_preloader.dart           # AdPreloader + the 4 per-format classes
│       ├── ad_size.dart  banner_ad.dart
│       └── native_ad.dart  native_ad_options.dart  native_template_style.dart
├── ios/
│   ├── google_mobile_ads_kit.podspec   # ★ s.platform is 15.0 (Xcode 27's floor, §11-1)
│   └── Classes/                        # split by role into 8 files; see §10
│       ├── GMAKCore.swift              # shared (internal): events, slot, JSON
│       ├── GMAKMobileAds.swift         # the 4 full-screen formats
│       ├── GMAKPreloader.swift         # preloading (Beta module, §1-1)
│       ├── GMAKMobileAdsProvider.swift # createView / handleMutation registration
│       ├── GMAKStore.swift             # retain / release / hand-off keyed by viewId
│       ├── GMAKBannerAd.swift  GMAKNativeAd.swift
│       └── GMAKNativeAdTemplate.swift  # the two templates (Auto Layout)
├── src/  CMakeLists.txt (★ at the plugin root),  ads_bridge.cpp (JNI bridge)
├── android/
│   ├── build.gradle                    # ★ Groovy. cmake path = ../src/CMakeLists.txt
│   └── src/main/
│       ├── AndroidManifest.xml         # no package attribute (AGP 8)
│       ├── kotlin/com/cafelafe/google_mobile_ads_kit/
│       │   ├── GoogleMobileAdsKitPlugin.kt   # registration, loadLibrary, registerNativeAdFactory
│       │   ├── AdsBridge.kt                   # the real work (@Keep @JvmStatic)
│       │   ├── BannerAdProvider.kt  NativeAdProvider.kt   # DNAndroidPluginProvider
│       │   ├── NativeAdFactory.kt             # interface the user implements
│       │   └── NativeAdRenderer.kt            # inflates the bundled templates, applies style
│       └── res/layout/gmak_native_ad_{small,medium}.xml
├── example/   test/
├── skills/google-mobile-ads-kit-usage/ # consumer skill (distributed via `dart run skills@ get`)
├── .claude/skills/                     # contributor skills (not shipped)
├── doc/  design.md  research.md  migration_from_flutter.md
├── .pubignore                          # excludes .claude/ .config/ CLAUDE.md doc/research.md
└── pubspec.yaml  README.md  CHANGELOG.md  CLAUDE.md  LICENSE
```

### 3-3. Naming

| Target | Value |
|---|---|
| Dart package / Android package / plugin class | `google_mobile_ads_kit` / `com.cafelafe.google_mobile_ads_kit` / `GoogleMobileAdsKitPlugin` |
| C symbols | `GMAK*` (`GMAKLoadAd`, `GMAKBannerCreate`, `GMAKNativeAdCreate` …). Dart resolves 20, plus the iOS-only `GMAKRegisterProvider`, 21 in total |
| Native library | `libgoogle_mobile_ads_kit.so` |
| ViewType keys | `google_mobile_ads_kit/banner`, `google_mobile_ads_kit/native` |

---

## 4. Plugin manifest

```yaml
dartnative:
  plugin:
    platforms:
      ios:     { ffiPlugin: true }
      android: { package: com.cafelafe.google_mobile_ads_kit, pluginClass: GoogleMobileAdsKitPlugin }  # ★ never ffiPlugin
  registrant:
    imports: [ package:google_mobile_ads_kit/google_mobile_ads_kit.dart ]
    calls:   [ "initializeMobileAdsPlugin();" ]
```

**`ffiPlugin: true` is not an option on Android.** An FFI-only plugin is never
added to the registrant, so `System.loadLibrary` never runs and the ad
callbacks (reverse JNI) die with `UnsatisfiedLinkError` (the same warning as in
`dartnative_firebase`'s pubspec). `initializeMobileAdsPlugin()` resolves the FFI
symbols and registers the banner and native ad element factories.

---

## 5. Dart ↔ native communication

### 5-1. Dart → native

| Purpose | Mechanism |
|---|---|
| View-less operations (load, show, preload) | Call the FFI function directly |
| Configuring a view | Pre-register over FFI at mount, keyed by viewId (§7-5). `PluginMutation` is currently unused |

> ⚠️ `handleMutation` is **broadcast to every provider**. Avoiding tag
> collisions is your own responsibility.

> ⚠️ **`createView` must answer "not mine" for a view type that is not yours —
> `null` on Android, `0` on iOS.** The registry walks providers in registration
> order and **stops at the first non-null / non-zero result** (confirmed on
> Android by disassembling the `.aar`, where the interface is also `@Nullable`;
> and on iOS by disassembling the framework: `testq %rax,%rax; jne`). Returning
> an empty container hijacks every later view type. This never shows up with a
> banner alone; it surfaced as "loads but blank" the moment a second view type
> (native ads) was added.

### 5-2. Native → Dart: the dispatcher-slot pattern

The **one and only** callback pointer, created with `Pointer.fromFunction` (not
`NativeCallable`), is handed to native once. Native stores it in a "slot" and
**re-reads the slot immediately before every fire, calling only if non-zero**.
The C++ side never caches it.

```dart
typedef _DispatchC = Void Function(Int64 token, Int32 status, Pointer<Utf8> json);
```

**Hot restart:** a `reset()` registered with `DNViewRegistry.registerResetHook`
runs **before** the old isolate is torn down. It zeroes the slot and releases
every retained ad, `AdView` and `NativeAdView`. Ad events arrive seconds to
minutes late, so straddling a restart is the normal case — this pattern is not
optional.

> Implementation note: the design assumed Android would also use an isolate
> generation counter (`nativeIsolateGen()`), but **the engine does not export
> that symbol** (`DNRegisterAsyncDispatcherSlot` is absent from the `.so`, and
> `DN_IsolateGen` is not a getter). The mechanism that actually exists is
> `registerResetHook` (confirmed in bytecode). See research.md §14-4.
>
> **That note is Android-only. iOS differs (confirmed with `nm` on the engine
> xcframework):**
>
> - `DNRegisterAsyncDispatcherSlot` **does exist on iOS**. The engine zeroes the
>   slot itself (the binary contains the string `[DN-Swift] callbacks frozen for
>   hot restart, dropping fires`). That is enough to block late events.
> - **iOS has no plugin-facing equivalent of `registerResetHook`.** The engine
>   only clears the slot and never calls back into the plugin, so
>   `GMAKSetDispatcher(0)` **never arrives** — cleanup written there is dead code.
> - The usable signal is **a second non-zero pointer**. A hot restart re-runs
>   `loadSymbols()`, so "a dispatcher is already installed and another one is
>   being installed" means the old isolate is gone, and `releaseAll()` runs
>   (`GMAKMobileAds.swift`).
>
> Left alone, a surviving `BannerView` keeps auto-refreshing and firing
> impressions, and the leftover entries in the container hand-off queue shift
> every subsequent `createView` by one (the hand-off in §7-5 is FIFO).

### 5-3. Payloads

Structured data travels as a JSON string (`Pointer<Utf8>`). `token` (Int64) is
the Dart-side receiver; `status` (Int32) is the event kind (`AdEventStatus`
0–14; **append-only, never renumber** — Kotlin and Swift carry the same
constants). Synchronous string returns use "caller-supplied buffer + written
length; if the buffer is too small, return the required size as a negative
number" (`GMAKPreloadReadJson`).

---

## 6. Threading model

Dart runs on the platform's main thread (there is no raster thread).

| Direction | Rule |
|---|---|
| Dart → native (synchronous) | UI APIs may be called directly |
| Native → Dart | **Always from the main thread** (`Pointer.fromFunction` requires the owning isolate's thread) |

**Android Next-Gen fires every callback on a background thread.**
`AdsBridge.deliver` always returns to main via `mainHandler.post`. Conversely,
`MobileAds.initialize` and ad loads **ANR if called on main**, so they go to
`ioExecutor`. View creation (inflating a `NativeAdView` and so on) happens after
hopping back to main. The iOS GMA delegates fire on main.

---

## 7. Banner design

### 7-1. Widget structure (two layers)

`BannerAd` (public `StatefulWidget`) → `_BannerAdView` (internal leaf `Widget`)
→ `_BannerAdElement extends NativeElement`. Only the leaf is passed to
`registerElementFactory`. Listeners receive `_BannerAdHandle extends Ad` rather
than the immutable widget.

### 7-2. The `NativeElement` contract

`viewType` (`ViewType.claim`), `buildProps`, `mount`, `update`, `unmount`.
`stretchAsStackFlowChild => true` stretches to the parent's full width.

### 7-3. Sizing

A plugin view **cannot report an intrinsic size to Yoga**, but a banner's size
is known before the request, so emitting `SetFlexAspectRatio(viewId, w/h)` at
mount is enough. For adaptive banners, `LayoutBuilder` supplies the width and
`AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)` (synchronous
FFI → Kotlin's `AdSize.getLargeAnchoredAdaptiveBannerAdSize`) computes the
height analytically.

**Standard sizes must map to the SDK constants (important).** A hand-built
`AdSize(320, 50)` is not treated as `AdSize.BANNER`; AdMob reads it as a
flexible slot and **returned a 468x60** (on device). Kotlin's `resolveAdSize()`
maps BANNER / LARGE_BANNER / MEDIUM_RECTANGLE / FULL_BANNER / LEADERBOARD to the
constants and passes anything else through as custom.

### 7-4. ⚠️ Placement in lists (IVT risk)

`FastList` / `FastGrid` do real recycling on top of RecyclerView / UITableView.
A cell that scrolls off and back is unmounted and remounted, and **a new ad
request goes out** (wasted inventory, lower match rate, invalid-traffic
flagging).

The implemented mitigation is **teardown deferred by one microtask plus a
generation check** (§7-5): an element remounted within the same frame by
recycling is not destroyed; only a true unmount reaches `AdView.destroy()`.
**There is no per-slot ad cache** — a cell that scrolls far away and returns
re-requests. The README recommends `ScrollView` / `Column` and leaving
`keepAliveCount` unset.

### 7-5. Implementation notes (Android, confirmed on device)

1. **`createView` cannot receive ad configuration** (its only argument is the
   view type). Dart's `mount` first calls `bannerCreate(token, viewId, adUnitId,
   …)`, Kotlin queues a `FrameLayout`, and the `createView` that follows returns
   it. The reconciler asks for the view synchronously, so an empty container is
   returned at once and the `AdView` is inserted after load.
2. Both sides claim the same view type key (idempotent; never hard-code the
   number).
3. **Do not insert the `AdView` with `MATCH_PARENT`** — the creative was clipped
   on the right. Use its real size (dp × density) with `Gravity.CENTER`. AdMob
   forbids scaling and cropping.
4. Use `AdView.loadAd()` (`BannerAd.load()` is deprecated; load and registration
   are one step).
5. In `unmount`, after `release(token)`, check the generation number in
   `scheduleMicrotask` and only then call `bannerDispose`. On hot restart
   `reset()` destroys whatever is left. (This fixed a bug where no teardown path
   existed and `AdView`s lived forever.)

---

## 8. Native Ads design

### 8-1. The layout cannot be written in Dart (same as Flutter)

AdMob requires asset views to be registered as children of a `NativeAdView`,
and the SDK measures clicks and viewability on them. DartNative gives a plugin
one leaf view and a byte pipe, so Dart widgets cannot be placed inside the ad
view. This is an AdMob requirement, and Flutter's `google_mobile_ads` also
writes the layout in XML / xib.

The constraint only applies in the **Dart → native direction**. `NativeAdView`
is a `FrameLayout` (`BaseAdAssetViewContainer`), so building children on the
native side is unconstrained.

### 8-2. The two routes offered (same as Flutter)

| Route | What it does |
|---|---|
| Template | The bundled small / medium layouts are inflated in Kotlin and `NativeTemplateStyle` (JSON) applies colours, fonts and corner radius |
| Factory | The user implements and registers a `NativeAdFactory`; Dart names it with `factoryId`. `customOptions` is passed as JSON |

❌ A Dart layout overlaid with a transparent `NativeAdView` is not an option
(covering assets is a policy violation).

### 8-3. The Next-Gen SDK API (confirmed by `javap` on the `ads-mobile-sdk` `.aar`)

| Purpose | API |
|---|---|
| The ad | `nativead.NativeAd` (interface): `headline / body / icon / callToAction / starRating / store / price / advertiser / mediaContent` |
| Container | `nativead.NativeAdView` → `common.BaseAdAssetViewContainer` → `FrameLayout` |
| Asset registration | `setHeadlineView / setBodyView / setCallToActionView / setIconView / setStarRatingView / setAdvertiserView / setStoreView / setPriceView` |
| Binding / loading | `NativeAdView.registerNativeAd(ad, MediaView)` / `NativeAdLoader.load(NativeAdRequest, NativeAdLoaderCallback)` |
| Options | `NativeAdRequest.Builder`: `setMediaAspectRatio / setAdChoicesPlacement / setVideoOptions(VideoOptions.Builder) / disableImageDownloading` |

Notes: `setHeadlineView` and friends live on the **base class** (looking at
`NativeAdView` alone makes them look absent). The `MediaView` argument of
`registerNativeAd` is a required positional. `NativeAd` has no `destroy()`;
destroy via `NativeAdView.destroy()`. The `AdChoicesPlacement` enum order
differs from Dart's (`google_mobile_ads`-compatible, `topRight` first), so the
index is not passed through raw. There is no builder API corresponding to
`shouldRequestMultipleImages` / `requestCustomMuteThisAd`.

### 8-4. The templates are our own

Flutter's small / medium templates are not an SDK feature; they are assets
bundled with `google_mobile_ads` (Apache-2.0). The Next-Gen SDK `.aar` contains
no templates at all. Because this package is MIT and transcribes nothing,
`res/layout/gmak_native_ad_*.xml` and `NativeAdRenderer.kt` were **written from
scratch**. Default heights: small 144 (iOS) / 90 (Android), medium 350.

iOS small is 144 rather than 90 because AdMob requires a `MediaView` of **at
least 120x120pt** for video assets (discovered from the `media view size ...
too small` warning at runtime). A 120pt square plus vertical padding gives 144.
Android's small (`gmak_native_ad_small.xml`) has no MediaView — it is a 48dp
icon row — so it stays at 90; a shared default of 144 would only add ~54dp of
blank space on Android.

### 8-5. Factory registration API

```kotlin
GoogleMobileAdsKitPlugin.registerNativeAdFactory(context, "adFactoryExample", factory)   // Flutter takes an engine
GoogleMobileAdsKitPlugin.unregisterNativeAdFactory("adFactoryExample")
interface NativeAdFactory { fun createNativeAdView(nativeAd: NativeAd, customOptions: Map<String, Any?>): NativeAdView }
```

The Dart call is identical to Flutter's. A factory implementation ports by
swapping the import. What is registered is a factory, not a view; `factoryId`
is delivered by the same viewId-keyed pre-registration as banners. An
unregistered `factoryId` fails immediately with `onAdFailedToLoad` before
anything reaches the network.

### 8-6. Sizing (differs from banners)

A native ad's **height is not known in advance**, so Dart decides it: the
template default, or for factories the `height:` the user passes (small's 90 if
omitted). It is delivered by **taking the width from `LayoutBuilder` and emitting
`SetFlexAspectRatio(width / height)`** — the only size-related mutation a plugin
can emit (`SetFlexHeight` is not exported by `plugin.dart`). **Wrapping in a
`SizedBox` leaves the native view inside at 0x0 and nothing is drawn** (§8-7).

**However, `LayoutBuilder`'s width is the screen width, not the slot width**
(found on the simulator: inside a Column with 20pt padding it returned 402 while
the real width was 362). With that ratio Yoga produces a height of
`realWidth / (screenWidth / height)` — 144 shrinks to 130, 350 to 315. The fix
is **width feedback from native**: the container reports the width Yoga laid it
out at through a `laidOut` event (status 15, payload `{"width"}`), and if it
differs from the last emitted width by 0.5 or more, Dart re-emits
`SetFlexAspectRatio(realWidth / height)`. Yoga's recomputation is
`realWidth / (realWidth / height) = height` with the width unchanged, so native
does not fire again and it converges in one round trip. From then on `update()`
ignores `LayoutBuilder`'s value (it would keep reverting the correction with the
same wrong number). On iOS this is `GMAKAdContainer.layoutSubviews`; on Android
`addOnLayoutChangeListener`.

**`markDirty()` is mandatory after the re-emit.** The event arrives outside a
build, so a mutation emitted there is only queued, not flushed — without
`markDirty()` Dart is sending the right ratio and the container stays at 130
(confirmed on the simulator). Only a dirty element makes the reconciler flush
mutations and Yoga recompute.

### 8-6-1. iOS `MediaView` requirements (visible only at runtime)

Learned by running the AdMob validator and reading the SDK logs on the
simulator. **None of this shows up in type-checking**, so always verify on a
device or simulator when touching the iOS templates.

| SDK / validator complaint | Cause and fix |
|---|---|
| `MediaView not used for main image or video asset` | small had no `MediaView`. Android's small only uses an `ImageView` for the icon and passes the validator, but **iOS flags the absence of a MediaView itself**. The leading square became a `MediaView` |
| `media view size ... 0x0` | The code branched on `mediaContent` to decide whether to create a `MediaView`. `mainImage` can be nil at load time. **Always create it and always put it on screen** |
| `media view size ... 120x57` | A fixed size and an aspect-ratio constraint fought. Derive the height from the width consistently, and make the 120 floor `.required` (`UIStackView` lays out at `.required`, so anything weaker always loses) |
| Collapse at container height 0 | Yoga assigns the height **after mount**, so the container is 0 high while the template is built. `.required` top/bottom insets cannot be satisfied and get dropped. Lower the insets to `.defaultHigh` |
| `User interactions must be enabled on the GADMediaView` | The `MediaView` alone must have **taps enabled** — the opposite of the other asset views |
| medium: body squashed to 0pt, CTA to 12pt | The width-derived MediaView height (`.defaultHigh` = 750) tied with the labels' and button's compression resistance (default 750), and the stack squashed the text (a 1.35 asset gave a 250pt image and a 0pt body). Match Android's `0dp / layout_weight=1` semantics: text/CTA compression resistance and hugging at 999, the ratio constraint at `.defaultLow`. **The media absorbs the slack** |
| small CTA truncated to "Inst…" | `UIButton.intrinsicContentSize` excludes `directionalLayoutMargins`. `.required` compression resistance only protects the intrinsic size, which is 24pt short to begin with. Fixed with a `PaddedButton` that returns the margin-inclusive size |

**A MediaView for video assets must be at least 120x120pt** (the log states
that smaller ones will be demonetised in future). This is why small's default
height was raised 90 → 144 **on iOS only** (a `Platform.isIOS` branch; the
Android layout is unchanged).

> `User interactions must be disabled on the asset view` **remains, and is
> harmless.** It is logged on every load as long as the CTA is a `UIButton`, and
> taps work correctly (Google's own templates have had the same report since
> 2020, unfixed). Silencing it would mean replacing the `UIButton` with a
> `UILabel`, which loses the CTA's appearance.

### 8-7. Implementation notes (Android, confirmed on device)

Both the small and medium templates display, and **AdMob's own "native ad
validator" reports "No implementation issues found"** (the primary check of
asset registration). Two design changes:

1. The `null` contract of `createView` (§5-1) — violating it was why loads
   succeeded but nothing drew.
2. `SizedBox` is not enough; `SetFlexAspectRatio` is required (§8-6) — the
   original §8-6 said "wrap in a `SizedBox`", which was wrong.

---

## 9. Declaring native dependencies

### 9-1. iOS: `ios/google_mobile_ads_kit.podspec`

`s.platform = :ios, '15.0'` (Xcode 27's floor, §11-1),
`s.dependency 'Google-Mobile-Ads-SDK', '~> 13.0'` (v12 dropped the `GAD` prefix
from the Swift API names, so the code uses v13 names), `s.frameworks` includes
`AdSupport` / `AppTrackingTransparency`, and `pod_target_xcconfig` sets
`DEAD_CODE_STRIPPING = NO` (`@_cdecl` functions have no compile-time references
and are stripped in Release). Because of the `s.dependency`, `dn plugin build`
takes the CocoaPods path, which means **macOS is required** (§11).

**`s.static_framework = true` is mandatory** (found during the build). The GMA
SDK and the GoogleUserMessagingPlatform it pulls in are static frameworks;
without this, an app using `use_frameworks!` fails at `pod install` with
`has transitive dependencies that include statically linked binaries` — **it
never reaches compilation**, so no amount of Swift fixes helps. The
`google_mobile_ads` podspec declares it for the same reason.

**The app's deployment target must also be 15.0 or higher.** Lower fails at
`pod install` with `requires a higher minimum iOS deployment version than your
application is targeting` (the plugin name is shown, the required version is
not). The example raised both `ios/Podfile` and `Runner.xcodeproj`. The
official template's `s.dependency 'Flutter'` has been removed — not yet verified
on macOS (§12-6).

### 9-2. Android: `android/build.gradle`

**Groovy only** (the tooling looks for `build.gradle` by exact name). The
dependency is `com.google.android.libraries.ads.mobile.sdk:ads-mobile-sdk:1.4.0`
(resolves to 1.4.0; the API was verified with `javap` on 1.3.1 and builds and
runs unchanged on 1.4.0). The requirements minSdk 24 / compileSdk 35+ / Kotlin
1.9+ are met by this module (24 / 36 / 2.1). Imports come from
`com.google.android.libraries.ads.mobile.sdk.*`.

Constraints: pin explicit versions (an `.aar` has no POM); no Gradle variables
that span files; BOMs are fine.

**The real Next-Gen API versus the Legacy-style assumptions made at design time:**

| Assumed | Actual |
|---|---|
| `InterstitialAdLoadCallback` abstract class | `AdLoadCallback<T>` generic interface |
| `onPaidEventListener` | Folded into `AdEventCallback.onAdPaid(AdValue)` |
| `FullScreenContentCallback` | `AdEventCallback` plus per-format subclasses assigned to `ad.adEventCallback`. Every subclass extends the base, so **event handling is shared by the single `AdsBridge.AdEvents` class** |
| `MobileAds.setAppMuted` | `MobileAds.setUserMutedApp` |
| `error.code: Int` / `error.domain` | An enum (`.code.value`) / no domain (the plugin supplies one) |
| `setNeighboringContentUrls(List)` | `Set<String>` |
| `VideoOptions(a, b, c)` | The constructor is private; use `VideoOptions.Builder` |

### 9-3. AdMob App ID (set manually by the user)

There is no manifest merge, so the README explains it. The Next-Gen SDK itself
does not read the manifest — it takes the ID via
`InitializationConfig.Builder(appId)` — but users write the same `<meta-data>`
entry as for Legacy / Flutter, and `AdsBridge.initialize` reads it through
`PackageManager` and passes it on. That keeps `MobileAds.instance.initialize()`
argument-free. If it is missing, `initialize()` fails with a message telling
the user what to add, rather than letting the SDK crash. On iOS it is
`GADApplicationIdentifier` in `Info.plist`.

### 9-4. Android Gradle wiring (found during implementation)

1. **The engine classes (`DNNavigator` / `DNViewRegistry` / `DNPluginRegistry`)
   are not on the classpath automatically.** In an in-app build the sibling
   project `:dartnative_android` is referenced; in a standalone
   `dn plugin build`, the `.aar` from the SDK cache is referenced as
   `compileOnly` via `dn.sdk` in `local.properties` (putting it on the runtime
   classpath would duplicate a 17 MB `.so`).
2. **The engine embedding is not on Flutter's Maven** (`storage.googleapis.com`
   returns 404). Declare `https://cdn.dartnative.com/download.flutter.io`
   yourself.
3. **Do not remove the example's `dartnative_android` / `dartnative_ios`
   dependencies.** Removing them drops the engine `.aar` from the classpath and
   linking fails on `Theme.Material3.*`. Running `dn pub get` from the plugin
   root rewrites the example's pubspec and causes exactly this.

---

## 10. Implementation status

| # | Item | Status |
|---|---|---|
| 1–2 | Android: Interstitial / Rewarded / Rewarded Interstitial / App Open + event path | ✅ All four formats share one load and event path (`full_screen_ad.dart` / `AdsBridge.AdEvents`). App Open lifecycle detection is not implemented (the user decides when to show) |
| 3 | Android: Banner | ✅ Fixed and adaptive both display on device |
| 4 | iOS in general | 🟡 **Every format implemented** (preloading included). `swiftc -typecheck` passes against the real SDK, `dn plugin build` succeeds, every format loads on the simulator and the templates pass the validator. **Not verified on hardware** |
| 5 | Preloading | ✅ Implemented on both platforms. Android: build and symbols confirmed; iOS: Beta module (§1-1). **Buffer behaviour not verified on a device on either** |
| 6 | Android: Native Ads | ✅ Displays on device, validator passed |

**iOS file structure.** The original single `GMAKMobileAds.swift` was split by
role (`private` is file-scoped in Swift, so shared items had to move into
`GMAKCore.swift` as internal):

| File | Role |
|---|---|
| `GMAKCore.swift` | Event contract, dispatcher slot, `Request` assembly, payload conversion |
| `GMAKMobileAds.swift` | The 4 full-screen formats. Also takes over preloaded ads (`show` / `dispose` look in the same dictionary) |
| `GMAKPreloader.swift` | The 4 preloaders. Needs `import GoogleMobileAds_Private` |
| `GMAKMobileAdsProvider.swift` | Registration with `DNRegisterPluginProvider`, `createView` / `handleMutation`, the container |
| `GMAKStore.swift` | Retaining and releasing ads keyed by viewId, the container hand-off queue |
| `GMAKBannerAd.swift` | `BannerView` loading and events |
| `GMAKNativeAd.swift` | `AdLoader`, `GMAKNativeAdFactory` registration, option conversion |
| `GMAKNativeAdTemplate.swift` | The small / medium templates built with Auto Layout |

**Where iOS differs from Android:**

1. **Provider registration is called from Dart.** On Android the registrant
   instantiates the plugin class; iOS has no such mechanism. `loadSymbols()`
   calls `GMAKRegisterProvider` (§12-1).
2. **The enum orders match Dart.** `AdChoicesPosition` / `MediaAspectRatio` are
   declared in the same order as Dart in the iOS SDK, so the index passes
   through raw. Android's order differs and needs a mapping (§8-3) — **this is
   the trap when copying iOS code to Android**.
3. **Asset registration is property assignment.** iOS uses
   `adView.headlineView = label`, and binding is `adView.nativeAd = ad` (the
   counterpart of Android's `registerNativeAd(ad, mediaView)`). `MediaView` is
   only in the medium template and is not a required argument.
4. **The templates are built in code.** A source-only pod cannot carry XML
   layouts, so the equivalent of `res/layout/gmak_native_ad_*.xml` is written in
   Auto Layout. Appearance and default font sizes match the XML.

**Preloading decisions:** tokens for preloaded ads are assigned by Kotlin (Dart
uses positive values, Kotlin negative, to avoid collisions).
`peekAdResponseInfo` refers to the *next* ad, so it is fetched and cached just
before the poll. Synchronous JSON returns (§5-3) were added for
`getConfigurations` and friends. `RewardedInterstitialAdPreloader`, absent
upstream, is offered because the SDK has it.

**API compatibility (checked against upstream source):** `load` / `show` /
`dispose` and the preloaders return `Future`. `InterstitialAdLoadCallback` and
friends are subclasses of `FullScreenAdLoadCallback<T>`. `Ad.responseInfo` /
`onPaidEvent` / `setImmersiveMode` / `setServerSideOptions` are present.

---

## 11. Known obstacles

| Obstacle | Severity | Detail |
|---|---|---|
| iOS builds need a Mac | High | `import GoogleMobileAds` forces the pods path. `dn plugin build` exits immediately on non-macOS |
| Android callbacks are on background threads | High | One missed hop and `Pointer.fromFunction`'s isolate constraint crashes the app (§6) |
| JNI exception propagation | High | A failed `GetStaticMethodID` leaves an exception pending and the next JNI call aborts the process. `FindMethod` calls `ExceptionClear` every time. Only reproduces on a device |
| The `null` contract of `createView` | Medium | §5-1. Invisible while there is only one view type |
| Re-requests in lists | Medium | §7-4 |
| No reference native implementation | Medium | The SDK's bundled plugins ship no source. The official tutorial and `.aar` disassembly are all there is |
| Manual App ID setup | Low | §9-3 |

### 11-1. Environment conditions for `dn plugin build` to pass

**Android builds first, and a failure there never reaches iOS.** What looks like
an iOS error can be an Android one.

| Symptom | Cause and fix |
|---|---|
| `the framework checkout could not be located` | `dn plugin build` **greps `android/build.gradle` with a regex**; the literal `project(':dartnative_android')` makes it demand the framework's **source checkout** and `throwToolExit` at once. The `.aar` fallback in build.gradle (`dn.sdk` / `DN_SDK`) is **never reached**. → Assemble the project path by string concatenation so the grep misses. **A literal inside a comment matches too.** |
| `Engine artifacts not found … Flutter.xcframework` | `dn --version` does not download the engine. Run `dn precache --ios` once |
| `Loading a plug-in failed` / `CoreSimulator is out of date` | Bundled packages not installed after an Xcode update. `sudo xcodebuild -runFirstLaunch`. **It fails before reaching compilation**, so it looks like a code error (0 Swift compile tasks means the environment) |
| `deployment target … supported range is 15.0 to 27.0.x` | Xcode 27 refuses anything below iOS 15. The podspec's `s.platform` was raised to 15.0 (§1-2). The GMA SDK itself declares 12.0; this is not an SDK requirement |
| `nm` / `strings` unavailable | Xcode license not accepted. `sudo xcodebuild -license accept` |

---

## 12. Open questions

### 12-1. ~~The iOS plugin provider contract~~

**Resolved. It is a different shape from Android's.** There is no protocol to
implement on iOS; instead **two C function pointers are registered with the
engine**:

```
DNRegisterPluginProvider(createView, handleMutation)   registration
DNViewTypeClaim(key) -> Int32                          the iOS side of ViewType.claim
DNViewRegistryGetView(viewId) -> Int64                 viewId -> UIView
```

`createView: @convention(c) (Int32) -> Int64` returns
`Unmanaged.passRetained(view).toOpaque()` as an Int64 and **returns 0 for a view
type that is not yours** (the same hijacking accident as Android's `null`
contract, §5-1). `handleMutation` is
`(Int64, Int32, UnsafePointer<UInt8>?, Int32) -> Void`.

Symbols are resolved with `dlsym(dlopen(nil, RTLD_NOLOAD), …)`.
**`import dartnative_ios` is not possible** — the framework is what loads the
plugin, so CocoaPods would see a cycle.

Engine registration is not automatic: on Android the registrant instantiates
the plugin class, but on iOS nothing enters the pod until Dart's
`loadSymbols()` calls `GMAKRegisterProvider`.

Evidence: the official `docs/plugin_development.md` §3, and `nm` on
`dartnative_ios.xcframework` confirming all four symbols are exported (`T`).
### 12-2. ~~iOS numbering for `ViewType.claim()`~~

**Resolved.** iOS claims the same key string through `DNViewTypeClaim` and the
engine returns the same number on both sides (§12-1). As on Android, the number
is never hard-coded.
### 12-3. `dartnative_*` naming and the first-party allowlist

— The tutorial calls itself `dartnative_share`, but the relationship to
`dn_first_party.json` was unconfirmed. Check on dartpub.dev before publishing.
(See research.md §14-7: third parties may not use the prefix; hence the rename
to `google_mobile_ads_kit`.)
### 12-4. ~~Location of `CMakeLists.txt`~~

**Resolved.** `src/CMakeLists.txt` at the plugin root, confirmed by direct
comparison with the output of `dn create --template plugin_ffi`.
### 12-5. License requirements for third-party publishing

— Whether the free Community plan allows publishing to dartpub.dev is
unconfirmed. A publishing precondition, not a technical issue.
### 12-6. Verifying the podspec on macOS

— `pod lib lint` with `:file => '../LICENSE'`, and whether removing the official
template's `s.dependency 'Flutter'` is correct. First thing to check when
starting iOS work.
### 12-7. Prerelease

— The SDK constraint `^3.12.0-192.0.dev` is what `dn create` emits and cannot
be changed. The package version is `0.1.0` (a normal release). pub **warns**
that a prerelease SDK constraint should come with a prerelease version, but
does not refuse; the warning is accepted and the normal version kept. How
dartpub.dev / `dn plugin publish` treat this constraint is unconfirmed.
### 12-8. ~~The native ad factory registration API~~

**Resolved** (§8-5). The iOS side follows from §12-1.
### 12-9. Android SDK: Next-Gen only (option A chosen)

| | Legacy `play-services-ads` | Next-Gen `ads-mobile-sdk` |
|---|---|---|
| Status | Explicitly "Legacy" | GA. The official default |
| Initialisation / App ID | Optional / manifest | **Required** / code (`InitializationConfig`). **Must be called off the main thread** |
| Callbacks | Main thread | **Background thread** |
| Mediation | Many networks | AdMob only |

---

## 13. Documentation and distribution

- `doc/` (singular, per pub convention). `design.md` and
  `migration_from_flutter.md` ship; `research.md` is contributor material and
  excluded by `.pubignore`.
- The consumer agent skill is `skills/google-mobile-ads-kit-usage/` (scaffolded
  with `dart run skills@ create`; the directory name and `name:` must match).
  Contributor skills live in `.claude/skills/`.
- `dart pub publish --dry-run` warns only about uncommitted changes and the
  prerelease SDK constraint (the latter accepted per §12-7; the singular `doc/`,
  the CHANGELOG heading and the `.vscode` ignore scope are already handled).
