---
name: dartnative-plugin
description: >
  Build a DartNative plugin — the parts the official dart-native skill does not cover:
  dart:ffi bindings, the dispatcher-slot callback pattern, @_cdecl Swift bridges, the
  Android C++/JNI bridge, NativeElement for embedding native views, ViewType.claim,
  PluginMutation, podspec/build.gradle constraints, and dn plugin build. Use when
  writing or debugging plugin code in this repository, wiring native SDKs, or adding
  a native-backed widget.
---

# DartNative プラグイン開発

> 公式の `dart-native` skill は**プラグインを使う側**の知識（ウィジェット API、
> Flutter 非互換点、`registerAll()` の作法）。この skill は**作る側**を扱う。
> 両方が必要な場面では併用すること。

## 前提: 何が存在しないか

DartNative には以下が**存在しない**。AI は高確率で Flutter のつもりで書くので注意。

| 使わない | 代わりに |
|---|---|
| `MethodChannel` / `EventChannel` | `dart:ffi`（C ABI・同期呼び出し） |
| `PlatformView` / `AndroidView` / `UiKitView` | `NativeElement` |
| `pigeon` などのコード生成 | typedef を手書き（同梱プラグイン全てがそう） |
| `NativeCallable` | `Pointer.fromFunction` + ディスパッチャスロット |

---

## 1. ディレクトリ構成

```
<plugin>/
├── lib/
│   ├── <plugin>.dart                  # library + export + 初期化エントリ
│   └── src/
│       └── <name>_ffi_bindings.dart   # typedef, loadSymbols, ディスパッチャ
├── ios/
│   ├── <plugin>.podspec
│   └── Classes/
│       └── DN<Name>Bridge.swift       # @_cdecl エクスポート
├── src/
│   ├── CMakeLists.txt                 # ★ プラグイン直下。ツール雛形と同じ配置
│   └── <name>_bridge.cpp              # JNI ブリッジ
├── android/
│   ├── build.gradle                   # ★ Groovy。.kts は不可。cmake path は ../src/CMakeLists.txt
│   └── src/main/
│       ├── AndroidManifest.xml        # package 属性は書かない（AGP 8 でエラー）
│       └── kotlin/com/dartnative/<name>/
│           ├── DartNative<Name>Plugin.kt   # 登録 + System.loadLibrary のみ
│           └── <Name>Bridge.kt             # 実処理（@Keep 必須）
├── example/                           # dn plugin sync の対象。実質必須
└── pubspec.yaml
```

スキャフォールド: `dn create --template=plugin_ffi --platforms=android,ios <name>`
ただし**生成物は Flutter 標準テンプレートのまま**なので、pubspec / podspec /
build.gradle を手で書き換える必要がある。既存ディレクトリには `dn create .`。

### 命名規約

| 対象 | 規約 |
|---|---|
| Dart パッケージ | `dartnative_<name>` |
| Android パッケージ | `com.dartnative.<name>` |
| Android プラグインクラス | `DartNative<Name>Plugin` |
| C シンボル | `DN<Name><Verb>`（例: `DNShareText`） |
| ネイティブライブラリ | `lib<package>.so` |

---

## 2. pubspec のマニフェスト

```yaml
dartnative:
  plugin:
    platforms:
      ios:
        ffiPlugin: true
      android:
        package: com.dartnative.<name>
        pluginClass: DartNative<Name>Plugin
  registrant:
    imports:
      - package:<plugin>/<plugin>.dart
    calls:
      - initialize<Name>Plugin();      # ★ 末尾の ; を含めること
```

### ⚠️ Android で `ffiPlugin: true` を使ってはいけない場合

**ネイティブ → Dart のコールバック（リバース JNI）があるなら `pluginClass` を宣言する。**

ffi のみの Android プラグインは `GeneratedPluginRegistrant` に追加されず、
`System.loadLibrary` を呼ぶ `onAttachedToEngine` が走らないため、
リバース JNI が `UnsatisfiedLinkError` で落ちる。
`dartnative_firebase` / `dartnative_video_player` の pubspec に同じ注意書きがある。

### キー仕様

