# google_mobile_ads_kit

Google Mobile Ads (AdMob) plugin for DartNative. Published package — everything
here ships to users.

## Where to start

Read in this order. The implementation manual is written in Japanese; the
rest is English.

1. This file — the rules you must not break.
2. `.claude/skills/dartnative-plugin/SKILL.md` (JA, ~460 lines) — **the
   implementation manual.** Working FFI skeletons, the dispatcher-slot code for
   both platforms, the JNI shim, `NativeElement`. This is what you actually type.
3. [`doc/design.md`](doc/design.md) (EN, ~650 lines) — what we built and why,
   updated to the shipped state. §10 is the status table, §12 the open
   questions. Section numbers are cited from code — never renumber them.
4. [`doc/research.md`](doc/research.md) (EN, ~400 lines) — evidence only.
   Read §0, then dip in when you need to know *how we know* something.
5. [`README.md`](README.md) / [`doc/migration_from_flutter.md`](doc/migration_from_flutter.md)
   (EN) — the user-facing view.

## Two things that will change your plan

- **iOS artifacts require macOS + Xcode.** `import GoogleMobileAds` forces the
  CocoaPods build path and `dn plugin build` exits immediately on other hosts.
  On Windows you can complete all Dart and Android work, nothing iOS.
- **Every format is implemented on both platforms, but iOS has only run on
  the simulator.** Every format loads there and the built-in templates pass
  AdMob's native ad validator, but nothing has been checked on real iOS
  hardware. Treat iOS device behaviour as unverified (`doc/design.md` §1-1).
- **The iOS preloader lives in a module a plain import cannot see.** Its
  headers are under `PrivateHeaders/` (`GAD*Preloader_Beta.h`), reachable only
  by adding `import GoogleMobileAds_Private`. Searching `Headers/` alone makes
  the whole API look absent — it is not. Being Beta, it can change between SDK
  releases; the podspec's `~> 13.0` pin bounds that (`doc/design.md` §1-1).
- **The iOS provider contract is not Android's.** No protocol to implement:
  register two C function pointers through `DNRegisterPluginProvider`, resolved
  with `dlsym` — never `import dartnative_ios` (it would be a circular pod).
  Registration is triggered from Dart's `loadSymbols()`, because iOS has no
  registrant hook (`doc/design.md` §12-1).
- **Banners are not native ads.** A banner is one `AdView`/`BannerView` that the
  SDK draws entirely on its own — the plugin returns a single view and writes no
  layout. *Native ads* instead need the layout built natively, either from one of
  the templates this package ships or from an app-registered factory
  (`doc/design.md` §8). Both are implemented on both platforms.
- **`createView` must disown a view type that is not yours** — `null` on
  Android, `0` on iOS. The registry takes the first non-null/non-zero result and
  stops, so returning a placeholder hijacks every other plugin's views. This does
  not show up until a second view type exists (`doc/design.md` §5-1).
- **Enum indices cross the FFI boundary raw, and the two platforms disagree.**
  `AdChoicesPlacement` / `MediaAspectRatio` happen to match the Dart order on
  iOS, so they pass straight through; Android's differ and are remapped. Never
  copy one platform's handling to the other (`doc/design.md` §8-3).
- **A hosted view's size reaches Yoga only through `SetFlexAspectRatio`.**
  Wrapping the widget in a `SizedBox` sizes the Dart box and leaves the native
  view at 0x0 — it loads but never appears (`doc/design.md` §8-7).

---

## ⚠️ DartNative is not Flutter

The widget API looks familiar, but the internals are different and the framework
is new enough that it is largely absent from model training data. None of the
following exist here:

- ❌ `MethodChannel` / `EventChannel` / `BasicMessageChannel`
- ❌ `PlatformView` / `AndroidView` / `UiKitView`
- ❌ `AdWidget` (the Flutter `google_mobile_ads` banner wrapper)
- ❌ `WidgetsFlutterBinding.ensureInitialized()`
  → use `DartNativePluginRegistrant.registerAll()`

Use **`dart:ffi`** (C ABI, synchronous) and **`NativeElement`** instead.

## Decisions for this repository

| Topic | Decision | Why |
|---|---|---|
| Public Dart API | Follow `google_mobile_ads` | Ecosystem convention; eases migration |
| Internal implementation | Do not port from Flutter | It depends on MethodChannel / PlatformView |
| License | MIT | Nothing substantive is transcribed from upstream |
| Android manifest entry | Declare `pluginClass` (**never `ffiPlugin: true`**) | Otherwise ad callbacks die with `UnsatisfiedLinkError` |
| `android/build.gradle` | **Groovy**, not `.kts` | The tooling looks for `build.gradle` by exact name |
| Native → Dart callbacks | `Pointer.fromFunction` + dispatcher slot | Official pattern; not `NativeCallable` |
| Maven coordinates | Pin explicit versions | An `.aar` has no POM, so versionless deps cannot resolve |
| Android ad SDK | **GMA Next-Gen SDK only** (`ads-mobile-sdk`), no legacy switch | A prebuilt `.aar` cannot pick an SDK at app build time (`doc/design.md` §12-9) |

## Commands

```bash
dn pub get                  # resolve deps + regenerate the plugin registrant
cd example && dn run        # run on a device/emulator (r = hot reload)
dn plugin build             # produce the distributable artifact in dist/
dart analyze                # static analysis
```

## Working notes

- Check the relevant section of `doc/design.md` before implementing. If
  something is unspecified, see `doc/design.md` §12 (open questions) rather than deciding ad hoc.
- After any async hop on the native side, **return to the main thread** before
  firing a Dart callback. On Android this is not optional: the Next-Gen SDK fires
  every ad callback on a background thread, and `MobileAds.initialize` must itself
  be called off the main thread.
- Never destroy an ad view synchronously in `unmount` — a recycled list cell
  unmounts and remounts within one frame. Teardown is deferred one microtask
  and skipped if the element mounted again (`doc/design.md` §7-5).
- Every public declaration needs a `///` doc comment: this package's API docs are
  published to dartpub.dev and count toward its score. See the
  `dart-write-documentation` skill.
