# Research log — the technical groundwork for DartNative plugin development

> **This document is a record of research; the design decisions live in
> [`design.md`](design.md).** Read it when you want to check the evidence behind
> the design spec, or before re-investigating DartNative internals. It exists so
> the same research is not repeated.
>
> Sources are tagged `[dart-src]` (Dart source bundled with the SDK) /
> `[bytecode]` (`javap` on an AAR) / `[disasm]` (`llvm-objdump` on a `.so`) /
> `[tutorial]` (official tutorial) / `[inferred]`.
>
> **⚠️ Some findings were overturned after implementation (2026-09-15).** This
> document is kept as a record of what was known *at the time*; where it
> conflicts with what the implementation revealed, **the corresponding section
> of `design.md` is authoritative**. Overturned findings are marked "overturned
> by implementation" (e.g. §14-4). The design drafts from research time (old
> §3–§10) have their final form in `design.md`, so here they are compressed down
> to the supporting evidence. Repository only; not shipped (`.pubignore`).

- Researched: 2026-09-15 / Targets: DartNative 3.45.0-0.1.pre / Dart 3.12.0-192.0.dev
- `<SDK>` is the root of the installed DartNative SDK
  (`dirname $(dirname $(which dn))`, default `~/zero`)

## Summary (feasibility of the six AdMob formats → outcome)

| Format | Assessment at research time | Outcome (Android) |
|---|---|---|
| Interstitial / Rewarded / Rewarded Interstitial / App Open | 🟢 Easy; no view needed | ✅ |
| Banner (fixed / adaptive) | 🟢 / 🟡 Cannot report an intrinsic size, but the height is known up front | ✅ |
| Banner in `FastList` | 🟠 Recycling re-requests | ⚠️ Mitigated by deferred teardown; README discourages it |
| Native Ads (template / custom) | 🟡 Write the layout natively (same as Flutter) | ✅ Validator passed |

---

## 0. Read this first: DartNative is not Flutter

DartNative appeared in 2026 and is almost entirely absent from LLM training
data. An AI will, with high probability, **confidently propose non-existent
APIs** on the assumption that it is Flutter.

| | Flutter | DartNative |
|---|---|---|
| Native views | PlatformView (composited) | **Native views inserted directly into the tree** |
| Dart ↔ native | MethodChannel (asynchronous) | **Direct `dart:ffi` calls (synchronous)** |
| Layout / threads | Own engine / separate UI and raster threads | **Yoga** / **Dart runs on the main thread. No raster thread** |

Things that do not exist: the `MethodChannel` family, `PlatformView` /
`AndroidView` / `UiKitView`, the internals of `google_mobile_ads` (`AdWidget`
etc.), anything that assumes `PlatformDispatcher`. Things not to do: write
`android/build.gradle` as `.kts` (§5), set `ffiPlugin: true` for Android in the
pubspec (§4), call into Dart after an async hop on the native side without
returning to main (§6).

From `google_mobile_ads` we **keep the public API and the native-ads layout
approach; the internals cannot be reused** (§13). Banners are actually simpler
in DartNative — there is no PlatformView compositing cost and no rendering
glitches.

---

## 1. There is no native reference source

The 37 first-party plugins bundled with the SDK contain **not a single line of
native source** (zero `*.podspec` under `<SDK>/`, the only `*.swift` are app
templates, the only `*.kt` are Gradle plugins). Their structure is `lib/**.dart`
(every method `throw UnimplementedError()`) + `dart/*/*.dill` (compiled) +
`pubspec.yaml` + `manifest.json`. **All you can read is the pubspec and the
Dart signatures.** The real source is the private
`github.com/DartNative/dartnative_plugins`.

Trick: `strings -n 4 <pkg>/dart/debug/<pkg>.dill` recovers call order and
literals from the string table.

---

## 2. Primary sources

