# dartnative_mobile_ads 設計書

DartNative 向け Google Mobile Ads (AdMob) プラグインの設計と、実装で確定した事項。

- 作成: 2026-09-15（同日に Android 実装完了、実機検証済み）
- 対象 SDK: DartNative 3.45.0-0.1.pre / Dart 3.12.0-192.0.dev / GMA Next-Gen 1.4.0
- ライセンス: MIT
- 調査の根拠: [`research.md`](research.md)（リポジトリのみ。配布物には含めない）

> 節番号はコードの `///` コメント・`CLAUDE.md`・skill から参照されているため
> **変えない**。内容は実装後の事実に更新済み。「設計時の想定 → 実装で判明」の
> 差分は各節の末尾に **実装記録** として残す。

---

## 1. スコープ

### 1-1. フォーマットと状態

| フォーマット | 方式 | Android | iOS |
|---|---|---|---|
| Interstitial / Rewarded / Rewarded Interstitial / App Open | 純 FFI（ビュー不要） | ✅ 実機確認 | 🚧 記述済み・未コンパイル |
| Banner（固定・アダプティブ） | `NativeElement` | ✅ 実機確認 | ⬜ スタブ |
| Native Ads（テンプレート・ファクトリ） | `NativeElement` + ネイティブレイアウト | ✅ 実機確認（AdMob validator 合格） | ⬜ スタブ |
| Preloading | 純 FFI | ✅ ビルド確認（実機の動作は未確認） | ⬜ スタブ |

iOS のスタブは**無反応ではなくロード失敗を返す**（`onAdFailedToLoad` / `pollAd → null`）。
`loadSymbols` は全シンボルを起動時に一括解決するため、1 つでも欠けると
動くフォーマットまで巻き添えになる — スタブは必須。

### 1-2. 対応プラットフォーム

iOS 13.0+ / Android minSdk 24。それ以外（web / desktop）では
**例外を投げずに無反応**（共通コードがそのまま動くように）。

### 1-3. 非対応

メディエーション（Next-Gen は AdMob のみ。v1.0 対象外）、Ad Manager (GAM) 固有機能。

---

## 2. 設計方針

### 2-1. 公開 API は `google_mobile_ads` を踏襲する

DartNative エコシステムの作法（同梱プラグインは Flutter 版の drop-in を公言）で、
移行コストも下がる。**踏襲するのは**クラス名・メソッド名・引数名・enum・リスナー・
エラー構造・ファクトリ登録フロー。**踏襲しないのは**内部実装
（MethodChannel / PlatformView 依存で移植不能）。ファイル構成も本家の
`ad_containers.dart` 一枚岩ではなくフォーマット単位で分割する。

### 2-2. Flutter 版との意図的な差分

| 項目 | Flutter 版 | 本プラグイン | 理由 |
|---|---|---|---|
| バナー / ネイティブ広告の配置 | `AdWidget(ad:)` + 手動 `load()` | ウィジェットを直接ツリーに置く。mount で自動ロード | PlatformView が無く `NativeElement` で直接マウントできる |
| アダプティブサイズ | `await AdSize.getAnchoredAdaptiveBannerAdSize(orientation, width)` | `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)`（同期）。`Future` 版も残す | FFI は同期。`LayoutBuilder` 内で直接呼べる |
| ファクトリ登録（Android） | 第 1 引数 `FlutterEngine` | 第 1 引数 `Context` | `FlutterEngine` が存在しない。ファクトリ本体は同一 |
| テンプレートの色 | `dart:ui` `Color` | 32bit ARGB `int` | スタイル型を `dart:ui` 非依存に保つ |
| ネイティブ広告の高さ | プラットフォームビューから | 利用者が確保（既定値あり） | §8-6 |
| Android の SDK | Legacy 既定 + `USE_NEXT_GEN_SDK` | Next-Gen のみ | 事前ビルド `.aar` はアプリ側で SDK を選べない（§12-9） |