- `registrant.imports` — bare な package URI（`import` や `;` は書かない）
- `registrant.calls` — 完全な Dart 文（**`;` を含める**。そのまま出力される）
- `flutter:` と `dartnative:` はマージされ、衝突時は `dartnative:` が勝つ

registrant は `dn pub get` のたびに再生成される。1 行目が
`// GENERATED FILE — DO NOT EDIT BY HAND.` の場合のみ上書きされる。

---

## 3. FFI バインディング

```dart
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

typedef _DNShareTextC = Void Function(Pointer<Utf8>);
typedef _DNShareTextDart = void Function(Pointer<Utf8>);

class ShareFFIBindings {
  static late final _DNShareTextDart _shareText;
  static bool _loaded = false;

  static void loadSymbols() {
    if (_loaded) return;
    // 対応外プラットフォームでは例外を投げず無反応にする
    if (!Platform.isIOS && !Platform.isAndroid) return;

    // iOS: 静的 xcframework でアプリバイナリにリンクされる → process()
    // Android: 独立した .so → open()
    final lib = Platform.isAndroid
        ? DynamicLibrary.open('libdartnative_share.so')
        : DynamicLibrary.process();

    _shareText = lib.lookupFunction<_DNShareTextC, _DNShareTextDart>('DNShareText');
    _loaded = true;
  }

  static void shareText(String text) {
    final ptr = text.toNativeUtf8();
    try {
      _shareText(ptr);
    } finally {
      calloc.free(ptr);   // ★ finally で必ず解放
    }
  }
}
```

構造化データは **JSON 文字列**（`Pointer<Utf8>`）でやり取りする。
同期的な文字列読み出しが要る場合は `Int32 Function(Int64, Pointer<Uint8>, Int32)`
（呼び出し側バッファ + 書き込み長を返す）。

---

## 4. ★ ネイティブ → Dart: ディスパッチャスロット（最重要）

**原則: ネイティブ側はコールバックアドレスをキャッシュしない。**

1. Dart 側でコールバックポインタを **1 つだけ**作る
2. アドレスをネイティブへ一度だけ渡す
3. ネイティブは「スロット」（可変ポインタ）に格納する
4. **発火の直前に毎回スロットを読み直し、非ゼロを確認する**
5. フレームワークが、古い isolate を破棄する前にスロットをゼロクリアする

これを守らないと、ホットリスタート後に死んだ isolate へ発火してクラッシュする。
**遅れて飛んでくるコールバック（ネットワーク完了、SDK イベント）では必須。**

### Dart

```dart
typedef _ResultDispatchC = Void Function(Int64, Int32, Pointer<Utf8>);
//                                       token   status  JSON

void _dispatchResult(int token, int status, Pointer<Utf8> raw) {
  Bindings._complete(token, status, raw == nullptr ? '' : raw.toDartString());
}

final _dispatchPtr = Pointer.fromFunction<_ResultDispatchC>(_dispatchResult);
// loadSymbols() 内で: _setDispatcher(_dispatchPtr.address);
```

### iOS

```swift
private let _dispatcherSlot: UnsafeMutablePointer<Int64> = {
  let p = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
  p.pointee = 0
  return p
}()

@_cdecl("DNShareSetDispatcher")
public func DNShareSetDispatcher(_ callbackPtr: Int64) {
  _dispatcherSlot.pointee = callbackPtr
  if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                     "DNRegisterAsyncDispatcherSlot") { /* register */ }
}

private func fireResult(token: Int64, status: Int32, raw: String) {
  DispatchQueue.main.async {
    let addr = _dispatcherSlot.pointee
    guard addr != 0 else { return }          // ← 毎回チェック
    raw.withCString {
      unsafeBitCast(addr, to: ResultDispatch.self)(token, status, $0)
    }
  }
}
```

### Android（リセットフックでスロットをゼロにする）

