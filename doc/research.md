# 調査記録 — DartNative プラグイン開発の技術的前提

> **この文書は「調査の記録」であり、設計判断は [`design.md`](design.md) にある。**
> 設計書の根拠を確かめたいとき、または DartNative の内部仕様を調べ直す前に読む。
> 同じ調査を繰り返さないために残している。
>
> 出典は `[dart-src]`（SDK 同梱 Dart ソース）/ `[bytecode]`（AAR を `javap`）/
> `[disasm]`（`.so` を `llvm-objdump`）/ `[tutorial]`（公式チュートリアル）/ `[推測]` で明示。
>
> **⚠️ 実装後（2026-09-15）に覆った箇所がある。** 本書は調査「時点」の記録として残し、
> 実装で判明した事実と食い違う場合は **`design.md` の各節が正**。覆った箇所には
> 「実装で覆った」注記を付けている（§14-4 など）。設計時の素案（旧 §3〜§10）は
> `design.md` に確定版があるため、本書では根拠となる証拠だけを残して圧縮した。
> リポジトリのみに置き、配布物には含めない（`.pubignore`）。

- 調査日: 2026-09-15 ／ 対象: DartNative 3.45.0-0.1.pre / Dart 3.12.0-192.0.dev
- `<SDK>` はインストール済み DartNative SDK のルート（`dirname $(dirname $(which dn))`、既定 `~/zero`）

## 結論サマリ（AdMob 6 フォーマットの実現可否 → 実装結果）

| フォーマット | 調査時の評価 | 結果（Android） |
|---|---|---|
| Interstitial / Rewarded / Rewarded Interstitial / App Open | 🟢 容易。ビュー不要 | ✅ |
| Banner（固定 / アダプティブ） | 🟢 / 🟡 intrinsic size は報告不可だが高さは事前に求まる | ✅ |
| Banner in `FastList` | 🟠 リサイクルで再リクエスト | ⚠️ 遅延破棄で緩和。README で非推奨案内 |
| Native Ads（テンプレート / カスタム） | 🟡 ネイティブでレイアウトを書く（Flutter 版と同じ） | ✅ validator 合格 |

---

## 0. 最初に読む人へ：DartNative は Flutter ではない

DartNative は 2026 年登場で LLM の学習データにほぼ無い。AI は高確率で「Flutter のつもりで」
**存在しない API を自信を持って提案する**。

| | Flutter | DartNative |
|---|---|---|
| ネイティブビュー | PlatformView（合成） | **ネイティブビューを直接ツリーに挿入** |
| Dart ↔ ネイティブ | MethodChannel（非同期） | **dart:ffi 直呼び（同期）** |
| レイアウト / スレッド | 独自エンジン / UI・ラスタ別スレッド | **Yoga** / **Dart がメインスレッドで動く。ラスタ無し** |

存在しないもの: `MethodChannel` 系、`PlatformView` / `AndroidView` / `UiKitView`、
`google_mobile_ads` の内部実装（`AdWidget` 等）、`PlatformDispatcher` 前提コード。
やってはいけないこと: `android/build.gradle` を `.kts` で書く（§5）、Android の pubspec で
`ffiPlugin: true`（§4）、ネイティブで非同期を挟んだ後にメインへ戻さず Dart を呼ぶ（§6）。

`google_mobile_ads` は **公開 API と Native Ads のレイアウト方式は踏襲、内部実装は流用不能**
（§13）。バナーは DartNative の方が素直 — PlatformView の合成コストと描画不具合が存在しない。

---

## 1. 参考にできるネイティブソースは存在しない

SDK 同梱の一次プラグイン 37 個に**ネイティブソースは 1 行も無い**（`<SDK>/` 全体で
`*.podspec` ゼロ、`*.swift` はアプリ雛形のみ、`*.kt` は Gradle プラグインのみ）。構造は
`lib/**.dart`（全メソッド `throw UnimplementedError()`）+ `dart/*/*.dill`（コンパイル済み）+
`pubspec.yaml` + `manifest.json`。**読めるのは pubspec と Dart のシグネチャだけ。**
実ソースは非公開 `github.com/DartNative/dartnative_plugins`。

