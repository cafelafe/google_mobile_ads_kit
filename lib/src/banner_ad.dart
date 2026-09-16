/// Banner ads.
///
/// A banner is one native `AdView` that the Mobile Ads SDK draws entirely on
/// its own — this plugin hands the reconciler a single view and writes no
/// layout of its own. (That is what separates a banner from a native ad, which
/// *does* require the app to build the layout; see `doc/design.md` §8.)
library;

import 'dart:async';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative/plugin.dart';

import 'ad_base.dart';
import 'ad_error.dart';
import 'ad_listener.dart';
import 'ad_request.dart';
import 'ad_size.dart';
import 'ads_ffi_bindings.dart';
import 'full_screen_ad.dart' show loadErrorFromJson;

/// The view type this plugin claims for its banners.
abstract final class _BannerViewType {
  /// Resolved on first access — `claim` is idempotent for a given key, so the
  /// Dart and native sides agree without either hard-coding a number.
  static final int banner = ViewType.claim('google_mobile_ads_kit/banner');
}

/// A banner ad, placed directly in the widget tree.
///
/// ```dart
/// BannerAd(
///   adUnitId: 'ca-app-pub-3940256099942544/6300978111',  // test unit
///   size: AdSize.banner,
///   request: const AdRequest(),
///   listener: BannerAdListener(
///     onAdLoaded: (ad) => debugPrint('loaded'),
///     onAdFailedToLoad: (ad, error) => debugPrint('failed: $error'),
///   ),
/// )
/// ```
///
/// Unlike `google_mobile_ads` there is **no `AdWidget` wrapper and no manual
/// `load()`**: DartNative mounts native views directly, so the ad is requested
/// when the widget mounts (`doc/design.md` §2-2).
///
/// For a banner that fills the available width, compute the size first:
///
/// ```dart
/// LayoutBuilder(
///   builder: (context, constraints) {
///     final size = AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
///       constraints.maxWidth.truncate(),
///     );
///     if (size == null) return const SizedBox.shrink();
///     return BannerAd(adUnitId: ..., size: size, listener: ...);
///   },
/// )
/// ```
///
/// ⚠️ Avoid placing banners in `FastList` / `FastGrid`. Those recycle for real,
/// so a cell scrolling out and back re-requests an ad — wasting inventory and
/// risking an invalid-traffic flag. Use `ScrollView` or `Column`
/// (`doc/design.md` §7-4).
class BannerAd extends StatefulWidget {
  /// Creates a banner for [adUnitId] at [size].
  const BannerAd({
    super.key,
    required this.adUnitId,
    required this.size,
    required this.listener,
    this.request = const AdRequest(),
  });

  /// The AdMob ad unit to request.
  final String adUnitId;

  /// The size to request, and the space the widget occupies.
  final AdSize size;

  /// Lifecycle callbacks for this banner.
  final BannerAdListener listener;

  /// Targeting information used to fetch the ad.
  final AdRequest request;

  @override
  State<BannerAd> createState() => _BannerAdState();
}

class _BannerAdState extends State<BannerAd> {
  @override
  Widget build(BuildContext context) {
    return _BannerAdView(
      adUnitId: widget.adUnitId,
      size: widget.size,
      listener: widget.listener,
      request: widget.request,
    );
  }
}

/// The leaf widget backed by a native view.
///
/// Only the leaf is registered with the reconciler; [BannerAd] is the public
/// wrapper. This two-layer split is the convention for DartNative plugins
/// (`doc/design.md` §7-1).
class _BannerAdView extends Widget {
  const _BannerAdView({
    required this.adUnitId,
    required this.size,
    required this.listener,
    required this.request,
  });

  final String adUnitId;
  final AdSize size;
  final BannerAdListener listener;
  final AdRequest request;
}

/// The banner's Dart-side handle, passed to the listener callbacks.
///
/// Mirrors `google_mobile_ads`, where the listener receives the `BannerAd`
/// object. Here the widget is immutable, so callbacks get this instead.
class _BannerAdHandle extends Ad {
  _BannerAdHandle({required super.adUnitId});
}

/// Hosts the native `AdView`.
class _BannerAdElement extends NativeElement {
  _BannerAdElement(_BannerAdView super.widget);

  _BannerAdView get _widget => widget as _BannerAdView;

  /// The FFI token this banner's events arrive on.
  int? _token;

  /// Bumped on every mount, so a deferred teardown can tell a permanent
  /// unmount from a list cell that was recycled straight back in.
  int _generation = 0;

  /// Handed to the listener so callbacks have an [Ad] to receive.
  late final _BannerAdHandle _handle =
      _BannerAdHandle(adUnitId: _widget.adUnitId);

