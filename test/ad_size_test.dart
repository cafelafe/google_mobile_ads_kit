import 'package:google_mobile_ads_kit/src/ad_size.dart';
import 'package:test/test.dart';

void main() {
  group('AdSize', () {
    test('the standard constants match the AdMob sizes', () {
      // These are fixed by AdMob, and the native side is told the numbers
      // verbatim, so a typo here would silently request the wrong size.
      expect(AdSize.banner, const AdSize(width: 320, height: 50));
      expect(AdSize.largeBanner, const AdSize(width: 320, height: 100));
      expect(AdSize.mediumRectangle, const AdSize(width: 300, height: 250));
      expect(AdSize.fullBanner, const AdSize(width: 468, height: 60));
      expect(AdSize.leaderboard, const AdSize(width: 728, height: 90));
    });

    test('equality is by value, so rebuilds do not re-emit the ratio', () {
      expect(const AdSize(width: 320, height: 50), AdSize.banner);
      expect(
        const AdSize(width: 320, height: 50).hashCode,
        AdSize.banner.hashCode,
      );
      expect(const AdSize(width: 320, height: 51), isNot(AdSize.banner));
    });

    test('the standard sizes stay distinguishable from one another', () {
      // The Android side maps these onto the SDK's own AdSize constants,
      // because a custom size of the same dimensions asks AdMob for a flexible
      // slot and can come back a different shape. If two constants ever
      // collided here, that mapping would silently pick the wrong slot.
      final Set<AdSize> sizes = <AdSize>{
        AdSize.banner,
        AdSize.largeBanner,
        AdSize.mediumRectangle,
        AdSize.fullBanner,
        AdSize.leaderboard,
      };

      expect(sizes, hasLength(5));
    });

    test('an adaptive size is an AdSize', () {
      const AnchoredAdaptiveBannerAdSize size =
          AnchoredAdaptiveBannerAdSize(width: 412, height: 50);

      expect(size, isA<AdSize>());
      expect(size.width, 412);
    });

    test('adaptive sizing reports null off Android and iOS', () {
      // No SDK on the VM, so there is no height to compute; callers fall
      // through to their no-banner path rather than getting a bogus size.
      expect(
        AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(412),
        isNull,
      );
    });

    test('the Future-returning form matches the synchronous one', () async {
      expect(await AdSize.getAnchoredAdaptiveBannerAdSize(412), isNull);
    });
  });
}