裏技: `strings -n 4 <pkg>/dart/debug/<pkg>.dill` で文字列テーブルから呼び出し順とリテラルが拾える。

---

## 2. 一次資料リスト

| 資料 | 重要度 | 内容 |
|---|---|---|
| https://dartnative.com/tutorials/build-a-plugin/ | ★★★ | プラグイン構造・FFI・Swift/Kotlin ブリッジを扱う唯一の公式資料。§14 に確定情報 |
| https://dartnative.com/tutorials/google-maps/ | ★★★ | ネイティブビュー埋め込み + ネイティブ側 API キー。バナーと同型 |
| https://dartnative.com/tutorials/publish-your-plugin/ | ★★ | dartpub.dev 公開手順 |
| `<SDK>/packages/flutter_tools/lib/src/commands/plugin_build.dart` | ★★★ | パッケージング仕様（2000 行超）。podspec / build.gradle の制約はここが正 |
| `<SDK>/packages/flutter_tools/lib/src/flutter_plugins.dart` (L494-760) | ★★★ | registrant 生成 |
| `<SDK>/bin/cache/pkg/dartnative/lib/plugin.dart` | ★★★ | **スタブでない唯一の API 定義**。プラグイン作者向け export 一覧 |
| `…/dartnative/lib/src/reconciler/{mutations,element}.dart` | ★★★ | `ViewType` / `ViewProps` / `PluginMutation` / `NativeElement` の定義 |
| `<SDK>/packages/flutter_tools/templates/plugin_ffi/` | ★★★ | 実在する唯一の podspec / CMakeLists / build.gradle 雛形（`dn create --template plugin_ffi`） |
| `dartnative_android.aar` / `libdartnative_android.so` | ★★★ | プロバイダ契約・レジストリ挙動はこれを逆アセンブルして確認（§12） |

参考にした同梱プラグインの pubspec / typedef: `dartnative_firebase`（`pluginClass` 必須の理由）、
`dartnative_revenuecat`（int64 トークン + JSON ディスパッチャ）、`dartnative_webview`
（`NativeElement` 最小例）、`dartnative_google_maps`（2 層構成 + API キー）、
`dartnative_video_player`（`SetFlexAspectRatio` の正規用法）。

---

## 3. コールバック方式の候補（確定版は design.md §5-2）

同梱プラグインの方式は 2 つ `[dart-src]`: **A. 関数ポインタ登録**（`dartnative_firebase`）と
**B. int64 トークン + 単一ディスパッチャ + JSON**（`dartnative_revenuecat`）。AdMob は B
（`onAdFailedToLoad` のエラー詳細を運べる）。同梱プラグインは `NativeCallable` を
**使っていない**（grep ゼロ件）。`DnCallbacks.arm()` も存在するが、公式チュートリアルが
`Pointer.fromFunction` + ディスパッチャスロットを示したので採用（§14-4）。

`plugin.dart` が export するレイアウト mutation は `SetAlignSelf` / `SetFlexAspectRatio` /
`SetFlexPositionType` / `SetFlexPositionInsets` **のみ**。`mutations.dart` に実在する
`SetFlexWidth` / `SetFlexHeight` / `SetViewHidden` は非公開 `[dart-src]`
— ネイティブ広告の高さ指定で効いた制約（design.md §8-6）。

---

## 4. `ffiPlugin` ではなく `pluginClass`（確定版は design.md §4）

`dartnative_firebase/pubspec.yaml` の原文 `[dart-src]`:

> NOT ffiPlugin: an ffi-only Android plugin is never added to GeneratedPluginRegistrant,
> so DartNativeFirebasePlugin.onAttachedToEngine (which System.loadLibrary's
> libdartnative_firebase.so) never runs and FCM's reverse-JNI nativeOnTokenRefresh
> crashes with UnsatisfiedLinkError.

広告イベントはまさにリバース JNI。マニフェストのキー仕様: `registrant.imports` は bare な
package URI、`registrant.calls` は `;` を含む完全な Dart 文、`flutter:` と `dartnative:` は
マージされ衝突時は `dartnative:` が勝つ。registrant は `dn pub get` のたびに再生成
（1 行目が `// GENERATED FILE — DO NOT EDIT BY HAND.` のときのみ上書き）。

