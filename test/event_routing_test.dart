@TestOn('vm')
library;

import 'package:dartnative_mobile_ads/src/ads_ffi_bindings.dart';
import 'package:test/test.dart';

/// Exercises the token router without touching FFI.
///
/// `_deliver` is the seam every native event passes through, so these cover the
/// routing and payload-decoding rules that the native side depends on. The
/// symbol table itself needs a device and is covered by the example app.
void main() {
  group('event routing', () {
    test('delivers an event to the sink registered for its token', () {
      int? seenStatus;
      Map<String, Object?>? seenPayload;

      final int token = AdsFFIBindings.registerSink((int s, Map<String, Object?> p) {
        seenStatus = s;
        seenPayload = p;
      });
      addTearDown(() => AdsFFIBindings.release(token));

      deliverForTest(token, AdEventStatus.loaded, '{"responseId":"abc"}');

      expect(seenStatus, AdEventStatus.loaded);
      expect(seenPayload, <String, Object?>{'responseId': 'abc'});
    });

    test('gives each token its own sink', () {
      final List<String> calls = <String>[];

      final int first = AdsFFIBindings.registerSink((int s, Map<String, Object?> _) {
        calls.add('first:$s');
      });
      final int second = AdsFFIBindings.registerSink((int s, Map<String, Object?> _) {
        calls.add('second:$s');
      });
      addTearDown(() {
        AdsFFIBindings.release(first);
        AdsFFIBindings.release(second);
      });

      expect(first, isNot(second));

      deliverForTest(second, AdEventStatus.clicked, '');

      expect(calls, <String>['second:${AdEventStatus.clicked}']);
    });

    test('drops events for a released token', () {
      int calls = 0;
      final int token = AdsFFIBindings.registerSink((int _, Map<String, Object?> _) {
        calls++;
      });

      AdsFFIBindings.release(token);
      deliverForTest(token, AdEventStatus.dismissed, '');

      // A late event after dispose is normal — the SDK fires after the Dart
      // object is gone — and must not reach a disposed listener.
      expect(calls, 0);
    });

    test('treats an empty payload as an empty map', () {
      Map<String, Object?>? seen;
      final int token = AdsFFIBindings.registerSink((int _, Map<String, Object?> p) {
        seen = p;
      });
      addTearDown(() => AdsFFIBindings.release(token));

      deliverForTest(token, AdEventStatus.showed, '');

      expect(seen, isEmpty);
    });

    test('survives a malformed payload rather than throwing', () {
      // This runs on the native call stack, where an exception would cross the
      // FFI boundary and abort the process.
      Map<String, Object?>? seen;
      final int token = AdsFFIBindings.registerSink((int _, Map<String, Object?> p) {
        seen = p;
      });
      addTearDown(() => AdsFFIBindings.release(token));

      expect(
        () => deliverForTest(token, AdEventStatus.failedToLoad, 'not json{'),
        returnsNormally,
      );
      expect(seen, isEmpty);
    });

    test('ignores an event for a token that was never registered', () {
      expect(
        () => deliverForTest(999999, AdEventStatus.loaded, '{}'),
        returnsNormally,
      );
    });
  });
}
