/// The targeting information attached to an ad request.
library;

import 'dart:convert';

/// Targeting information used when loading an ad.
///
/// Mirrors `google_mobile_ads`' `AdRequest`. Every field is optional; the
/// default `const AdRequest()` requests an untargeted ad, which is what most
/// apps want.
///
/// ```dart
/// InterstitialAd.load(
///   adUnitId: adUnitId,
///   request: const AdRequest(keywords: ['puzzle', 'game']),
///   adLoadCallback: /* ... */,
/// );
/// ```
class AdRequest {
  /// Creates an ad request with the given targeting information.
  const AdRequest({
    this.keywords,
    this.contentUrl,
    this.neighboringContentUrls,
    this.nonPersonalizedAds,
    this.extras,
  });

  /// Words relevant to the content the ad appears next to.
  final List<String>? keywords;

  /// The URL of the content the ad appears next to.
  final String? contentUrl;

  /// URLs of content shown alongside the ad, for brand-safety targeting.
  final List<String>? neighboringContentUrls;

  /// Whether to request a non-personalized ad.
  ///
  /// Set this to true when the user has not consented to personalized ads.
  /// Obtaining that consent is the app's responsibility — this flag only
  /// forwards the decision to the SDK.
  final bool? nonPersonalizedAds;

  /// Extra key-value parameters passed through to the ad network adapters.
  final Map<String, String>? extras;

  /// Serializes this request for the native bridge.
  ///
  /// Keys whose value is null are omitted so the native side can distinguish
  /// "not set" from "set to a default".
  Map<String, Object?> toJson() => <String, Object?>{
        if (keywords != null) 'keywords': keywords,
        if (contentUrl != null) 'contentUrl': contentUrl,
        if (neighboringContentUrls != null)
          'neighboringContentUrls': neighboringContentUrls,
        if (nonPersonalizedAds != null) 'nonPersonalizedAds': nonPersonalizedAds,
        if (extras != null) 'extras': extras,
      };

  /// Encodes this request as the JSON string the FFI layer transports.
  String encode() => jsonEncode(toJson());
}