---

## 5. ネイティブ依存の制約（確定版は design.md §9）

- **`build.gradle` は Groovy 限定**: `plugin_build.dart:751` が `androidDir.childFile('build.gradle')`
  決め打ちで、無ければ Android 成果物を**スキップして null**。依存抽出の正規表現（:800-843）も
  Groovy 前提。`dn create --template=plugin_ffi` の生成物も Groovy（§14-2）。
  チュートリアル図の `build.gradle.kts` は表記ミス（§14-5）。
- **Maven 座標**: バージョン無しは警告付きスキップ（`.aar` に POM が無い）、ファイルを跨ぐ
  Gradle 変数は `throwToolExit`、BOM は可。
- **podspec**: ソースは `ios/Classes/`（`.swift .m .mm .c .cc .cpp`）。`s.dependency` を
  宣言すると "pods" 経路（CocoaPods + `xcodebuild`）になり、`import GoogleMobileAds` は
  いずれにせよこの経路。consumer podspec には `DEAD_CODE_STRIPPING = NO` が付く
  （`_PodspecInfo.read` :1723-1768）。
- **AdMob App ID** はマニフェストマージが無いので利用者が手で設定（`dartnative_google_maps`
  の API キーと同じ扱い）。

---

## 6. スレッドモデルの根拠（確定版は design.md §6）

原文 `[dart-src]`: `dartnative_ios/pubspec.yaml` "Dart runs on the iOS platform (main) thread,
making all UIKit calls synchronous with no thread hopping" ／ `dartnative/lib/src/core.dart:630-632`
"rendering is synchronous on the main thread — there is no separate raster thread"。

ただしチュートリアルの実コードは `DispatchQueue.main.async` / `Handler(...).post` を使う
（§14-6）: 同期呼び出しでは不要、**ネイティブで非同期を挟んだら Dart 発火前に必ずメインへ戻す**。
調査当初「Android の AdMob リスナーはメインで発火する」と書いたのは Legacy SDK の話で
**誤り** — Next-Gen は全コールバックがバックグラウンド。

Dart のタイマーはバックグラウンドで止まらない（`core.dart:661-667`）。

---

## 7〜10. 設計素案（→ design.md へ統合済み）

調査時のディレクトリ構成案・実装順序・障壁一覧・未確認事項は `design.md` §3-2 / §10 / §11 / §12
に確定版がある。調査時に立てて**解消した**問いだけ記す:

- `dn plugin build` の入力構造 → チュートリアル + スキャフォールドで確定（§14）
- コールバック方式 → `Pointer.fromFunction` + スロット（§14-4）
- `google_mobile_ads` からの流用とライセンス → MIT で可（§13-3）
- iOS 側のプロバイダ契約・`ViewType` 採番・`dartnative_*` 命名・公開のライセンス要件 →
  **未解決のまま design.md §12 に引き継ぎ**

---

## 11. 開発環境と AI 支援

- DartNative SDK（`dn --version`）、Android SDK 36、iOS は **macOS + Xcode 必須**。
  無料 Community プランで自作プラグインは開発できる（起動ログ `Launch check ok — tier=free`）。
  ただしトライアル token の `apps` 許可リストは公式サンプルのみなので、自作アプリでは
  `dn config --license-key=...` が要る（画面に `No DartNative license found.` が出る）。
- `dn doctor` / `dn emulators --launch <id>` / `dn run`（r = reload, R = restart）/ `dn plugin build`。
- 公式 skill `dartnative/dartnative@dart-native`・`@dart-native-porting` は**使う側**の知識で、
  プラグイン開発（`NativeElement` / `@_cdecl` / JNI / `ViewType` / podspec）は記載ゼロ。
  その空白を `.claude/skills/dartnative-plugin` が埋め、利用者向けには
  `skills/dartnative-mobile-ads-usage` を配布する。`dart-use-ffigen`（手書き FFI 非推奨の立場）
  と Flutter 系 skill は方針が衝突するので入れない。
