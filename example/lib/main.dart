import 'dart:io' show Platform;

import 'package:dartnative/dartnative.dart';
import 'package:dartnative_mobile_ads/dartnative_mobile_ads.dart';

import 'dartnative_plugin_registrant.dart';

void main() {
  // Platform bindings + plugin FFI symbols. Keep this as the FIRST line of
  // main() — see lib/dartnative_plugin_registrant.dart.
  DartNativePluginRegistrant.registerAll();

  // Start the Mobile Ads SDK. No need to await it: requests made while it is
  // still starting are queued by the SDK.
  MobileAds.instance.initialize();

  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  );
  runApp(const HomeScreen());
}

/// Google's sample ad units.
///
/// These always fill, on any device, and are the only units safe to use during
/// development: requesting your own units from a test device risks having the
/// traffic flagged as invalid.
abstract final class TestAdUnits {
  /// The interstitial test unit for the current platform.
  static String get interstitial => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/1033173712'
      : 'ca-app-pub-3940256099942544/4411468910';

  /// The rewarded test unit for the current platform.
  static String get rewarded => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/5224354917'
      : 'ca-app-pub-3940256099942544/1712485313';

  /// The rewarded interstitial test unit for the current platform.
  static String get rewardedInterstitial => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/5354046379'
      : 'ca-app-pub-3940256099942544/6978759866';

  /// The app open test unit for the current platform.
  static String get appOpen => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/9257395921'
      : 'ca-app-pub-3940256099942544/5575463023';

  /// The banner test unit for the current platform.
  static String get banner => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/6300978111'
      : 'ca-app-pub-3940256099942544/2934735716';

  /// The native advanced test unit for the current platform.
  static String get nativeAd => Platform.isAndroid
      ? 'ca-app-pub-3940256099942544/2247696110'
      : 'ca-app-pub-3940256099942544/3986624511';
}

/// Demonstrates each full-screen ad format.
class HomeScreen extends StatefulWidget {
  /// Creates the demo screen.
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _status = 'Ready.';

  InterstitialAd? _interstitial;
  RewardedAd? _rewarded;
  RewardedInterstitialAd? _rewardedInterstitial;
  AppOpenAd? _appOpen;

  void _log(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  /// Wires the presentation callbacks shared by every format.
  ///
  /// Disposing in both terminal cases — dismissed and failed-to-show — is the
  /// rule for full-screen ads: the ad is spent either way.
  FullScreenContentCallback<T> _contentCallback<T extends FullScreenAd>(
    String label,
    void Function() clear,
  ) {
    return FullScreenContentCallback<T>(
      onAdShowedFullScreenContent: (_) => _log('$label: showed'),
      onAdImpression: (_) => _log('$label: impression'),
      onAdClicked: (_) => _log('$label: clicked'),
      onAdDismissedFullScreenContent: (T ad) {
        _log('$label: dismissed');
        ad.dispose();
        clear();
      },
      onAdFailedToShowFullScreenContent: (T ad, AdError error) {
        _log('$label: failed to show — ${error.message}');
        ad.dispose();
        clear();
      },
    );
  }

  void _loadInterstitial() {
    _log('Interstitial: loading…');
    InterstitialAd.load(
      adUnitId: TestAdUnits.interstitial,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (InterstitialAd ad) {
          ad.fullScreenContentCallback = _contentCallback<InterstitialAd>(
            'Interstitial',
            () => _interstitial = null,
          );
          _interstitial = ad;
          _log('Interstitial: loaded — tap Show');
        },
        onAdFailedToLoad: (LoadAdError error) =>
            _log('Interstitial: load failed — ${error.message}'),
      ),
    );
  }

