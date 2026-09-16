@TestOn('vm')
library;

import 'package:google_mobile_ads_kit/src/ads_ffi_bindings.dart';
import 'package:test/test.dart';

/// Covers the startup path the generated plugin registrant runs.
///
/// `initializeMobileAdsPlugin()` itself cannot be tested here: it also registers
/// the banner element factory, which pulls in `package:dartnative` and so
/// `dart:ui`, and `dart:ui` does not exist on the VM the test runner uses.
/// What is testable — and what actually matters off-device — is that resolving
/// symbols is inert and repeatable on a platform with no Mobile Ads SDK.
void main() {
  test('loadSymbols is a harmless no-op off Android and iOS', () {
    expect(AdsFFIBindings.loadSymbols, returnsNormally);
    expect(AdsFFIBindings.loadSymbols, returnsNormally);
    expect(AdsFFIBindings.isAvailable, isFalse);
  });
}
