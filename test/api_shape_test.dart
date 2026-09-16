@TestOn('vm')
library;

import 'package:google_mobile_ads_kit/src/ad_error.dart';
import 'package:google_mobile_ads_kit/src/ad_listener.dart';
import 'package:google_mobile_ads_kit/src/ad_preloader.dart';
import 'package:google_mobile_ads_kit/src/ad_request.dart';
import 'package:google_mobile_ads_kit/src/interstitial_ad.dart';
import 'package:google_mobile_ads_kit/src/mobile_ads.dart';
import 'package:google_mobile_ads_kit/src/rewarded_ad.dart';
import 'package:test/test.dart';

/// Guards the parts of the API that exist to match `google_mobile_ads`.
///
/// These are compile-time shape checks as much as runtime assertions: if a
/// signature drifts back to the non-matching form, this file stops compiling,
/// which is the point.
void main() {
  group('load callbacks', () {
    test('each format has its own named subclass', () {
      const InterstitialAdLoadCallback interstitial = InterstitialAdLoadCallback(
        onAdLoaded: _ignoreAd,
        onAdFailedToLoad: _ignoreError,
      );
      const RewardedAdLoadCallback rewarded = RewardedAdLoadCallback(
        onAdLoaded: _ignoreAd,
        onAdFailedToLoad: _ignoreError,
      );

      // The shared base is what lets generic helpers accept any of them.
      expect(interstitial, isA<FullScreenAdLoadCallback<InterstitialAd>>());
      expect(rewarded, isA<FullScreenAdLoadCallback<RewardedAd>>());
    });
  });

  group('PrecisionType', () {
    test('ordinals match the native enum', () {
      // The bridge sends the native ordinal, so the order is load-bearing.
      expect(PrecisionType.values.indexOf(PrecisionType.unknown), 0);
      expect(PrecisionType.values.indexOf(PrecisionType.estimated), 1);
      expect(PrecisionType.values.indexOf(PrecisionType.publisherProvided), 2);
      expect(PrecisionType.values.indexOf(PrecisionType.precise), 3);
    });
  });

  group('PreloadConfiguration', () {
    test('defaults match google_mobile_ads', () {
      const PreloadConfiguration config =
          PreloadConfiguration(adUnitId: 'ca-app-pub-test/1');

      expect(config.bufferSize, 2);
      expect(config.request.toJson(), isEmpty);
    });

    test('keeps an explicit buffer size', () {
      const PreloadConfiguration config = PreloadConfiguration(
        adUnitId: 'ca-app-pub-test/1',
        bufferSize: 5,
      );

      expect(config.bufferSize, 5);
    });
  });

  group('platform fallbacks', () {
    // Off Android and iOS every call is inert rather than throwing, so shared
    // code keeps running on web and desktop (doc/design.md §1-2).
    test('a load reports failure instead of hanging', () async {
      LoadAdError? seen;
      await InterstitialAd.load(
        adUnitId: 'ca-app-pub-test/1',
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: _ignoreAd,
          onAdFailedToLoad: (LoadAdError error) => seen = error,
        ),
      );

      expect(seen, isNotNull);
      expect(seen!.domain, 'google_mobile_ads_kit');
    });

    test('polling an unstarted preloader yields null', () async {
      expect(await InterstitialAdPreloader.pollAd('absent'), isNull);
    });

    test('preloader queries report empty rather than throwing', () async {
      expect(await InterstitialAdPreloader.isAdAvailable('absent'), isFalse);
      expect(await InterstitialAdPreloader.getNumAdsAvailable('absent'), 0);
      expect(await InterstitialAdPreloader.getConfigurations(), isEmpty);
    });

    test('initialize completes with an empty status', () async {
      final InitializationStatus status =
          await MobileAds.instance.initialize();

      expect(status.adapterStatuses, isEmpty);
    });
  });
}

void _ignoreAd(Object ad) {}
void _ignoreError(LoadAdError error) {}