- AI に実装させるときは**禁止事項を仕様の冒頭に置く**（§0）。DartNative は学習データに無いため
  肯定形より「存在しない」という否定形が効く。検証ループ（`dn run` 実機）を最初に確立する。

---

## 12. フォーマット別の実現可否（詳細と根拠）

Android AAR の `javap` と `libdartnative_android.so` の `llvm-objdump` で確認。
**iOS 側は未検証**（読める framework が無い。design.md §12-1）。

### 12-1. 🟡 Native Ads — ネイティブでレイアウトを書く（Flutter 版と同じ）

> 初版は「🔴 ブロック」と評価していたが**誤り**。Dart ウィジェットを広告ビューの子にできないのは
> AdMob SDK 側の要求で、Flutter 公式も "your app — rather than Google Mobile Ads Flutter
> Plugin — is then responsible for displaying them" と明記し、XML / xib + `NativeAdFactory` を採る。

技術的事実（正しい）`[bytecode]`: プラグインがネイティブ側に持つ interface は 2 メソッドのみ。

```java
public interface com.dartnative.DNAndroidPluginProvider {
  @Nullable View createView(int);          // null = 自分の種別ではない
  void handleMutation(long, int, byte[]);
}
```

子ビューを差し込む API が無いことの 3 つの確認: (1) 上記 interface に `insertChild` 相当が無い、
(2) `NativeElement`（`element.dart:127-148`）に `children` / `replaceChild` のオーバーライドが無く
`plugin.dart` は子要素機構を公開していない `[dart-src]`、(3) 組み込みコンテナが使う
`_emitFlexChild()`（`native_elements.dart:21`）は file-private、ネイティブの
`DNFlexLayout.insertChild` もリコンサイラ内部専用 `[bytecode]`。

→ 制約が効くのは **Dart → ネイティブ方向だけ**。`NativeAdView` は `FrameLayout` なので
ネイティブ側で子を組むのは自由。Flutter 版の 2 方式（テンプレート / ファクトリ）をそのまま提供する
（design.md §8）。❌ Dart レイアウト + 透明 `NativeAdView` の重ね合わせは素材の被覆となり
ポリシー違反。

**実装で判明（design.md §5-1）:** `DNPluginRegistry.createView(int)` は登録順に走査して
**最初の non-null で打ち切る** `[bytecode]`。プレースホルダを返すと後続のプロバイダが
呼ばれない。

### 12-2. 🟢 全画面フォーマット

ビューを扱わないので `createView` も `ViewType.claim()` も不要。SDK が `show(activity)` で
自前表示。`Activity` は `DNNavigator.activity()` `[bytecode]`。App Open のライフサイクル検知には
`registerAppLifecycleCallback`（`uikit_bindings.dart:162`）`[dart-src]` が使える（未実装）。
DartNative 自身の全画面 API（`presentDartSheet` 等）は AdMob では使わない。

### 12-3. 🟡 Banner（アダプティブ）— intrinsic size は報告できないが回避可能

`DNViewFactory.register(View)` `[bytecode]`:

```
27: instanceof    android/view/ViewGroup
30: ifne          38                     ← ViewGroup ならスキップ
35: invokestatic  DNFlexLayout.attachIntrinsicMeasure:(JLandroid/view/View;)V
```

`attachIntrinsicMeasure` は非 `ViewGroup` にしか、しかもプラグイン経路では**そもそも**呼ばれない。
再レイアウトを要求する mutation も公開されていない（§3）。`Element.markDirty()` は Dart 要素の
再ビルド用。

回避: 広告の高さは**事前に解析的に求まる**。`LayoutBuilder`（`builders.dart:26-31`）で幅を取り、
ネイティブの `getLargeAnchoredAdaptiveBannerAdSize(ctx, widthDp)` で高さを得て
`SetFlexAspectRatio(w/h)` を mount 時に emit。`dartnative_video_player` が採る正規の手法
（`video_player.dart:126-128`）。`stretchAsStackFlowChild => true` と併用。

### 12-4. 🟠 リスト内バナー — リサイクルによる再リクエスト