差分は README の表と `migration_from_flutter.md` に明記する。

### 2-3. ライセンス

**MIT。** `google_mobile_ads` は Apache-2.0 だが転記できる実装が実質存在しない
（research.md §13-3）。テンプレートのレイアウト XML も自前で書き起こす（§8-4）。

---

## 3. アーキテクチャ

### 3-1. 全体像

```
Dart   BannerAd / NativeAd ──→ NativeElement（ビューあり）
       Interstitial / Rewarded / AppOpen / Preloader ──→ AdsFFIBindings（ビューなし）
                │ dart:ffi（C ABI・同期）／ 逆方向はディスパッチャスロット（§5-2）
ブリッジ  iOS: @_cdecl Swift（1 ホップ）   Android: C++ JNI → Kotlin AdsBridge（2 ホップ）
                │
SDK     Google Mobile Ads   iOS v13 Swift API ／ Android Next-Gen (ads-mobile-sdk)
```

### 3-2. ディレクトリ構成（実物）

```
dartnative_mobile_ads/
├── lib/
│   ├── dartnative_mobile_ads.dart      # export + initializeMobileAdsPlugin()
│   └── src/
│       ├── ads_ffi_bindings.dart       # typedef・loadSymbols・ディスパッチャ・イベント種別
│       ├── mobile_ads.dart  ad_request.dart  ad_error.dart  ad_listener.dart  ad_base.dart
│       ├── full_screen_ad.dart         # 全画面 4 形式の共通ロード / イベント経路
│       ├── interstitial_ad.dart  rewarded_ad.dart  app_open_ad.dart
│       ├── ad_preloader.dart           # AdPreloader + フォーマット別 4 クラス
│       ├── ad_size.dart  banner_ad.dart
│       └── native_ad.dart  native_ad_options.dart  native_template_style.dart
├── ios/  dartnative_mobile_ads.podspec,  Classes/DNMobileAds.swift（全 @_cdecl。バナー等はスタブ）
├── src/  CMakeLists.txt（★プラグイン直下）,  ads_bridge.cpp（JNI ブリッジ）
├── android/
│   ├── build.gradle                    # ★ Groovy。cmake path = ../src/CMakeLists.txt
│   └── src/main/
│       ├── AndroidManifest.xml         # package 属性なし（AGP 8）
│       ├── kotlin/com/dartnative/mobile_ads/
│       │   ├── DartNativeMobileAdsPlugin.kt   # 登録・loadLibrary・registerNativeAdFactory
│       │   ├── AdsBridge.kt                   # 実処理（@Keep @JvmStatic）
│       │   ├── BannerAdProvider.kt  NativeAdProvider.kt   # DNAndroidPluginProvider
│       │   ├── NativeAdFactory.kt             # 利用者が実装する interface
│       │   └── NativeAdRenderer.kt            # 同梱テンプレートの inflate とスタイル適用
│       └── res/layout/dn_native_ad_{small,medium}.xml
├── example/   test/
├── skills/dartnative-mobile-ads-usage/ # 利用者向け skill（`dart run skills@ get` で配布）
├── .claude/skills/                     # 開発者向け skill（配布物には含めない）
├── doc/  design.md  research.md  migration_from_flutter.md
├── .pubignore                          # .claude/ .config/ CLAUDE.md doc/research.md を除外
└── pubspec.yaml  README.md  CHANGELOG.md  CLAUDE.md  LICENSE
```

### 3-3. 命名規約

| 対象 | 値 |
|---|---|
| Dart パッケージ / Android パッケージ / プラグインクラス | `dartnative_mobile_ads` / `com.dartnative.mobile_ads` / `DartNativeMobileAdsPlugin` |
| C シンボル | `DNAds*`（`DNAdsLoadAd`, `DNAdsBannerCreate`, `DNAdsNativeAdCreate` …。20 個） |
| ネイティブライブラリ | `libdartnative_mobile_ads.so` |
| ViewType キー | `dartnative_mobile_ads/banner`, `dartnative_mobile_ads/native` |

