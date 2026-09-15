/// Ad error types, mirroring `google_mobile_ads` so that error-handling code
/// ports across unchanged.
library;

/// An error reported by the Mobile Ads SDK.
///
/// The [code] and [domain] values come straight from the underlying native
/// SDK, so they differ between iOS and Android for the same logical failure.
/// Match on [code] only together with [domain].
class AdError {
  /// Creates an error with the given [code], [domain] and [message].
  const AdError(this.code, this.domain, this.message);

  /// The SDK-specific error code.
  ///
  /// On Android these are the `AdRequest.ERROR_CODE_*` constants; on iOS the
  /// `GADErrorCode` values. The numbering is not shared between platforms.
  final int code;

  /// The domain the error originated from.
  ///
  /// For example `com.google.android.gms.ads` on Android and
  /// `com.google.admob` on iOS.
  final String domain;

  /// A human-readable description of the failure, intended for logs.
  final String message;

  @override
  String toString() => 'AdError(code: $code, domain: $domain, message: $message)';
}

/// An error reported when an ad fails to load.
///
/// Extends [AdError] with the mediation [responseInfo], which identifies which
/// ad source was tried. `responseInfo` is null when the SDK did not report one.
class LoadAdError extends AdError {
  /// Creates a load error with the given [code], [domain], [message] and
  /// optional [responseInfo].
  const LoadAdError(super.code, super.domain, super.message, this.responseInfo);

  /// Information about the ad response that failed, when the SDK supplied it.
  final ResponseInfo? responseInfo;

  @override
  String toString() =>
      'LoadAdError(code: $code, domain: $domain, message: $message, '
      'responseInfo: $responseInfo)';
}

/// Information about an ad response, used for debugging mediation.
class ResponseInfo {
  /// Creates a response info record.
  const ResponseInfo({
    this.responseId,
    this.mediationAdapterClassName,
  });

  /// The response identifier, useful when reporting an issue to AdMob support.
  final String? responseId;

  /// The class name of the mediation adapter that supplied the ad.
  final String? mediationAdapterClassName;

  /// Builds a [ResponseInfo] from the JSON map sent by the native bridge.
  ///
  /// Returns null when [json] is null, so callers can pass an absent key
  /// through directly.
  static ResponseInfo? fromJson(Map<String, Object?>? json) {
    if (json == null) return null;
    return ResponseInfo(
      responseId: json['responseId'] as String?,
      mediationAdapterClassName: json['mediationAdapterClassName'] as String?,
    );
  }

  @override
  String toString() => 'ResponseInfo(responseId: $responseId, '
      'mediationAdapterClassName: $mediationAdapterClassName)';
}
