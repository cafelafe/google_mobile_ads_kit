/// SDK-wide initialization and settings.
library;

import 'dart:async';

import 'ads_ffi_bindings.dart';

/// The status of one mediation adapter after initialization.
class AdapterStatus {
  /// Creates an adapter status.
  const AdapterStatus({
    required this.state,
    required this.description,
    required this.latency,
  });

  /// Whether the adapter is ready to serve ads.
  final AdapterInitializationState state;

  /// A human-readable description of the adapter's state.
  final String description;

  /// How long the adapter took to initialize, in seconds.
  final double latency;

  @override
  String toString() =>
      'AdapterStatus(state: $state, description: $description, '
      'latency: $latency)';
}

/// Whether a mediation adapter finished initializing.
enum AdapterInitializationState {
  /// The adapter is not ready to serve ads.
  notReady,

  /// The adapter is ready to serve ads.
  ready,
}

/// The outcome of [MobileAds.initialize].
class InitializationStatus {
  /// Creates an initialization status from per-adapter results.
  const InitializationStatus(this.adapterStatuses);

  /// Each mediation adapter's state, keyed by adapter class name.
  ///
  /// Empty when no mediation adapters are configured, which is the usual case
  /// — this package does not support mediation yet (`doc/design.md` §1-3).
  final Map<String, AdapterStatus> adapterStatuses;

  @override
  String toString() => 'InitializationStatus($adapterStatuses)';
}

/// Entry point for SDK-wide operations.
///
/// Initialize the SDK once, early in `main`, before requesting any ad:
///
/// ```dart
/// void main() {
///   DartNativePluginRegistrant.registerAll();
///   MobileAds.instance.initialize();
///   runApp(const MyApp());
/// }
/// ```
///
/// Your AdMob App ID must be declared in the native projects — see the README.
/// Initialization fails with a descriptive error if it is missing.
class MobileAds {
  MobileAds._();

  /// The singleton instance.
  static final MobileAds instance = MobileAds._();

  Future<InitializationStatus>? _initialization;

  /// Initializes the Mobile Ads SDK.
  ///
  /// Safe to call more than once: later calls return the first call's future.
  /// The returned future completes once the SDK is ready; you may request ads
  /// without awaiting it, as the SDK queues requests made during startup.
  ///
  /// On Android the work happens on a background thread, because GMA Next-Gen's
  /// `MobileAds.initialize` triggers an ANR when called on the main thread
  /// (`doc/design.md` §6).
  ///
  /// On a platform without a Mobile Ads SDK this completes immediately with an
  /// empty status, so shared code runs unchanged on web and desktop.
  Future<InitializationStatus> initialize() {
    return _initialization ??= _doInitialize();
  }

  Future<InitializationStatus> _doInitialize() {
    AdsFFIBindings.loadSymbols();
    if (!AdsFFIBindings.isAvailable) {
      return Future<InitializationStatus>.value(
        const InitializationStatus(<String, AdapterStatus>{}),
      );
    }

    final Completer<InitializationStatus> completer =
        Completer<InitializationStatus>();
    late final int token;
    token = AdsFFIBindings.registerSink((int status, Map<String, Object?> p) {
      if (status != AdEventStatus.initialized) return;
      AdsFFIBindings.release(token);
      if (!completer.isCompleted) {
        completer.complete(_statusFromJson(p));
      }
    });

    AdsFFIBindings.initialize(token);
    return completer.future;
  }

  static InitializationStatus _statusFromJson(Map<String, Object?> json) {
    final Object? raw = json['adapterStatuses'];
    if (raw is! Map<String, Object?>) {
      return const InitializationStatus(<String, AdapterStatus>{});
    }
    final Map<String, AdapterStatus> statuses = <String, AdapterStatus>{};
    raw.forEach((String key, Object? value) {
      if (value is! Map<String, Object?>) return;
      statuses[key] = AdapterStatus(
        state: (value['state'] as int? ?? 0) == 1
            ? AdapterInitializationState.ready
            : AdapterInitializationState.notReady,
        description: value['description'] as String? ?? '',
        latency: (value['latency'] as num? ?? 0).toDouble(),
      );
    });
    return InitializationStatus(statuses);
  }

  /// Mutes or unmutes ad audio app-wide.
  ///
  /// Only affects ads that play audio. Per AdMob policy, do not mute ads to
  /// make them less noticeable — this exists so ads respect your app's own
  /// mute control.
  void setAppMuted(bool muted) {
    AdsFFIBindings.setAppMuted(muted);
  }
}
