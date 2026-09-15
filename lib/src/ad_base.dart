/// The base class shared by every ad object.
library;

import 'dart:async';

import 'ad_error.dart';
import 'ads_ffi_bindings.dart';

/// Base class for all ads.
///
/// Holds the [adUnitId] and the native handle. Subclasses add the behaviour for
/// their format. Always [dispose] an ad you are finished with: the native ad
/// object is not reclaimed until you do.
abstract class Ad {
  /// Creates an ad for [adUnitId].
  Ad({required this.adUnitId, this.responseInfo});

  /// The AdMob ad unit this ad was requested for.
  final String adUnitId;

  /// Information about the loaded request, for debugging and logging.
  ///
  /// Only present once the ad has loaded successfully.
  ResponseInfo? responseInfo;

  /// The handle identifying this ad's native counterpart.
  ///
  /// Assigned when the load is issued; null before that and after [dispose].
  int? token;

  /// Whether this ad still holds a native object.
  bool get isDisposed => token == null;

  /// Frees the native resources associated with this ad.
  ///
  /// After this the ad cannot be shown again; load a new one. Calling this more
  /// than once is safe.
  ///
  /// Returns a [Future] to match `google_mobile_ads`, so that `await ad.dispose()`
  /// ports unchanged. The work itself is synchronous — FFI has no other mode —
  /// so the future is already complete when you get it.
  Future<void> dispose() {
    final int? t = token;
    if (t == null) return Future<void>.value();
    token = null;
    AdsFFIBindings.disposeAd(t);
    return Future<void>.value();
  }
}