```kotlin
@Volatile private var dispatcherPtr: Long = 0L
private var resetHookInstalled = false

fun setDispatcher(ptr: Long) {
  dispatcherPtr = ptr
  if (!resetHookInstalled) {
    resetHookInstalled = true
    // 旧 isolate が破棄される「前」にエンジンが呼ぶ。ここでスロットを
    // ゼロにすれば、遅れて届いたイベントは死んだ isolate に飛ばず捨てられる。
    DNViewRegistry.registerResetHook { dispatcherPtr = 0L /* + 生きた SDK オブジェクトの解放 */ }
  }
}

internal fun deliver(token: Long, status: Int, raw: String) {
  Handler(Looper.getMainLooper()).post {
    val ptr = dispatcherPtr          // 発火直前に毎回読む。C++ 側にキャッシュしない
    if (ptr == 0L) return@post
    nativeDeliver(ptr, token, status, raw)
  }
}
```

> ⚠️ **「isolate 世代カウンタ」方式は使えない（2026-09-15 に実機で確認）。**
> 以前この節にあった `nativeIsolateGen()` に相当するシンボルを
> **エンジンはエクスポートしていない**（`DNRegisterAsyncDispatcherSlot` は無く、
> `DN_IsolateGen` は逆アセンブルするとメモリ解放コードで getter ではない）。
> エンジンが実際に提供している仕組みは `DNViewRegistry.registerResetHook` で、
> `.aar` のバイトコードで存在を確認済み。`doc/design.md` §5-2 参照。

---

## 5. ネイティブブリッジ

### iOS: `@_cdecl`（1 ホップ）

```swift
@_cdecl("DNShareText")
public func DNShareText(_ textPtr: UnsafePointer<CChar>?) {
  guard let textPtr = textPtr else { return }
  let text = String(cString: textPtr)
  DispatchQueue.main.async { presentShareSheet(items: [text]) }
}
```

### Android: C++ JNI → Kotlin（2 ホップ）

Dart は Kotlin を直接呼べないため C++ シムが要る。

```cpp
extern "C" __attribute__((visibility("default")))
void DNShareText(const char* text) {
  JNIEnv* env = getEnv();
  if (!env || !g_bridgeClass || !g_shareText) return;
  jstring jText = env->NewStringUTF(text ? text : "");
  env->CallStaticVoidMethod(g_bridgeClass, g_shareText, jText);
  env->DeleteLocalRef(jText);                      // ← ローカル参照を解放
  if (env->ExceptionCheck()) env->ExceptionClear(); // ← 例外をクリア
}
```

Kotlin は 2 ファイルに分ける。

```kotlin
// DartNativeSharePlugin.kt — 登録とライブラリロードのみ
class DartNativeSharePlugin : FlutterPlugin {
  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    System.loadLibrary("dartnative_share")   // JNI_OnLoad を発火させる
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
```

> **なぜ DartNative なのに `FlutterPlugin` なのか**（よくある疑問）
>
> DartNative は Android の登録機構だけ Flutter ツールのものを流用している。
> 生成される `io.flutter.plugins.GeneratedPluginRegistrant` が
> `flutterEngine.getPlugins().add(new DartNative<Name>Plugin())` を呼び、
> この `add()` が `FlutterPlugin` 型を要求するため。
> DartNative 自身の一次プラグイン `com.dartnative.DartNativeAndroidPlugin` も
> 同じインターフェースを実装している（AAR のクラスファイルで確認済み）。
>
> **登録フックとしてのみ使う。** メソッドチャネルは介在せず、Flutter の描画も
> 使わない。Dart との通信は全て FFI。
>
> ネイティブビューは別契約: `DNAndroidPluginProvider`
> （`createView(Int)` / `handleMutation(Long, Int, ByteArray)`）を実装する。
> こちらは `io.flutter.*` とは無関係。

```kotlin
// ShareBridge.kt — 実処理。JNI から呼ぶので @Keep 必須
@Keep
fun shareText(text: String?) { /* ... */ }
```

Activity が要る場合は `DNNavigator.activity(): Activity` で取得する。

---

## 6. スレッドモデル

**Dart はプラットフォームのメインスレッド上で動く。ラスタスレッドは存在しない。**

