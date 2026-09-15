import 'package:dartnative_mobile_ads/src/ad_error.dart';
import 'package:test/test.dart';

void main() {
  group('ResponseInfo.fromJson', () {
    test('returns null for an absent object', () {
      expect(ResponseInfo.fromJson(null), isNull);
    });

    test('reads the fields the native bridge sends', () {
      final ResponseInfo? info = ResponseInfo.fromJson(<String, Object?>{
        'responseId': 'abc123',
        'mediationAdapterClassName': 'com.google.ads.Adapter',
      });

      expect(info!.responseId, 'abc123');
      expect(info.mediationAdapterClassName, 'com.google.ads.Adapter');
    });

    test('tolerates missing keys', () {
      // The SDK omits these when it has nothing to report; that is not an error.
      final ResponseInfo? info = ResponseInfo.fromJson(<String, Object?>{});

      expect(info!.responseId, isNull);
      expect(info.mediationAdapterClassName, isNull);
    });
  });

  group('AdError', () {
    test('toString includes the code, domain and message', () {
      const AdError error = AdError(3, 'com.google.admob', 'No fill');

      expect(error.toString(), contains('3'));
      expect(error.toString(), contains('com.google.admob'));
      expect(error.toString(), contains('No fill'));
    });
  });

  group('LoadAdError', () {
    test('carries the response info alongside the error fields', () {
      const LoadAdError error = LoadAdError(
        3,
        'com.google.admob',
        'No fill',
        ResponseInfo(responseId: 'abc123'),
      );

      expect(error.code, 3);
      expect(error.responseInfo!.responseId, 'abc123');
      expect(error, isA<AdError>());
    });
  });
}