---

## 4. プラグインマニフェスト

```yaml
dartnative:
  plugin:
    platforms:
      ios:     { ffiPlugin: true }
      android: { package: com.dartnative.mobile_ads, pluginClass: DartNativeMobileAdsPlugin }  # ★ ffiPlugin にしない
  registrant:
    imports: [ package:dartnative_mobile_ads/dartnative_mobile_ads.dart ]
    calls:   [ "initializeMobileAdsPlugin();" ]
```

**Android で `ffiPlugin: true` は不可。** ffi のみのプラグインは registrant に
載らず `System.loadLibrary` が走らないため、広告コールバック（リバース JNI）が
`UnsatisfiedLinkError` で落ちる（`dartnative_firebase` の pubspec と同じ注意）。
`initializeMobileAdsPlugin()` が FFI シンボル解決とバナー / ネイティブ広告の
要素ファクトリ登録を行う。

---

## 5. Dart ↔ ネイティブの通信設計

### 5-1. Dart → ネイティブ

| 用途 | 手段 |
|---|---|
| ビューを持たない操作（ロード・表示・プリロード） | FFI 関数を直接呼ぶ |
| ビューの設定 | mount 時に FFI で viewId をキーに事前登録（§7-5）。`PluginMutation` は現状未使用 |

> ⚠️ `handleMutation` は**全プロバイダにブロードキャスト**される。タグ衝突の回避は自己責任。

> ⚠️ **`createView` は自分の種別でなければ `null` を返す。** `DNPluginRegistry.createView`
> は登録順に走査し**最初の non-null で打ち切る**（`.aar` 逆アセンブルで確認。
> インターフェースも `@Nullable`）。空の `FrameLayout` を返すと後続のビュー種別を
> すべて横取りする — バナー単独では出ず、2 つ目のビュー種別（ネイティブ広告）を
> 足したときに「ロード成功なのに空白」で発覚した。

### 5-2. ネイティブ → Dart: ディスパッチャスロット方式

`Pointer.fromFunction`（`NativeCallable` ではない）で作った**唯一の**コールバック
ポインタをネイティブへ一度だけ渡し、ネイティブは「スロット」に格納して
**発火の直前に毎回読み直し、非ゼロなら呼ぶ**。C++ 側にはキャッシュしない。

```dart
typedef _DispatchC = Void Function(Int64 token, Int32 status, Pointer<Utf8> json);
```

**ホットリスタート:** `DNViewRegistry.registerResetHook` に登録した `reset()` が
旧 isolate 破棄の**前**に呼ばれ、スロットをゼロにし、保持中の広告 / `AdView` /
`NativeAdView` を解放する。広告イベントは秒〜分単位で遅れて届くため、
リスタートを跨ぐのが常態 — このパターンは必須。

> 実装記録: 設計時は Android で isolate 世代カウンタ（`nativeIsolateGen()`）を併用する
> つもりだったが、**エンジンはそのシンボルを公開していない**（`DNRegisterAsyncDispatcherSlot`
> は `.so` に無く、`DN_IsolateGen` はゲッターではない）。実在する仕組みが
> `registerResetHook`（バイトコードで確認）。研究記録 §14-4 参照。

### 5-3. ペイロード

構造化データは JSON 文字列（`Pointer<Utf8>`）。`token`(Int64) は Dart 側の受け口、
`status`(Int32) はイベント種別（`AdEventStatus` 0–14。**追番のみ・改番禁止**、
Kotlin / Swift に同じ定数がある）。同期の文字列返却は「呼び出し側バッファ + 書き込み長、
容量不足は必要サイズを負値で返す」形式（`DNAdsPreloadReadJson`）。

---

## 6. スレッドモデル