| 方向 | ルール |
|---|---|
| Dart → ネイティブ（同期） | UIKit / Android View API を直接呼んでよい。ホップ不要 |
| ネイティブ内で非同期を挟む | メインへ戻す（`DispatchQueue.main.async` / `Handler(Looper.getMainLooper()).post`） |
| ネイティブ → Dart 発火 | **必ずメインスレッドから。** `Pointer.fromFunction` は所有 isolate のスレッドを要求する |
| SDK のコールバックがバックグラウンドで来る場合 | 上と同じ。**この repo の Android（GMA Next-Gen SDK）は全コールバックがバックグラウンド**なので、Kotlin のリスナー内で `Handler(Looper.getMainLooper()).post { deliverResult(...) }` と包んでから JNI を呼ぶ。SDK から直接 JNI を呼んではいけない |
| SDK がバックグラウンドでの呼び出しを要求する場合 | Dart（メイン）から来た同期呼び出しを Kotlin 側で `Executors` に投げ、結果をメインへ戻して Dart に通知する。GMA Next-Gen の `MobileAds.initialize` がこれ（メインで呼ぶと ANR） |

Dart のタイマーはバックグラウンドで止まらない。周期処理は
`WidgetsBinding.instance.isForeground` でゲートすること。

---

## 7. ネイティブビューを埋め込む（`NativeElement`）

### 7-1. ビュー種別を確保する

```dart
abstract final class MyViewType {
  // static const ではなく static final（初回アクセス時に解決される）
  static final int myView = ViewType.claim('my_plugin/view');
}
```

`claim()` は 65535 から降順に採番（下限 60000）。キーに対して冪等。
組み込みは 0-99 で予約されている。

### 7-2. 4 メソッド契約

```dart
class MyElement extends NativeElement {
  @override int get viewType => MyViewType.myView;
  @override ViewProps buildProps() => const FlexProps(...);
  @override void mount(Element? parent, UIKitReconciler rec) {
    super.mount(parent, rec);          // ← ネイティブビューが生成される
    emitMutation(SetFlexAspectRatio(viewId!, w / h));
    _emitConfigure();
  }
  @override void update(Widget newWidget) { /* 差分があれば再 emit */ }
}

void registerMyElementFactory() {
  DartNativeReconciler.registerElementFactory<MyView>((w) => MyElement(w));
}
```

**2 層構成が慣習:** 公開 `StatefulWidget` → 内部リーフ `Widget` →
`NativeElement`。`registerElementFactory` にはリーフのみ渡す。

**Android 側のプロバイダは、自分の種別でなければ `null` を返すこと:**

```kotlin
override fun createView(typeIndex: Int): View? {
  if (typeIndex != myViewType) return null   // ← 空の FrameLayout を返してはいけない
  return takePendingContainer()
}
```

> ⚠️ `DNPluginRegistry.createView` は登録順にプロバイダを走査し、
> **最初に non-null を返したものを採用して打ち切る**（`.aar` 逆アセンブルで確認。
> インターフェースも `@Nullable`）。プレースホルダを返すと、後から登録された
> 他プラグインの（あるいは自分の 2 つ目の）ビュー種別をすべて横取りする。
> **ビュー種別が 1 つのうちは症状が出ない**ので、2 つ目を足したときに
> 「ロードは成功するのに画面が空白」で初めて発覚する。`doc/design.md` §5-1。

### 7-3. 設定の送出: `PluginMutation`

```dart
emitMutation(PluginMutation(viewId!, _Tag.configure, bytes));
```

`eventTag` はプラグイン private な opcode（2 から始めるのが慣習）。

> ⚠️ `handleMutation` は**登録済みの全プロバイダにブロードキャストされる。**
> タグ衝突の回避は自分の責任。`viewId` で自分のビューか判定すること。
> 大きなデータは載せない（画像等は URL / ファイル経由）。

### 7-4. できないこと

- **Dart ウィジェットを自分のネイティブビューの子にできない。**
  プラグインに公開されているのは `createView` と `handleMutation` の 2 つだけで、
  子マウント API が無い。SDK がコンテナを所有する型の API では、
  レイアウトをネイティブ側で書くことになる
- **intrinsic size を Yoga に報告できない。**
  `attachIntrinsicMeasure` はプラグインのビューには適用されない。
  サイズが事前に分かるなら `SetFlexAspectRatio` を使う