  void _loadRewarded() {
    _log('Rewarded: loading…');
    RewardedAd.load(
      adUnitId: TestAdUnits.rewarded,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          ad.fullScreenContentCallback = _contentCallback<RewardedAd>(
            'Rewarded',
            () => _rewarded = null,
          );
          _rewarded = ad;
          _log('Rewarded: loaded — tap Show');
        },
        onAdFailedToLoad: (LoadAdError error) =>
            _log('Rewarded: load failed — ${error.message}'),
      ),
    );
  }

  void _loadRewardedInterstitial() {
    _log('Rewarded interstitial: loading…');
    RewardedInterstitialAd.load(
      adUnitId: TestAdUnits.rewardedInterstitial,
      request: const AdRequest(),
      rewardedInterstitialAdLoadCallback: RewardedInterstitialAdLoadCallback(
        onAdLoaded: (RewardedInterstitialAd ad) {
          ad.fullScreenContentCallback =
              _contentCallback<RewardedInterstitialAd>(
            'Rewarded interstitial',
            () => _rewardedInterstitial = null,
          );
          _rewardedInterstitial = ad;
          _log('Rewarded interstitial: loaded — tap Show');
        },
        onAdFailedToLoad: (LoadAdError error) =>
            _log('Rewarded interstitial: load failed — ${error.message}'),
      ),
    );
  }

  void _loadAppOpen() {
    _log('App open: loading…');
    AppOpenAd.load(
      adUnitId: TestAdUnits.appOpen,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (AppOpenAd ad) {
          ad.fullScreenContentCallback = _contentCallback<AppOpenAd>(
            'App open',
            () => _appOpen = null,
          );
          _appOpen = ad;
          _log('App open: loaded — tap Show');
        },
        onAdFailedToLoad: (LoadAdError error) =>
            _log('App open: load failed — ${error.message}'),
      ),
    );
  }

  /// The preload buffer this demo fills, named by the moment it serves.
  static const String _preloadId = 'level-end';

  bool _preloadStarted = false;

  /// Starts filling a buffer of interstitials in the background.
  ///
  /// Do this once, early. From then on an ad is ready the instant it is needed,
  /// instead of after a network round trip.
  Future<void> _startPreloading() async {
    await InterstitialAdPreloader.start(
      preloadId: _preloadId,
      preloadConfiguration: PreloadConfiguration(
        adUnitId: TestAdUnits.interstitial,
        request: const AdRequest(),
        bufferSize: 2,
      ),
      callback: PreloadCallback(
        onAdPreloaded: (String id, ResponseInfo? info) =>
            _log('Preload: ad ready in "$id"'),
        onAdsExhausted: (String id) => _log('Preload: "$id" is empty'),
        onAdFailedToPreload: (String id, AdError error) =>
            _log('Preload failed: ${error.message}'),
      ),
    );
    if (!mounted) return;
    setState(() => _preloadStarted = true);
  }

  /// Takes a preloaded ad and shows it, with no wait.
  Future<void> _showPreloaded() async {
    final int count =
        await InterstitialAdPreloader.getNumAdsAvailable(_preloadId);
    final InterstitialAd? ad =
        await InterstitialAdPreloader.pollAd(_preloadId);

    if (ad == null) {
      _log('Preload: buffer empty (it refills on its own)');
      return;
    }
    _log('Preload: showing 1 of $count buffered');
    ad.fullScreenContentCallback = _contentCallback<InterstitialAd>(
      'Preloaded interstitial',
      () {},
    );
    await ad.show();
  }

  @override
  void dispose() {
    InterstitialAdPreloader.destroy(_preloadId);
    _interstitial?.dispose();
    _rewarded?.dispose();
    _rewardedInterstitial?.dispose();
    _appOpen?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      brightness: Brightness.light,
      appBar: AppBar(
        title: const Text(
          'Mobile Ads',
          style: TextStyle(
            color: Color(0xFF111111),
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      backgroundColor: const Color(0xFFFFFFFF),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF2F2F7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _status,
                style: const TextStyle(fontSize: 14, color: Color(0xFF333333)),
              ),
            ),
            const SizedBox(height: 24),
            _AdSection(
              title: 'Interstitial',
              onLoad: _loadInterstitial,
              onShow: _interstitial == null ? null : () => _interstitial!.show(),
            ),
            _AdSection(
              title: 'Rewarded',
              onLoad: _loadRewarded,
              onShow: _rewarded == null
                  ? null
                  : () => _rewarded!.show(
                        onUserEarnedReward: (Ad ad, RewardItem reward) =>
                            _log('Reward: ${reward.amount} ${reward.type}'),
                      ),
            ),
            _AdSection(
              title: 'Rewarded interstitial',
              onLoad: _loadRewardedInterstitial,
              onShow: _rewardedInterstitial == null
                  ? null
                  : () => _rewardedInterstitial!.show(
                        onUserEarnedReward: (Ad ad, RewardItem reward) =>
                            _log('Reward: ${reward.amount} ${reward.type}'),
                      ),
            ),
            _AdSection(
              title: 'App open',
              onLoad: _loadAppOpen,
              onShow: _appOpen == null ? null : () => _appOpen!.show(),
            ),
            // Preloading keeps a buffer filled in the background, so Show
            // never waits on the network. Start once, then poll repeatedly.
            // A banner goes straight into the tree — no AdWidget wrapper and
            // no manual load(), unlike google_mobile_ads.
            const Text(
              'Banner (320x50)',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 8),
            const _FixedBannerDemo(),
            const SizedBox(height: 20),
            const Text(
              'Banner (adaptive)',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 8),
            const _AdaptiveBannerDemo(),
            const SizedBox(height: 20),
            // A native ad's layout is built natively — either from one of the
            // built-in templates, as here, or by a factory you register.
            const Text(
              'Native (small template)',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 8),
            const _SmallNativeDemo(),
            const SizedBox(height: 20),
            const Text(
              'Native (medium template)',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 8),
            const _MediumNativeDemo(),
            const SizedBox(height: 20),
            _AdSection(
              title: 'Interstitial (preloaded)',
              loadLabel: 'Start',
              showLabel: 'Poll & show',
              onLoad: _startPreloading,
              onShow: _preloadStarted ? _showPreloaded : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The standard 320x50 banner — the usual choice, and a fixed size.
class _FixedBannerDemo extends StatelessWidget {
  const _FixedBannerDemo();

  @override
  Widget build(BuildContext context) {
    return BannerAd(
      adUnitId: TestAdUnits.banner,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (Ad ad) => dnLog('Banner 320x50: loaded'),
        onAdFailedToLoad: (Ad ad, LoadAdError error) =>
            dnLog('Banner 320x50: failed — ${error.message}'),
      ),
    );
  }
}

/// An adaptive banner, sized to the width it is given.
///
/// Fills the available width with a Google-optimized height, so it suits a
/// screen-width slot better than the fixed 320x50 does on a wide device.
class _AdaptiveBannerDemo extends StatelessWidget {
  const _AdaptiveBannerDemo();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // Ask for the Google-optimized height for this width *before*
        // requesting, so the space is reserved correctly from the first frame.
        final AdSize? size =
            AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
          constraints.maxWidth.truncate(),
        );
        if (size == null) return const SizedBox.shrink();

        return BannerAd(
          adUnitId: TestAdUnits.banner,
          size: size,
          request: const AdRequest(),
          listener: BannerAdListener(
            onAdLoaded: (Ad ad) => dnLog('Banner adaptive: loaded'),
            onAdFailedToLoad: (Ad ad, LoadAdError error) =>
                dnLog('Banner adaptive: failed — ${error.message}'),
          ),
        );
      },
    );
  }
}