Dart はプラットフォームのメインスレッド上で動く（ラスタスレッド無し）。

| 方向 | ルール |
|---|---|
| Dart → ネイティブ（同期） | UI API を直接呼んでよい |
| ネイティブ → Dart | **必ずメインスレッドから**（`Pointer.fromFunction` は所有 isolate のスレッドを要求） |

**Android Next-Gen は全コールバックをバックグラウンドで発火する。** `AdsBridge.deliver`
が `mainHandler.post` で必ずメインへ戻す。`MobileAds.initialize` と広告ロードは逆に
**メインで呼ぶと ANR** なので `ioExecutor` へ投げる。ビュー生成（`NativeAdView` の
inflate 等）はメインへ戻してから行う。iOS の GMA デリゲートはメインで発火する。

---

## 7. バナー広告の設計

### 7-1. ウィジェット構成（2 層）

`BannerAd`（公開 `StatefulWidget`）→ `_BannerAdView`（内部リーフ `Widget`）→
`_BannerAdElement extends NativeElement`。`registerElementFactory` に渡すのはリーフのみ。
リスナーには不変ウィジェットの代わりに `_BannerAdHandle extends Ad` を渡す。

### 7-2. `NativeElement` の契約

`viewType`（`ViewType.claim`）・`buildProps`・`mount`・`update`・`unmount`。
`stretchAsStackFlowChild => true` で親の幅いっぱいに広がる。

### 7-3. サイズ決定

プラグインのビューは **intrinsic size を Yoga に報告できない**が、バナーは
リクエスト前にサイズが決まるので `SetFlexAspectRatio(viewId, w/h)` を mount 時に
emit すれば足りる。アダプティブは `LayoutBuilder` で幅を取り、
`AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(width)`（同期 FFI →
Kotlin の `AdSize.getLargeAnchoredAdaptiveBannerAdSize`）で高さを解析的に得る。

**標準サイズは SDK 定数に写像する（重要）。** 自前の `AdSize(320, 50)` は
`AdSize.BANNER` と同一視されず、AdMob が「柔軟な枠」と解釈して **468x60 を返してきた**
（実機）。Kotlin `resolveAdSize()` が BANNER / LARGE_BANNER / MEDIUM_RECTANGLE /
FULL_BANNER / LEADERBOARD を定数に写像し、それ以外はカスタムのまま通す。

### 7-4. ⚠️ リスト内配置（IVT リスク）

`FastList` / `FastGrid` は RecyclerView / UITableView ベースの本物のリサイクルを行う。
セルが画面外に出て戻ると unmount → remount され**新しい広告リクエストが飛ぶ**
（在庫浪費・マッチレート低下・無効トラフィック判定）。

実装している対策は**破棄の 1 マイクロタスク遅延 + 世代チェック**（§7-5）:
リサイクルで同一フレーム内に再マウントされた要素は破棄せず、本当の unmount だけ
`AdView.destroy()` に至る。**スロット単位の広告キャッシュは実装していない** —
遠くへスクロールして戻ったセルは再リクエストになる。README で
「`ScrollView` / `Column` 推奨、`keepAliveCount` は設定しない」と案内する。

### 7-5. 実装記録（Android、2026-09-15。実機 Pixel 9 Pro / API 37）

1. **`createView` は広告設定を受け取れない**（引数はビュー種別のみ）。Dart の `mount` が
   先に `bannerCreate(token, viewId, adUnitId, …)` を呼び、Kotlin が `FrameLayout` を
   キューに積み、直後の `createView` がそれを返す。リコンサイラは同期でビューを要求
   するので空コンテナを即返し、ロード後に `AdView` を入れる。
2. ビュー種別は両側で同じキーを claim（冪等。番号をハードコードしない）。
3. **`AdView` を `MATCH_PARENT` で入れてはいけない** — クリエイティブが右端で切れた。
   実サイズ（dp × density）で `Gravity.CENTER`。AdMob は拡大縮小・切り取りを禁じる。