- **`SizedBox` で囲んでもネイティブビューのサイズにはならない。**
  `SizedBox` が確保するのは Dart 側のボックスだけで、中のネイティブビューは
  0x0 のまま描画されない（ロードは成功し、ログには loaded と出る）。
  プラグインが emit できるサイズ系ミューテーションは `SetFlexAspectRatio` のみ
  （`SetFlexHeight` / `SetFlexWidth` は `plugin.dart` から非公開）。
  高さしか分からない場合は `LayoutBuilder` で幅を取り、比率にして渡す。
  `doc/design.md` §8-7

### 7-5. ⚠️ リサイクルされるリスト内での注意

`FastList` / `FastGrid` は RecyclerView / UITableView ベースの本物のリサイクルを
行う。セルが画面外に出て戻ると `NativeElement` が unmount → remount され、
**`createView` が再度呼ばれる。**

コストの高いリソース（広告、動画プレイヤー、SDK オブジェクト）を持つ場合:
- ネイティブ側でスロット番号をキーにキャッシュし、`createView` はキャッシュを返す
- `unmount` で破棄しない。明示的な dispose 時のみ
- `keepAliveCount` は設定しない（設定するとコンテンツが破棄される）

---

## 8. ネイティブ依存の宣言

### iOS: podspec

```ruby
s.platform     = :ios, '13.0'
s.source_files = 'Classes/**/*'
s.dependency 'SomeSDK', '~> 1.0'
```

ソースは `ios/Classes/` に置く（`.swift .m .mm .c .cc .cpp`）。
`s.dependency` を宣言すると pods ビルド経路になり、**`dn plugin build` に
macOS + Xcode が必要**になる。

### Android: `android/build.gradle`

**Groovy で書く。`.kts` は不可**（ツールが `build.gradle` 決め打ちで探し、
無ければ Android 成果物をスキップして `null` を返す）。

```gradle
dependencies {
    implementation 'com.example:sdk:1.2.3'    // ★ バージョンを明示ピン
}
```

1. **バージョン必須**（AAR に POM が無く解決できない）
2. **ファイルを跨ぐ変数は不可**（`$rootProject.ext.v` は即エラー）
3. BOM は可（`implementation platform('g:a:v')`）

---

## 9. ビルドと公開

```bash
dn pub get           # 依存解決 + registrant 再生成
cd example && dn run # 動作確認（r=ホットリロード, R=リスタート, q=終了）
dn plugin build      # dist/<name>-<version>.tar.gz
dn plugin publish    # dartpub.dev へ公開
dn plugin sync       # README + example ドキュメントの再push
```

---

## 10. 詰まったときの調べ方

公式 docs にプラグイン開発の章が無いため、**インストール済み SDK のソースが
事実上の仕様書**になる。

SDK の場所は `dirname $(dirname $(which dn))`（`dn` が PATH に無ければ
インストーラの既定は `~/zero`）。以下は**その配下の相対パス**。

| 知りたいこと | 見る場所（SDK ルートからの相対） |
|---|---|
| パッケージング仕様（podspec/gradle の制約） | `packages/flutter_tools/lib/src/commands/plugin_build.dart` |
| registrant 生成ロジック | `packages/flutter_tools/lib/src/flutter_plugins.dart` |
| `dartnative:` ブロックのパース | `packages/flutter_tools/lib/src/flutter_manifest.dart` |
| `ffiPlugin` / `pluginClass` の意味論 | `packages/flutter_tools/lib/src/platform_plugins.dart` |
| プラグイン向け公開 API（スタブでない） | `bin/cache/pkg/dartnative/lib/plugin.dart` |
| `ViewType` / `PluginMutation` の定義 | `bin/cache/pkg/dartnative/lib/src/reconciler/mutations.dart` |
| `NativeElement` の契約 | `bin/cache/pkg/dartnative/lib/src/reconciler/element.dart` |
| 実プラグインの pubspec 例 | `bin/cache/pkg/dartnative_*/pubspec.yaml` |
| podspec / CMakeLists の雛形 | `packages/flutter_tools/templates/plugin_ffi/` |

> 同梱プラグインの `lib/**.dart` は**全メソッドが `throw UnimplementedError()` の
> スタブ**。実装は `.dill` にコンパイル済み。読めるのは pubspec と typedef だけ。
> `strings -n 4 <pkg>/dart/debug/<pkg>.dill` で文字列テーブルを覗くと
> 呼び出し順序の手がかりが残っている。