`FastList` / `FastGrid` / `MasonryFastGrid` は `DNFastListBridge$DNFastListAdapter extends
RecyclerView$Adapter`（`onCreateViewHolder` / `onBindViewHolder` / `onViewRecycled`）による
**本物のリサイクル** `[bytecode]`。セル `DNCellContainer extends FrameLayout` が
`clearChildren()` / `swapView()` でビューを着脱する。`keepAliveCount`（`fast_list.dart:238-257`）
を設定すると可視範囲外の行のコンテンツが**破棄される**（原文 "has its built content disposed"）。

ホットリスタート時の後始末に使えるフック: `DNViewRegistry.registerResetHook(Function0<Unit>)`
`[bytecode]` — これが design.md §5-2 の採用根拠。

対策の確定版は design.md §7-4（遅延破棄 + 世代チェック、`keepAliveCount` 非設定、非リサイクル
コンテナ推奨）。

### 12-5. 画像素材の受け渡し

ネイティブ画像ハンドル（`Drawable` / `UIImage`）を Dart に渡す API は無い `[dart-src][bytecode]`
（`ImageProvider` は Network / Asset / File / Memory の 4 種のみ）。ネイティブ広告は
テンプレート / ファクトリともネイティブ側で描画するので**この経路は不要になった**。
参考: Coil / NSCache の共有キャッシュ、`ImageCache.configure`（`image.dart:203-273`）。

### 12-6. ViewType レジストリの実際の挙動 `[disasm]`

`DNViewTypeClaim`（`0xae2ec0`）: **65535 から降順**、下限 60000（`mov w10, #0xea5f`）、
プロセスグローバル・`std::mutex`・**キーに対して冪等**・解放されない。空文字は `-1`。
`DNViewFactory.create(int)` は **100 未満を組み込み** `tableswitch`、100 以上を
`DNPluginRegistry.createView` へ `[bytecode]`。組み込み 31 種のうち Dart の `ViewType`
定数として公開されるのは `view / label / button / floatingActionButton / shimmer / searchBar`
の 6 つ（`DNImageView`(6) はプラグインから名指しできない）。

### 12-7. `PluginMutation` の注意点

`DNPluginRegistry.handleMutation(long, int, byte[])` は**全プロバイダにブロードキャスト**
`[bytecode]` → `eventTag` は衝突しうる。ペイロード上限は明示的に無い（バッチデコーダに境界
チェックのみ、オフセット 32bit `[推測]`）。大きなデータは URL / ファイル経由。

### 12-8. SDK ベンダーへの要望候補（優先度低）

「Native Ads が実装できない」根拠は取り下げ（Flutter もネイティブで書く）。あれば嬉しい程度:
プラグインビューへの子マウント API、プラグインビューへの `attachIntrinsicMeasure` 適用
（汎用の `View.measure()` 経路は `attachIntrinsicMeasure$lambda$4+308` に実装済みで、分岐で
呼ばれていないだけ）。それより**情報開示**（`dartnative_plugins` へのアクセス、iOS 側の
プラグイン契約、`dartnative_*` 命名の可否、公開のライセンス要件）を先に依頼すべき。

### 12-9. 「変換」についての結論

コード生成（`pigeon` 相当）は不要。同梱プラグインは全て typedef 手書き。実際に要るのは
2 箇所のマーシャリング — Dart → ネイティブは JSON 文字列（本プラグインでは `PluginMutation`
の生バイト列すら使わなかった）、ネイティブ → Dart は int64 トークン + JSON。同期の文字列
読み出しは webview 方式（呼び出し側バッファ + 書き込み長）。

---

## 13. Flutter 互換方針（公開 API 設計の指針）

### 13-1. エコシステムの明示的な作法 `[dart-src]`

| プラグイン | 原文 |
|---|---|
| `dartnative_revenuecat` | "**Drop-in replacement for** RevenueCat's `purchases_flutter`" / "Derived from purchases_flutter by RevenueCat, Inc. (MIT)" |
| `dartnative_firebase` | "API surface mirrors the original where possible so that migration diffs are [minimal]" |
| `dartnative_shared_preferences` / `url_launcher` / `path_provider` / `permissions` | いずれも "**Drop-in** replacement" を公言 |