4. `AdView.loadAd()` を使う（`BannerAd.load()` は deprecated。ロードと登録が一体）。
5. `unmount` では `release(token)` 後、`scheduleMicrotask` で世代番号を照合してから
   `bannerDispose`。ホットリスタートは `reset()` が残りを全て destroy。
   （破棄経路が無く `AdView` が永久に残るバグを修正した結果。）

---

## 8. Native Ads の設計

### 8-1. Dart でレイアウトは書けない（Flutter 版も同じ）

AdMob は素材ビューを `NativeAdView` の子として登録させ、SDK がクリックと
ビューアビリティを計測する。DartNative がプラグインに与えるのはリーフ 1 枚と
バイト列のパイプだけなので、Dart のウィジェットを広告ビューの内側に入れられない。
これは AdMob 側の要求で、Flutter の `google_mobile_ads` も XML / xib で書く。

制約が効くのは **Dart → ネイティブ方向だけ**。`NativeAdView` は `FrameLayout`
（`BaseAdAssetViewContainer`）なので、ネイティブ側で子を組む分には制約はない。

### 8-2. 提供する 2 方式（Flutter 版と同じ）

| 方式 | 内容 |
|---|---|
| テンプレート | 同梱の small / medium レイアウトを Kotlin で inflate し、`NativeTemplateStyle`（JSON）で色・フォント・角丸を適用 |
| ファクトリ | 利用者が `NativeAdFactory` を実装して登録。Dart は `factoryId` で指定。`customOptions` を JSON で渡す |

❌ Dart レイアウト + 透明 `NativeAdView` の重ね合わせは採らない（素材の被覆はポリシー違反）。

### 8-3. Next-Gen SDK の API（`ads-mobile-sdk` の `.aar` を `javap` で確認）

| 用途 | API |
|---|---|
| 広告 | `nativead.NativeAd`（interface）: `headline / body / icon / callToAction / starRating / store / price / advertiser / mediaContent` |
| コンテナ | `nativead.NativeAdView` → `common.BaseAdAssetViewContainer` → `FrameLayout` |
| アセット登録 | `setHeadlineView / setBodyView / setCallToActionView / setIconView / setStarRatingView / setAdvertiserView / setStoreView / setPriceView` |
| 紐付け / ロード | `NativeAdView.registerNativeAd(ad, MediaView)` ／ `NativeAdLoader.load(NativeAdRequest, NativeAdLoaderCallback)` |
| オプション | `NativeAdRequest.Builder`: `setMediaAspectRatio / setAdChoicesPlacement / setVideoOptions(VideoOptions.Builder) / disableImageDownloading` |

注意: `setHeadlineView` 等は**基底クラス側**にある（`NativeAdView` だけ見ると無いと誤認する）。
`registerNativeAd` の `MediaView` は必須位置引数。`NativeAd` に `destroy()` は無く、
`NativeAdView.destroy()` で破棄する。`AdChoicesPlacement` の enum 順は Dart 側
（`google_mobile_ads` 互換: topRight 先頭）と異なるので index をそのまま渡さない。
`shouldRequestMultipleImages` / `requestCustomMuteThisAd` に相当する builder API は無い。

### 8-4. テンプレートは自前で持つ

Flutter 版の small / medium は SDK 機能ではなく `google_mobile_ads` 同梱の資産
（Apache-2.0）。Next-Gen SDK の `.aar` にテンプレートは 1 件も無い。
本パッケージは MIT かつ転記しない方針なので、`res/layout/dn_native_ad_*.xml` と
`NativeAdRenderer.kt` を**書き起こした**。既定高さは small 90dp / medium 350dp。

### 8-5. ファクトリ登録 API