/// A native ad rendered with the compact built-in template.
class _SmallNativeDemo extends StatelessWidget {
  const _SmallNativeDemo();

  @override
  Widget build(BuildContext context) {
    return NativeAd(
      adUnitId: TestAdUnits.nativeAd,
      nativeTemplateStyle: const NativeTemplateStyle(
        templateType: TemplateType.small,
        mainBackgroundColor: 0xFFF2F2F7,
        cornerRadius: 12,
      ),
      listener: NativeAdListener(
        onAdLoaded: (Ad ad) => dnLog('Native small: loaded'),
        onAdFailedToLoad: (Ad ad, LoadAdError error) =>
            dnLog('Native small: failed — ${error.message}'),
      ),
    );
  }
}

/// A native ad rendered with the taller template, which shows the ad's media.
///
/// Styled here to show that the template's colours and type are controllable
/// from Dart even though the layout itself is native.
class _MediumNativeDemo extends StatelessWidget {
  const _MediumNativeDemo();

  @override
  Widget build(BuildContext context) {
    return NativeAd(
      adUnitId: TestAdUnits.nativeAd,
      nativeTemplateStyle: const NativeTemplateStyle(
        templateType: TemplateType.medium,
        mainBackgroundColor: 0xFFFFFFFF,
        cornerRadius: 12,
        primaryTextStyle: NativeTemplateTextStyle(
          textColor: 0xFF111111,
          style: NativeTemplateFontStyle.bold,
        ),
        callToActionTextStyle: NativeTemplateTextStyle(
          textColor: 0xFFFFFFFF,
          backgroundColor: 0xFF2563EB,
        ),
      ),
      listener: NativeAdListener(
        onAdLoaded: (Ad ad) => dnLog('Native medium: loaded'),
        onAdFailedToLoad: (Ad ad, LoadAdError error) =>
            dnLog('Native medium: failed — ${error.message}'),
      ),
    );
  }
}

/// One ad format's Load / Show pair.
class _AdSection extends StatelessWidget {
  const _AdSection({
    required this.title,
    required this.onLoad,
    required this.onShow,
    this.loadLabel = 'Load',
    this.showLabel = 'Show',
  });

  final String title;
  final VoidCallback onLoad;

  /// Null until an ad is loaded, which disables the Show button.
  final VoidCallback? onShow;

  final String loadLabel;
  final String showLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: Color(0xFF111111),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: Button(
                  title: loadLabel,
                  variant: ButtonVariant.filled,
                  onPressed: onLoad,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                // A null onPressed disables the button, so Show stays inert
                // until an ad is actually loaded.
                child: Button(
                  title: showLabel,
                  variant: ButtonVariant.filled,
                  onPressed: onShow,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