| Source | Importance | Content |
|---|---|---|
| https://dartnative.com/tutorials/build-a-plugin/ | ★★★ | The only official material covering plugin structure, FFI and the Swift/Kotlin bridges. Confirmed facts in §14 |
| https://dartnative.com/tutorials/google-maps/ | ★★★ | Embedding a native view + a native-side API key. Same shape as a banner |
| https://dartnative.com/tutorials/publish-your-plugin/ | ★★ | Publishing to dartpub.dev |
| `<SDK>/packages/flutter_tools/lib/src/commands/plugin_build.dart` | ★★★ | The packaging spec (2000+ lines). Authoritative on podspec / build.gradle constraints |
| `<SDK>/packages/flutter_tools/lib/src/flutter_plugins.dart` (L494-760) | ★★★ | Registrant generation |
| `<SDK>/bin/cache/pkg/dartnative/lib/plugin.dart` | ★★★ | **The only non-stub API definition.** The export list for plugin authors |
| `…/dartnative/lib/src/reconciler/{mutations,element}.dart` | ★★★ | Definitions of `ViewType` / `ViewProps` / `PluginMutation` / `NativeElement` |
| `<SDK>/packages/flutter_tools/templates/plugin_ffi/` | ★★★ | The only real podspec / CMakeLists / build.gradle template (`dn create --template plugin_ffi`) |
| `dartnative_android.aar` / `libdartnative_android.so` | ★★★ | The provider contract and registry behaviour were confirmed by disassembling these (§12) |

Bundled plugins whose pubspecs / typedefs were consulted: `dartnative_firebase`
(why `pluginClass` is required), `dartnative_revenuecat` (int64 token + JSON
dispatcher), `dartnative_webview` (minimal `NativeElement` example),
`dartnative_google_maps` (two-layer structure + API key),
`dartnative_video_player` (the canonical use of `SetFlexAspectRatio`).

---

## 3. Callback approaches considered (final form: design.md §5-2)

The bundled plugins use two approaches `[dart-src]`: **A. function-pointer
registration** (`dartnative_firebase`) and **B. int64 token + single dispatcher
+ JSON** (`dartnative_revenuecat`). AdMob needs B (it can carry the error
details for `onAdFailedToLoad`). The bundled plugins **do not use
`NativeCallable`** (zero grep hits). `DnCallbacks.arm()` also exists, but the
official tutorial shows `Pointer.fromFunction` + a dispatcher slot, so that was
adopted (§14-4).

The layout mutations exported by `plugin.dart` are `SetAlignSelf` /
`SetFlexAspectRatio` / `SetFlexPositionType` / `SetFlexPositionInsets` **only**.
`SetFlexWidth` / `SetFlexHeight` / `SetViewHidden` exist in `mutations.dart` but
are not exported `[dart-src]` — the constraint that shaped native ad height
handling (design.md §8-6).

---

## 4. `pluginClass`, not `ffiPlugin` (final form: design.md §4)

Verbatim from `dartnative_firebase/pubspec.yaml` `[dart-src]`:

> NOT ffiPlugin: an ffi-only Android plugin is never added to GeneratedPluginRegistrant,
> so DartNativeFirebasePlugin.onAttachedToEngine (which System.loadLibrary's
> libdartnative_firebase.so) never runs and FCM's reverse-JNI nativeOnTokenRefresh
> crashes with UnsatisfiedLinkError.

Ad events are exactly that reverse JNI. Manifest key rules: `registrant.imports`
are bare package URIs, `registrant.calls` are complete Dart statements including
the `;`, `flutter:` and `dartnative:` are merged with `dartnative:` winning on
conflict. The registrant is regenerated on every `dn pub get` (overwritten only
when line 1 is `// GENERATED FILE — DO NOT EDIT BY HAND.`).

---

## 5. Native dependency constraints (final form: design.md §9)

- **`build.gradle` must be Groovy**: `plugin_build.dart:751` hard-codes
  `androidDir.childFile('build.gradle')`; if absent, the Android artifact is
  **skipped and null is returned**. The dependency-extraction regexes (:800-843)
  also assume Groovy. `dn create --template=plugin_ffi` emits Groovy too (§14-2).
  The tutorial diagram's `build.gradle.kts` is a typo (§14-5).
- **Maven coordinates**: a versionless coordinate is skipped with a warning (an
  `.aar` has no POM); a Gradle variable spanning files is a `throwToolExit`;
  BOMs are fine.
- **podspec**: sources are `ios/Classes/` (`.swift .m .mm .c .cc .cpp`).
  Declaring `s.dependency` selects the "pods" path (CocoaPods + `xcodebuild`),
  and `import GoogleMobileAds` needs that path anyway. The consumer podspec gets
  `DEAD_CODE_STRIPPING = NO` (`_PodspecInfo.read` :1723-1768).