```kotlin
DartNativeMobileAdsPlugin.registerNativeAdFactory(context, "adFactoryExample", factory)   // Flutter は engine
DartNativeMobileAdsPlugin.unregisterNativeAdFactory("adFactoryExample")
interface NativeAdFactory { fun createNativeAdView(nativeAd: NativeAd, customOptions: Map<String, Any?>): NativeAdView }
```

Dart 側の呼び出しは Flutter 版と完全に同一。ファクトリ実装は import 差し替えで移植できる。
登録するのはビューではなくファクトリで、`factoryId` はバナー同様 viewId をキーに事前登録で渡す。
未登録の `factoryId` はネットワークに出る前に `onAdFailedToLoad` で即失敗させる。

### 8-6. サイズ決定（バナーと違う）

ネイティブ広告は**事前に高さが確定しない**ので Dart 側で高さを決める:
テンプレートは既定値、ファクトリは利用者が `height:` を指定（未指定なら small の 90）。
渡し方は **`LayoutBuilder` で幅を取り `SetFlexAspectRatio(width / height)`** — プラグインが
emit できるサイズ系 mutation はこれだけで（`SetFlexHeight` は `plugin.dart` 非公開）、
**`SizedBox` で囲んでも中のネイティブビューは 0x0 のまま描画されない**（§8-7）。

### 8-7. 実装記録（Android、2026-09-15。実機）

small / medium 両テンプレートを表示し、**AdMob 純正 "native ad validator" が
"No implementation issues found"** を表示（アセット登録の一次確認）。設計変更 2 点:

1. `createView` の `null` 契約（§5-1）— これを破っていたためロード成功なのに空白だった。
2. `SizedBox` では足りず `SetFlexAspectRatio` が要る（§8-6）— 当初 §8-6 は「`SizedBox` に
   包む」としていたが誤り。

---

## 9. ネイティブ依存の宣言

### 9-1. iOS: `ios/dartnative_mobile_ads.podspec`

`s.platform = :ios, '13.0'`、`s.dependency 'Google-Mobile-Ads-SDK', '~> 13.0'`（v12 で Swift
API 名から `GAD` 接頭辞が消えたため v13 の名前で書く）、`s.frameworks` に
`AdSupport` / `AppTrackingTransparency`、`pod_target_xcconfig` に `DEAD_CODE_STRIPPING = NO`
（`@_cdecl` はコンパイル時参照が無く Release で消える）。`s.dependency` があるため
`dn plugin build` は CocoaPods 経路 = **macOS 必須**（§11）。公式雛形の
`s.dependency 'Flutter'` は外している — macOS で未検証（§12-6）。

### 9-2. Android: `android/build.gradle`

**Groovy 限定**（ツールが `build.gradle` 決め打ち）。依存は
`com.google.android.libraries.ads.mobile.sdk:ads-mobile-sdk:1.4.0`（解決も 1.4.0。
API の確認は 1.3.1 の `javap` で行い、1.4.0 でもそのままビルド・動作）。
要件 minSdk 24 / compileSdk 35+ / Kotlin 1.9+ は本モジュール（24 / 36 / 2.1）で充足。
import は `com.google.android.libraries.ads.mobile.sdk.*`。

制約: バージョンを明示ピン（`.aar` に POM が無い）／ファイルを跨ぐ Gradle 変数は不可／BOM は可。

**Next-Gen の実 API（設計時の Legacy 風の想定との差）:**

| 想定 | 実際 |
|---|---|
| `InterstitialAdLoadCallback` 抽象クラス | `AdLoadCallback<T>` ジェネリック interface |
| `onPaidEventListener` | `AdEventCallback.onAdPaid(AdValue)` に統合 |
| `FullScreenContentCallback` | `AdEventCallback` + フォーマット別派生を `ad.adEventCallback` に代入。派生は全て基底を継承するので **イベント処理は `AdsBridge.AdEvents` 1 クラスで共有** |
| `MobileAds.setAppMuted` | `MobileAds.setUserMutedApp` |
| `error.code: Int` / `error.domain` | enum（`.code.value`）／ domain は無い（プラグインが付与） |
| `setNeighboringContentUrls(List)` | `Set<String>` |
| `VideoOptions(a, b, c)` | コンストラクタは private。`VideoOptions.Builder` |