  @override
  int get viewType => _BannerViewType.banner;

  @override
  ViewProps buildProps() => const ViewProps();

  /// Fills the parent's width when placed in a stack-flow parent, with the
  /// height following from the aspect ratio emitted in [mount].
  @override
  bool get stretchAsStackFlowChild => true;

  @override
  void mount(Element? parent, UIKitReconciler reconciler) {
    super.mount(parent, reconciler);

    _generation++;

    final int? id = viewId;
    if (id == null) return;

    AdsFFIBindings.loadSymbols();
    if (!AdsFFIBindings.isAvailable) {
      // Unsupported platform: report a failure so callers take their no-ad
      // path, and leave the (empty) view in place (design.md §1-2).
      _widget.listener.onAdFailedToLoad?.call(
        _handle,
        const LoadAdError(
          -1,
          'google_mobile_ads_kit',
          'The Mobile Ads SDK is not available on this platform.',
          null,
        ),
      );
      return;
    }

    // A plugin view cannot report an intrinsic size to Yoga, but a banner's
    // dimensions are known before the request goes out, so the ratio is enough
    // to reserve the right space (doc/design.md §7-3).
    final AdSize size = _widget.size;
    if (size.height > 0) {
      emitMutation(SetFlexAspectRatio(id, size.width / size.height));
    }

    _token = AdsFFIBindings.registerSink(_handleEvent);

    // Register the configuration before the reconciler builds the view:
    // createView receives only a view type, so everything else is filed under
    // the view id ahead of time.
    AdsFFIBindings.bannerCreate(
      token: _token!,
      viewId: id,
      adUnitId: _widget.adUnitId,
      requestJson: _widget.request.encode(),
      widthDp: size.width,
      heightDp: size.height,
    );
  }

  void _handleEvent(int status, Map<String, Object?> payload) {
    final BannerAdListener l = _widget.listener;
    switch (status) {
      case AdEventStatus.loaded:
        _handle.responseInfo =
            ResponseInfo.fromJson(payload['responseInfo'] as Map<String, Object?>?);
        l.onAdLoaded?.call(_handle);
      case AdEventStatus.failedToLoad:
        l.onAdFailedToLoad?.call(_handle, loadErrorFromJson(payload));
      case AdEventStatus.impression:
        l.onAdImpression?.call(_handle);
      case AdEventStatus.clicked:
        l.onAdClicked?.call(_handle);
      case AdEventStatus.opened:
        l.onAdOpened?.call(_handle);
      case AdEventStatus.closed:
        l.onAdClosed?.call(_handle);
      case AdEventStatus.paidEvent:
        l.onPaidEvent?.call(
          _handle,
          (payload['valueMicros'] as num? ?? 0).toDouble(),
          _precisionFromInt(payload['precision'] as int? ?? 0),
          payload['currencyCode'] as String? ?? '',
        );
    }
  }

  @override
  void update(Widget newWidget) {
    final _BannerAdView old = _widget;
    super.update(newWidget);
    final _BannerAdView now = _widget;

    // Re-emit only when the shape actually changed; the reconciler calls this
    // on every rebuild of the parent.
    final int? id = viewId;
    if (id != null && now.size != old.size && now.size.height > 0) {
      emitMutation(SetFlexAspectRatio(id, now.size.width / now.size.height));
    }
  }

  @override
  void unmount() {
    final int? t = _token;
    if (t != null) {
      AdsFFIBindings.release(t);
      _token = null;
    }

    // Destroying the AdView is deferred rather than done here. A recycled list
    // cell unmounts and remounts within the same frame, and tearing the ad down
    // on every pass would re-request it — wasted inventory and an
    // invalid-traffic risk (doc/design.md §7-4). Deciding one frame later
    // distinguishes a real teardown from recycling: if the element mounted
    // again, [_generation] has moved on and the destroy is skipped.
    final int viewIdAtUnmount = viewId ?? -1;
    final int generationAtUnmount = _generation;
    if (viewIdAtUnmount >= 0) {
      scheduleMicrotask(() {
        if (_generation != generationAtUnmount) return;
        AdsFFIBindings.bannerDispose(viewIdAtUnmount);
      });
    }

    super.unmount();
  }
}

PrecisionType _precisionFromInt(int value) =>
    value >= 0 && value < PrecisionType.values.length
        ? PrecisionType.values[value]
        : PrecisionType.unknown;

/// Registers the banner element factory.
///
/// Called from `initializeMobileAdsPlugin()`; apps do not call this directly.
void registerBannerAdElementFactory() {
  DartNativeReconciler.registerElementFactory<_BannerAdView>(
    (_BannerAdView w) => _BannerAdElement(w),
  );
}