- **The AdMob App ID** is set by the user by hand because there is no manifest
  merge (treated like `dartnative_google_maps`'s API key).

---

## 6. Evidence for the threading model (final form: design.md §6)

Verbatim `[dart-src]`: `dartnative_ios/pubspec.yaml` — "Dart runs on the iOS
platform (main) thread, making all UIKit calls synchronous with no thread
hopping" / `dartnative/lib/src/core.dart:630-632` — "rendering is synchronous on
the main thread — there is no separate raster thread".

The tutorial's actual code nonetheless uses `DispatchQueue.main.async` /
`Handler(...).post` (§14-6): unnecessary for synchronous calls, but **after any
async hop on the native side you must return to main before firing into Dart**.
The early claim that "Android AdMob listeners fire on main" applied to the
Legacy SDK and is **wrong** — Next-Gen fires every callback on a background
thread.

Dart timers do not stop in the background (`core.dart:661-667`).

---

## 7–10. Design drafts (→ merged into design.md)

The directory layout proposal, implementation order, obstacle list and open
items from research time have their final form in design.md §3-2 / §10 / §11 /
§12. Only the questions raised and **resolved** during research are listed here:

- The input structure for `dn plugin build` → settled by the tutorial plus the
  scaffold (§14)
- The callback approach → `Pointer.fromFunction` + slot (§14-4)
- Reuse from `google_mobile_ads` and licensing → MIT is fine (§13-3)
- The iOS provider contract, `ViewType` numbering, `dartnative_*` naming and
  publishing license requirements → **carried over unresolved to design.md §12**

---

## 11. Development environment and AI assistance

- DartNative SDK (`dn --version`), Android SDK 36, iOS **requires macOS +
  Xcode**. A plugin of your own can be developed on the free Community plan
  (startup log `Launch check ok — tier=free`). The trial token's `apps`
  allowlist covers only the official samples, though, so your own app needs
  `dn config --license-key=...` (otherwise the screen shows
  `No DartNative license found.`).
- `dn doctor` / `dn emulators --launch <id>` / `dn run` (r = reload,
  R = restart) / `dn plugin build`.
- The official skills `dartnative/dartnative@dart-native` and
  `@dart-native-porting` are **consumer-side** knowledge and say nothing about
  plugin development (`NativeElement` / `@_cdecl` / JNI / `ViewType` / podspec).
  `.claude/skills/dartnative-plugin` fills that gap, and
  `skills/google-mobile-ads-kit-usage` is distributed to users.
  `dart-use-ffigen` (which discourages hand-written FFI) and the Flutter skills
  conflict with the approach here and are not included.
- When having an AI implement, **put the prohibitions at the top of the spec**
  (§0). Because DartNative is not in training data, negative statements ("this
  does not exist") work better than positive ones. Establish the verification
  loop (`dn run` on a device) first.

---

## 12. Feasibility per format (details and evidence)

Confirmed with `javap` on the Android AAR and `llvm-objdump` on
`libdartnative_android.so`. **The iOS side was unverified at research time** (no
readable framework; design.md §12-1).

### 12-1. 🟡 Native Ads — write the layout natively (same as Flutter)

> The first draft rated this "🔴 blocked", which was **wrong**. The reason a
> Dart widget cannot be a child of the ad view is a requirement of the AdMob
> SDK, and Flutter's official plugin says as much — "your app — rather than
> Google Mobile Ads Flutter Plugin — is then responsible for displaying them" —
> and uses XML / xib + `NativeAdFactory`.

The technical fact (correct) `[bytecode]`: the interface a plugin has on the
native side has exactly two methods.

```java
public interface com.dartnative.DNAndroidPluginProvider {
  @Nullable View createView(int);          // null = not my view type
  void handleMutation(long, int, byte[]);
}
```

Three confirmations that there is no API for inserting a child view: (1) the
interface above has nothing like `insertChild`; (2) `NativeElement`
(`element.dart:127-148`) has no `children` / `replaceChild` override and
`plugin.dart` exposes no child mechanism `[dart-src]`; (3) the built-in
containers' `_emitFlexChild()` (`native_elements.dart:21`) is file-private, and
the native `DNFlexLayout.insertChild` is reconciler-internal `[bytecode]`.

→ The constraint applies **only in the Dart → native direction**. `NativeAdView`
is a `FrameLayout`, so building children natively is unconstrained. Both of the
Flutter plugin's routes (template / factory) are offered as-is (design.md §8).
❌ Overlaying a Dart layout on a transparent `NativeAdView` covers the assets
and violates policy.

**Found during implementation (design.md §5-1):**
`DNPluginRegistry.createView(int)` walks providers in registration order and
**stops at the first non-null** `[bytecode]`. Return a placeholder and the
providers after you are never called.

### 12-2. 🟢 Full-screen formats

No views involved, so neither `createView` nor `ViewType.claim()` is needed. The
SDK presents them itself via `show(activity)`. The `Activity` comes from
`DNNavigator.activity()` `[bytecode]`. `registerAppLifecycleCallback`
(`uikit_bindings.dart:162`) `[dart-src]` could drive App Open lifecycle
detection (not implemented). DartNative's own full-screen APIs
(`presentDartSheet` etc.) are not used for AdMob.

### 12-3. 🟡 Banner (adaptive) — no intrinsic size reporting, but avoidable

`DNViewFactory.register(View)` `[bytecode]`:

```
27: instanceof    android/view/ViewGroup
30: ifne          38                     ← skipped for a ViewGroup
35: invokestatic  DNFlexLayout.attachIntrinsicMeasure:(JLandroid/view/View;)V
```

`attachIntrinsicMeasure` only applies to non-`ViewGroup`s, and on the plugin
path it is **never called at all**. No mutation requesting a relayout is
exported either (§3). `Element.markDirty()` is for rebuilding Dart elements.

Workaround: an ad's height **can be computed analytically in advance**. Take
the width from `LayoutBuilder` (`builders.dart:26-31`), get the height from the
native `getLargeAnchoredAdaptiveBannerAdSize(ctx, widthDp)`, and emit
`SetFlexAspectRatio(w/h)` at mount. This is the canonical technique used by
`dartnative_video_player` (`video_player.dart:126-128`). Combine with
`stretchAsStackFlowChild => true`.

### 12-4. 🟠 Banners in lists — re-requests from recycling

`FastList` / `FastGrid` / `MasonryFastGrid` do **genuine recycling** through
`DNFastListBridge$DNFastListAdapter extends RecyclerView$Adapter`
(`onCreateViewHolder` / `onBindViewHolder` / `onViewRecycled`) `[bytecode]`. The
cell `DNCellContainer extends FrameLayout` attaches and detaches views with
`clearChildren()` / `swapView()`. Setting `keepAliveCount`
(`fast_list.dart:238-257`) **disposes** the content of off-screen rows
(verbatim: "has its built content disposed").

A hook usable for hot-restart cleanup:
`DNViewRegistry.registerResetHook(Function0<Unit>)` `[bytecode]` — the evidence
behind design.md §5-2.

The final mitigation is design.md §7-4 (deferred teardown + generation check,
`keepAliveCount` unset, non-recycling containers recommended).

### 12-5. Passing image assets

There is no API for handing a native image handle (`Drawable` / `UIImage`) to
Dart `[dart-src][bytecode]` (`ImageProvider` has only Network / Asset / File /
Memory). Since native ads are rendered natively in both the template and
factory routes, **this path is no longer needed**. For reference: the shared
Coil / NSCache caches, `ImageCache.configure` (`image.dart:203-273`).

### 12-6. Actual behaviour of the ViewType registry `[disasm]`

`DNViewTypeClaim` (`0xae2ec0`): **counts down from 65535**, floor 60000
(`mov w10, #0xea5f`), process-global, `std::mutex`, **idempotent per key**,
never released. The empty string yields `-1`. `DNViewFactory.create(int)` treats
**below 100 as built-in** via `tableswitch` and sends 100 and above to
`DNPluginRegistry.createView` `[bytecode]`. Of the 31 built-ins, the ones
exposed as Dart `ViewType` constants are the six `view / label / button /
floatingActionButton / shimmer / searchBar` (`DNImageView` (6) cannot be named
from a plugin).

### 12-7. `PluginMutation` caveats

`DNPluginRegistry.handleMutation(long, int, byte[])` is **broadcast to every
provider** `[bytecode]` → `eventTag` can collide. There is no explicit payload
limit (only bounds checks in the batch decoder, 32-bit offsets `[inferred]`).
Large data should go via a URL or file.

### 12-8. Possible requests to the SDK vendor (low priority)

The "native ads cannot be implemented" argument is withdrawn (Flutter writes
them natively too). Nice-to-haves: an API for mounting children into a plugin
view; applying `attachIntrinsicMeasure` to plugin views (the generic
`View.measure()` path is already implemented at
`attachIntrinsicMeasure$lambda$4+308` and merely not reached by the branch).
More important is **disclosure**: access to `dartnative_plugins`, the iOS
plugin contract, whether `dartnative_*` naming is allowed, and the license
requirements for publishing.

### 12-9. Conclusion on "conversion"

No code generation (a `pigeon` equivalent) is needed. Every bundled plugin
hand-writes its typedefs. What is actually required is marshalling in two
places — Dart → native as JSON strings (this plugin did not even use
`PluginMutation`'s raw bytes), native → Dart as int64 token + JSON. Synchronous
string reads follow the webview approach (caller buffer + written length).

---

## 13. Flutter compatibility policy (guiding the public API design)

### 13-1. The ecosystem's explicit convention `[dart-src]`

| Plugin | Verbatim |
|---|---|
| `dartnative_revenuecat` | "**Drop-in replacement for** RevenueCat's `purchases_flutter`" / "Derived from purchases_flutter by RevenueCat, Inc. (MIT)" |
| `dartnative_firebase` | "API surface mirrors the original where possible so that migration diffs are [minimal]" |
| `dartnative_shared_preferences` / `url_launcher` / `path_provider` / `permissions` | All declare themselves a "**Drop-in** replacement" |

→ `google_mobile_ads_kit` follows the public API of `google_mobile_ads` too.

### 13-2. Policy per layer

Class names, method names, parameter names, enums, listeners, the factory
registration flow, error structures = ✅ match. Internal implementation = ❌
cannot be reused.

### 13-3. License: MIT is fine

`google_mobile_ads` is Apache-2.0, but its Dart implementation depends on
`instanceManager` (MethodChannel), everything from `load()` down is implemented
differently here, and the display side (`AdWidget`) does not exist. What
matches is only field declarations that can be written one way and constant
values from the official AdMob documentation → **no situation arises where a
block of code is transcribed**. `LICENSE` is MIT alone; no `NOTICE`. References
are the official AdMob docs (constants, error codes) and the pub.dev API
reference (method names, parameter order). The only thing to avoid is pasting
upstream source files wholesale. The pubspec `description` says "API surface
follows google_mobile_ads" (not "Based on"). The native ad templates (Apache-2.0
assets bundled upstream) were written from scratch for the same reason
(design.md §8-4).

---

## 14. Facts confirmed from the official tutorial `[tutorial]`

Sources: https://dartnative.com/tutorials/build-a-plugin/ (`dartnative_share`)
and the output of `dn create --template=plugin_ffi`.

### 14-1. Directory structure

Tutorial: `lib/` `ios/Classes/DNShareBridge.swift`
`android/src/main/kotlin/…/{DartNativeSharePlugin,ShareBridge}.kt`
`android/src/main/cpp/share_bridge.cpp` `android/CMakeLists.txt`
`android/build.gradle`. Kotlin is two files: the "plugin class" and the "worker
class". For the location of `CMakeLists.txt`, the tool template's
`src/CMakeLists.txt` was adopted (§14-5).

### 14-2. Scaffold: `dn create --template=plugin_ffi --platforms=android,ios <name>`

Generates: `lib/<name>.dart`, `lib/<name>_bindings_generated.dart`,
`ios/Classes/<name>.c`, `ios/<name>.podspec`, `android/build.gradle`,
`android/src/main/AndroidManifest.xml`, `src/CMakeLists.txt`, `src/<name>.{c,h}`,
`ffigen.yaml`. **The output is the stock Flutter template** — the `pubspec` has
a `flutter:` block + `plugin_platform_interface`, the podspec has
`s.dependency 'Flutter'`, Android is `ffiPlugin: true`, the manifest has a
`package=` attribute (an error on AGP 8), and there is no Kotlin and no JNI. Use
only the skeleton and hand-write pubspec / podspec / build.gradle. The example's
pub get fails (`dartnative_android` is not on pub.dev) but the plugin itself
generates fine.

On 2026-09-15 this package's `build.gradle` / podspec / CMakeLists / manifest
were compared directly against the generated output: AGP 8.11.1, compileSdk 36,
NDK 28.2.13676358, minSdk 24, Java 17, `../src/CMakeLists.txt` and 16k page
support all match. Every difference is deliberate (design.md §3-2).

### 14-3. Android is two Kotlin files

`DartNativeSharePlugin : FlutterPlugin` does only `System.loadLibrary` in
`onAttachedToEngine` (which triggers `JNI_OnLoad`). The worker `ShareBridge` is
called from JNI, so `@Keep` is mandatory. On the C++ side: `NewStringUTF` →
`CallStaticVoidMethod` → `DeleteLocalRef` → **never forget `ExceptionCheck` /
`ExceptionClear`**.

> Found during implementation: a failed `GetStaticMethodID` also leaves an
> exception pending, and **the process aborts on the next JNI call**
> (`JNI DETECTED ERROR ... called with pending exception`). A `FindMethod` helper
> that calls `ExceptionClear` after every method ID lookup was added
> (design.md §11).

### 14-4. ✅ Callbacks use `Pointer.fromFunction` + a dispatcher slot

This settled "`NativeCallable` or `Pointer.fromFunction`?". The tutorial's
principle: **never cache the callback address.** Create exactly one in Dart →
pass it once → store it in a slot → **re-read and check for non-zero
immediately before every fire** → the framework zeroes it before tearing down
the old isolate. On iOS the slot is an `UnsafeMutablePointer<Int64>` plus
`DispatchQueue.main.async`.

For Android the tutorial said to combine this with a **generation counter**:

> **⚠️ Overturned by implementation (2026-09-15).** The engine exports no symbol
> corresponding to `nativeIsolateGen()` — `DNRegisterAsyncDispatcherSlot` is not
> in the `.so`, and `DN_IsolateGen` disassembles to memory-freeing code, not a
> getter `[disasm]`. The mechanism that exists is
> **`DNViewRegistry.registerResetHook`** `[bytecode]` (§12-4): the hook is called
> just before the old isolate is destroyed, and the slot is zeroed there. The
> adopted form is design.md §5-2 / `.claude/skills/dartnative-plugin/SKILL.md` §4.

```kotlin
// ❌ For the record only. nativeIsolateGen does not exist and this does not compile.
@Volatile private var dispatcherGen: Long = 0L
fun setDispatcher(ptr: Long) { dispatcherPtr = ptr; dispatcherGen = nativeIsolateGen() }
// deliver: if (dispatcherGen != nativeIsolateGen()) return@post
```

The `token` (Int64) + `status` (Int32) + JSON (`Pointer<Utf8>`) signature was
adopted as-is.

### 14-5. ⚠️ Where the tutorial and the tooling disagree

| Item | Tutorial | Tooling / reality | Adopted |
|---|---|---|---|
| Android Gradle | `build.gradle.kts` | `plugin_build.dart:751` hard-codes `build.gradle`; the template agrees | **Groovy `build.gradle`** |
| Threading | Uses `DispatchQueue.main.async` / `Handler.post` | The pubspec says "no thread hopping" | §14-6 (both are true) |
| Location of `CMakeLists.txt` | Directly under `android/` | The template has `src/CMakeLists.txt`; `build.gradle.tmpl` points at `../src/CMakeLists.txt` | **`src/` (plugin root)** |

### 14-6. Threading model, supplementary

"`DispatchQueue.main.async` is unnecessary" applies only to synchronous Dart →
native calls. Wherever native does something asynchronous, and wherever a Dart
callback is fired, **always be on main**. Android Next-Gen fires every callback
in the background, so the hop is always required there (design.md §6).

### 14-7. Naming conventions (settled)

`dartnative_<name>` / `com.dartnative.<name>` / `DartNative<Name>Plugin` /
C symbols `DN<Name><Verb>` / pod name = package name / `lib<package>.so`. The
tutorial itself is named `dartnative_share`, so the text assumed third parties
may use `dartnative_*`. The relationship to `dn_first_party.json` (the
first-party allowlist) was unconfirmed at the time (design.md §12-3).

**Addendum, 2026-09**: third parties **may not** use the `dartnative_` prefix.
This package was renamed to `google_mobile_ads_kit` / `GoogleMobileAdsKitPlugin`
/ C symbols `GMAK<Verb>` / Swift types `GMAK*` / Android resources
`gmak_native_*` (see the table in design.md §3). Only the Android package
`com.cafelafe.google_mobile_ads_kit` was left as-is, to avoid touching the JNI
symbol names.

### 14-8. Development flow

`dn create .` (adds the iOS/Android shells to an existing directory) → `dn run`
→ `dn plugin build` (`dist/<name>-<version>.tar.gz`) → `dn plugin publish` /
`dn plugin sync` (re-pushes README + example).

### 14-9. What the tutorial still did not answer

The complete DartNative-specific contents of `CMakeLists.txt` / the podspec
(the template is for Flutter; whether `s.dependency 'Flutter'` should be removed
was unverified on macOS — design.md §12-6), and the iOS plugin provider
contract (`dartnative_share` has no view — design.md §12-1).