### 9-3. AdMob App ID（利用者が手動設定）

マニフェストマージが無いので README で案内する。Next-Gen SDK 自体は manifest を読まず
`InitializationConfig.Builder(appId)` で受け取るが、利用者には Legacy / Flutter と同じ
`<meta-data>` を書いてもらい、`AdsBridge.initialize` が `PackageManager` 経由で読んで渡す。
これで `MobileAds.instance.initialize()` を引数なしに保てる。無ければ SDK に
クラッシュさせず `initialize()` を失敗させ、エラーメッセージで追記を案内する。
iOS は `Info.plist` の `GADApplicationIdentifier`。

### 9-4. Android Gradle の配線（実装で判明）

1. **エンジンのクラス（`DNNavigator` / `DNViewRegistry` / `DNPluginRegistry`）は自動では
   classpath に載らない。** アプリ内ビルドでは兄弟プロジェクト `:dartnative_android` を、
   `dn plugin build` の単独ビルドでは `local.properties` の `dn.sdk` から SDK キャッシュの
   `.aar` を `compileOnly` で参照する（ランタイムに載せると 17 MB の `.so` が重複）。
2. **エンジンの embedding は Flutter の Maven に無い**（`storage.googleapis.com` は 404）。
   `https://cdn.dartnative.com/download.flutter.io` を自分で宣言する。
3. **example の `dartnative_android` / `dartnative_ios` 依存を消してはいけない。** 外すと
   エンジンの `.aar` が classpath から消え `Theme.Material3.*` のリンクエラーになる。
   プラグインルートで `dn pub get` を実行すると example の pubspec が書き換わりこれが起きる。

---

## 10. 実装状況

| # | 内容 | 状態 |
|---|---|---|
| 1–2 | Android: Interstitial / Rewarded / Rewarded Interstitial / App Open + イベント経路 | ✅ 4 形式はロードもイベントも同一経路（`full_screen_ad.dart` / `AdsBridge.AdEvents`）。App Open のライフサイクル検知は未実装（表示タイミングは利用者が決める） |
| 3 | Android: Banner | ✅ 固定・アダプティブとも実機表示 |
| 4 | iOS 全般 | 🟡 Swift 記述済み・**未コンパイル**。バナー / ネイティブ / プリロードはスタブ |
| 5 | Preloading | ✅ Android ビルド・シンボル確認。実機でのバッファ動作は未確認 |
| 6 | Android: Native Ads | ✅ 実機表示・validator 合格 |

**プリロードの実装判断:** プリロード済み広告のトークンは Kotlin が採番（Dart は正、
Kotlin は負の値で衝突回避）。`peekAdResponseInfo` は「次の」広告を指すので poll 直前に
取得してキャッシュ。`getConfigurations` 等のため同期の JSON 返却（§5-3）を追加。
本家に無い `RewardedInterstitialAdPreloader` も SDK にあるので提供。

**API 互換（本家ソースと突合済み）:** `load` / `show` / `dispose` / プリローダは
`Future` を返す。`InterstitialAdLoadCallback` 等は `FullScreenAdLoadCallback<T>` の
サブクラス。`Ad.responseInfo` / `onPaidEvent` / `setImmersiveMode` / `setServerSideOptions` あり。

---

## 11. 既知の障壁