→ `dartnative_mobile_ads` も `google_mobile_ads` の公開 API を踏襲する。

### 13-2. 層ごとの方針

クラス名・メソッド名・引数名・enum・リスナー・ファクトリ登録フロー・エラー構造 = ✅ 合わせる。
内部実装 = ❌ 流用不能。

### 13-3. ライセンス: MIT で問題ない

`google_mobile_ads` は Apache-2.0 だが、Dart 実装は `instanceManager`（MethodChannel）に
依存し `load()` 以下が全て別実装、表示側の `AdWidget` も存在しない。一致するのは
「書き方が 1 通りしかない」フィールド宣言と、AdMob 公式ドキュメントにある定数値だけ
→ **まとまったコードを転記する場面が発生しない**。`LICENSE` は MIT 一本、`NOTICE` 不要。
参照先は AdMob 公式ドキュメント（定数・エラーコード）と pub.dev の API リファレンス
（メソッド名・引数の並び）。上流のソースファイルをまとめてペーストすることだけ避ける。
pubspec の `description` は "API surface follows google_mobile_ads"（"Based on" ではない）。
ネイティブ広告テンプレート（上流同梱の Apache-2.0 資産）も同じ理由で書き起こした
（design.md §8-4）。

---

## 14. 公式チュートリアルからの確定情報 `[tutorial]`

出典: https://dartnative.com/tutorials/build-a-plugin/（`dartnative_share`）と
`dn create --template=plugin_ffi` の実行結果。

### 14-1. ディレクトリ構造

チュートリアル: `lib/` `ios/Classes/DNShareBridge.swift` `android/src/main/kotlin/…/{DartNativeSharePlugin,ShareBridge}.kt`
`android/src/main/cpp/share_bridge.cpp` `android/CMakeLists.txt` `android/build.gradle`。
Kotlin は「プラグインクラス」と「実処理クラス」の 2 ファイル。`CMakeLists.txt` の位置は
ツール雛形の `src/CMakeLists.txt` を採用（§14-5）。

### 14-2. スキャフォールド `dn create --template=plugin_ffi --platforms=android,ios <name>`

生成: `lib/<name>.dart`, `lib/<name>_bindings_generated.dart`, `ios/Classes/<name>.c`,
`ios/<name>.podspec`, `android/build.gradle`, `android/src/main/AndroidManifest.xml`,
`src/CMakeLists.txt`, `src/<name>.{c,h}`, `ffigen.yaml`。**生成物は Flutter 標準テンプレートのまま**
— `pubspec` が `flutter:` ブロック + `plugin_platform_interface`、podspec に `s.dependency 'Flutter'`、
Android が `ffiPlugin: true`、manifest に `package=` 属性（AGP 8 でエラー）、Kotlin も JNI も無し。
骨組みだけ使い、pubspec / podspec / build.gradle は手で書く。example の pub get は失敗する
（`dartnative_android` が pub.dev に無い）がプラグイン本体の生成は成功する。

2026-09-15 に本パッケージの `build.gradle` / podspec / CMakeLists / マニフェストを生成物と
直接比較: AGP 8.11.1・compileSdk 36・NDK 28.2.13676358・minSdk 24・Java 17・
`../src/CMakeLists.txt`・16k page 対応が一致。差分は全て意図的（design.md §3-2）。

### 14-3. Android は Kotlin 2 ファイル構成

`DartNativeSharePlugin : FlutterPlugin` は `onAttachedToEngine` で `System.loadLibrary` のみ
（`JNI_OnLoad` を発火させる）。実処理 `ShareBridge` は JNI から呼ぶので `@Keep` 必須。
C++ 側は `NewStringUTF` → `CallStaticVoidMethod` → `DeleteLocalRef` →
**`ExceptionCheck` / `ExceptionClear` を忘れない**。

> 実装で判明: `GetStaticMethodID` 失敗も例外を pending にし、**次の JNI 呼び出しでプロセスが
> abort する**（`JNI DETECTED ERROR ... called with pending exception`）。メソッド ID 解決ごとに
> `ExceptionClear` する `FindMethod` を置いた（design.md §11）。

