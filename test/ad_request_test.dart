import 'dart:convert';

import 'package:google_mobile_ads_kit/src/ad_request.dart';
import 'package:test/test.dart';

void main() {
  group('AdRequest', () {
    test('an empty request serializes to an empty object', () {
      expect(const AdRequest().toJson(), isEmpty);
      expect(const AdRequest().encode(), '{}');
    });

    test('omits unset fields so native can tell "unset" from "default"', () {
      final Map<String, Object?> json =
          const AdRequest(keywords: <String>['puzzle']).toJson();

      expect(json.keys, <String>['keywords']);
      expect(json.containsKey('nonPersonalizedAds'), isFalse);
    });

    test('round-trips every field through JSON', () {
      const AdRequest request = AdRequest(
        keywords: <String>['puzzle', 'game'],
        contentUrl: 'https://example.com/article',
        neighboringContentUrls: <String>['https://example.com/a'],
        nonPersonalizedAds: true,
        extras: <String, String>{'key': 'value'},
      );

      final Map<String, Object?> decoded =
          jsonDecode(request.encode()) as Map<String, Object?>;

      expect(decoded['keywords'], <String>['puzzle', 'game']);
      expect(decoded['contentUrl'], 'https://example.com/article');
      expect(decoded['neighboringContentUrls'], <String>['https://example.com/a']);
      expect(decoded['nonPersonalizedAds'], isTrue);
      expect(decoded['extras'], <String, String>{'key': 'value'});
    });

    test('keeps nonPersonalizedAds: false rather than dropping it', () {
      // False is a deliberate choice by the caller, not an absent value.
      expect(
        const AdRequest(nonPersonalizedAds: false).toJson()['nonPersonalizedAds'],
        isFalse,
      );
    });
  });
}