| 障壁 | 深刻度 | 内容 |
|---|---|---|
| iOS ビルドに Mac 必須 | 高 | `import GoogleMobileAds` が pods 経路を強制。`dn plugin build` は非 macOS で即終了 |
| Android コールバックがバックグラウンド | 高 | ホップを 1 か所忘れると `Pointer.fromFunction` の isolate 制約で落ちる（§6） |
| JNI の例外運び | 高 | `GetStaticMethodID` 失敗は例外を pending にし、次の JNI 呼び出しでプロセスが abort。`FindMethod` が毎回 `ExceptionClear`。実機でしか出ない |
| `createView` の `null` 契約 | 中 | §5-1。ビュー種別が 1 つのうちは発覚しない |
| リスト内の再リクエスト | 中 | §7-4 |
| 参考ネイティブ実装が無い | 中 | SDK 同梱プラグインにソースが無い。公式チュートリアルと `.aar` 逆アセンブルが頼り |
| App ID 手動設定 | 低 | §9-3 |

---

## 12. 未確認事項

### 12-1. iOS のプラグインプロバイダ契約

— Android の `createView(Int)` + `handleMutation`
と同形かは未検証（`dartnative_ios` に読める framework が無い）。**iOS のバナー /
ネイティブ広告の前提**であり Android には影響しない。バナーとネイティブ広告を
混同しないこと: 子ビュー制約が効くのはネイティブ広告だけで、バナーは SDK の
`AdView` 1 枚を返すだけ（`google_mobile_ads` でも `BannerAd` に `factoryId` は無い）。
### 12-2. `ViewType.claim()` の iOS 側採番

— Android は 65535 から降順・下限 60000。
### 12-3. `dartnative_*` 命名と一次プラグイン許可リスト

— チュートリアルは `dartnative_share`
を名乗るが `dn_first_party.json` との関係は未確認。公開前に dartpub.dev で確認。
### 12-4. ~~`CMakeLists.txt` の位置~~

**解決。** `src/CMakeLists.txt`（プラグイン直下）。
`dn create --template plugin_ffi` の生成物と直接比較して一致を確認（2026-09-15）。
### 12-5. サードパーティ公開のライセンス要件

— 無料 Community プランで dartpub.dev に
公開できるか未確認。技術課題ではなく公開の前提条件。
### 12-6. podspec の macOS 検証

— `:file => '../LICENSE'` の `pod lib lint`、および公式雛形の
`s.dependency 'Flutter'` を外していることの妥当性。iOS 着手時の最初に確認。
### 12-7. prerelease

— SDK 制約 `^3.12.0-192.0.dev` は `dn create` 自身が出す値で変えられない。
パッケージ版は `0.1.0`（通常版）。pub は「prerelease の SDK 制約なら版も prerelease に」と
**警告する**が拒否ではなく、警告を受け入れて通常版で進める。
dartpub.dev / `dn plugin publish` がこの制約をどう扱うかは未確認。
### 12-8. ~~Native Ads のファクトリ登録 API~~

**解決**（§8-5）。iOS 側は §12-1 に従属。
### 12-9. Android SDK は Next-Gen 一本（案 A で決定）。

| | Legacy `play-services-ads` | Next-Gen `ads-mobile-sdk` |
|---|---|---|
| 状態 | 「Legacy」と明記 | GA。公式の既定 |
| 初期化 / App ID | 任意 / manifest | **必須** / コード（`InitializationConfig`）。**バックグラウンドで呼ぶ** |
| コールバック | メイン | **バックグラウンド** |
| メディエーション | 各社 | AdMob のみ |

---

## 13. ドキュメントと配布

- `doc/`（pub 規約で単数形）。`design.md` と `migration_from_flutter.md` は配布、
  `research.md` は開発者向けとして `.pubignore` で除外。
- 利用者向け agent skill は `skills/dartnative-mobile-ads-usage/`（`dart run skills@ create`
  で生成。ディレクトリ名と `name:` を一致させる）。開発者向け skill は `.claude/skills/`。
- `dart pub publish --dry-run` の警告は未コミットと prerelease SDK 制約の 2 件のみ
  （後者は §12-7 のとおり受け入れ。`doc/` 単数化・CHANGELOG 見出し・`.vscode` の
  ignore 範囲は対処済み）。