### 14-4. ✅ コールバックは `Pointer.fromFunction` + ディスパッチャスロット方式

「`NativeCallable` か `Pointer.fromFunction` か」に決着。チュートリアルの原則:
**コールバックアドレスをキャッシュしない。** Dart で 1 つだけ作る → 一度だけ渡す →
スロットに格納 → **発火直前に毎回読み直して非ゼロ確認** → フレームワークが旧 isolate 破棄前に
ゼロクリア。iOS 側は `UnsafeMutablePointer<Int64>` のスロット + `DispatchQueue.main.async`。

Android 側についてチュートリアルは**世代カウンタ**を併用するとしていた:

> **⚠️ 実装で覆った（2026-09-15）。** エンジンは `nativeIsolateGen()` に相当するシンボルを
> エクスポートしていない — `DNRegisterAsyncDispatcherSlot` は `.so` に無く、`DN_IsolateGen`
> は逆アセンブルするとメモリ解放コードでゲッターではない `[disasm]`。実在する仕組みは
> **`DNViewRegistry.registerResetHook`** `[bytecode]`（§12-4）で、旧 isolate 破棄の直前に
> フックが呼ばれるのでそこでスロットをゼロにする。採用形は design.md §5-2 /
> `.claude/skills/dartnative-plugin/SKILL.md` §4。

```kotlin
// ❌ 記録のみ。nativeIsolateGen は存在せずコンパイルできない。
@Volatile private var dispatcherGen: Long = 0L
fun setDispatcher(ptr: Long) { dispatcherPtr = ptr; dispatcherGen = nativeIsolateGen() }
// deliver: if (dispatcherGen != nativeIsolateGen()) return@post
```

`token`(Int64) + `status`(Int32) + JSON(`Pointer<Utf8>`) のシグネチャはそのまま採用した。

### 14-5. ⚠️ チュートリアルとツール実装の食い違い

| 項目 | チュートリアル | ツール実装 / 実物 | 採用 |
|---|---|---|---|
| Android の Gradle | `build.gradle.kts` | `plugin_build.dart:751` は `build.gradle` 決め打ち。雛形も同じ | **Groovy `build.gradle`** |
| スレッド | `DispatchQueue.main.async` / `Handler.post` を使用 | pubspec は "no thread hopping" | §14-6（両立する） |
| `CMakeLists.txt` の位置 | `android/` 直下 | 雛形は `src/CMakeLists.txt`、`build.gradle.tmpl` は `../src/CMakeLists.txt` | **`src/`（プラグイン直下）** |

### 14-6. スレッドモデルの補足

「`DispatchQueue.main.async` は不要」は Dart → ネイティブの同期呼び出しに限った話。
ネイティブ側で非同期を挟む場合と、Dart のコールバックを発火する箇所は**必ずメイン**。
Android Next-Gen は全コールバックがバックグラウンドなのでホップは常に必須（design.md §6）。

### 14-7. 命名規約（確定）

`dartnative_<name>` / `com.dartnative.<name>` / `DartNative<Name>Plugin` / C シンボル `DN<Name><Verb>` /
pod 名はパッケージ名 / `lib<package>.so`。チュートリアル自身が `dartnative_share` を名乗る
ので、サードパーティが `dartnative_*` を名乗る前提の記述。ただし `dn_first_party.json`
（一次プラグイン許可リスト）との関係は未確認（design.md §12-3）。

### 14-8. 開発フロー

`dn create .`（既存ディレクトリに iOS/Android シェルを追加）→ `dn run` → `dn plugin build`
（`dist/<name>-<version>.tar.gz`）→ `dn plugin publish` / `dn plugin sync`（README + example 再 push）。

### 14-9. チュートリアルでも判明しなかったこと

`CMakeLists.txt` / podspec の DartNative 用の完全な内容（雛形は Flutter 用。
`s.dependency 'Flutter'` を外すべきかは macOS で未検証 — design.md §12-6）、
iOS 側のプラグインプロバイダ契約（`dartnative_share` はビューを持たない — design.md §12-1）。
