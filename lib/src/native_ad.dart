/// Native ads.
///
/// Unlike a banner, a native ad's layout is built by the *app*, not the SDK:
/// AdMob requires each asset view to be registered with a `NativeAdView` so it
/// can handle clicks and measure viewability. That registration cannot happen
/// from Dart — the reconciler gives a plugin one leaf view and no way to insert
/// children into it — so the layout is built natively, by one of two routes
/// (`doc/design.md` §8-2):
///
/// * a **built-in template**, styled from Dart via [NativeTemplateStyle];
/// * a **factory** you register natively and name here with `factoryId`.
///
/// Note the constraint is on the Dart→native direction only. `NativeAdView` is
/// a `FrameLayout` subclass, so the native side is free to build a whole tree
/// inside it; both routes do exactly that.
library;

import 'dart:async';

import 'package:dartnative/dartnative.dart';
import 'package:dartnative/plugin.dart';

import 'ad_base.dart';
import 'ad_error.dart';
import 'ad_listener.dart';
import 'ad_request.dart';
import 'ads_ffi_bindings.dart';
import 'full_screen_ad.dart' show loadErrorFromJson;
import 'native_ad_options.dart';
import 'native_template_style.dart';

/// The view type this plugin claims for its native ads.
abstract final class _NativeViewType {
  /// Resolved on first access — `claim` is idempotent for a given key, so the
  /// Dart and native sides agree without either hard-coding a number.
  static final int nativeAd = ViewType.claim('dartnative_mobile_ads/native');
}

/// A native ad, placed directly in the widget tree.
///
/// Exactly one of [nativeTemplateStyle] and [factoryId] must be given.
///
/// ## With a built-in template
///
/// ```dart
/// NativeAd(
///   adUnitId: 'ca-app-pub-3940256099942544/2247696110',  // test unit
///   nativeTemplateStyle: const NativeTemplateStyle(
///     templateType: TemplateType.medium,
///   ),
///   listener: NativeAdListener(
///     onAdLoaded: (ad) => debugPrint('loaded'),
///   ),
/// )
/// ```
///
/// ## With your own layout
///
/// Register a factory natively, then name it here. On Android, in
/// `MainActivity`:
///
/// ```kotlin
/// DartNativeMobileAdsPlugin.registerNativeAdFactory(
///   this, "adFactoryExample", MyNativeAdFactory(layoutInflater))
/// ```
///
/// ```dart
/// NativeAd(
///   adUnitId: ...,
///   factoryId: 'adFactoryExample',
///   height: 120,
///   listener: NativeAdListener(),
/// )
/// ```
///
/// The registration call differs from `google_mobile_ads` only in taking a
/// `Context` where Flutter takes a `FlutterEngine`; the factory itself and the
/// Dart call above are unchanged (`doc/design.md` §8-5).
///
/// ⚠️ Avoid placing native ads in `FastList` / `FastGrid`, for the same reason
/// as banners: those recycle for real, so a cell scrolling out and back
/// re-requests an ad (`doc/design.md` §7-4).
class NativeAd extends StatefulWidget {
  /// Creates a native ad for [adUnitId].
  ///
  /// Provide either [nativeTemplateStyle] (to use a built-in layout) or
  /// [factoryId] (to use one you registered natively) — not neither.
  const NativeAd({
    super.key,
    required this.adUnitId,
    required this.listener,
    this.factoryId,
    this.nativeTemplateStyle,
    this.request = const AdRequest(),
    this.nativeAdOptions,
    this.customOptions,
    this.height,
  }) : assert(
          nativeTemplateStyle != null || factoryId != null,
          'Provide either nativeTemplateStyle or factoryId.',
        );

  /// The AdMob ad unit to request.
  final String adUnitId;

  /// Lifecycle callbacks for this ad.
  final NativeAdListener listener;

  /// Names a factory registered on the native side.
  ///
  /// Ignored when [nativeTemplateStyle] is also set.
  final String? factoryId;

  /// Renders the ad with a built-in template in this style.
  ///
  /// Takes precedence over [factoryId].
  final NativeTemplateStyle? nativeTemplateStyle;

  /// Targeting information used to fetch the ad.
  final AdRequest request;

  /// Options applied to the ad request itself.
  final NativeAdOptions? nativeAdOptions;

  /// Arbitrary data passed through to your native factory.
  ///
  /// Ignored when using a template. Values must survive JSON encoding.
  final Map<String, Object?>? customOptions;

  /// The height to reserve, in logical pixels.
  ///
  /// A native ad's height is not known before it loads — it depends on the
  /// creative — so unlike a banner it cannot be derived (`doc/design.md` §8-6).
  /// Defaults to [defaultTemplateHeight] for the chosen template; **required in
  /// practice when using [factoryId]**, since only you know how tall your
  /// layout is.
  final double? height;

  /// The height the built-in templates are laid out for, in logical pixels.
  ///
  /// [TemplateType.small] is a single row; [TemplateType.medium] adds the ad's
  /// media above it.
  static double defaultTemplateHeight(TemplateType type) =>
      switch (type) { TemplateType.small => 90, TemplateType.medium => 350 };

  /// The height this ad will occupy, resolving the defaults described on
  /// [height].
  double get resolvedHeight {
    final double? explicit = height;
    if (explicit != null) return explicit;
    final NativeTemplateStyle? style = nativeTemplateStyle;
    if (style != null) return defaultTemplateHeight(style.templateType);
    // A factory with no height given: reserve the small-template height rather
    // than collapsing to zero, which would make the ad invisible and
    // unmeasurable.
    return defaultTemplateHeight(TemplateType.small);
  }

  @override
  State<NativeAd> createState() => _NativeAdState();
}

class _NativeAdState extends State<NativeAd> {
  @override
  Widget build(BuildContext context) {
    // The width is needed only to turn the known height into the aspect ratio
    // Yoga is given: SetFlexAspectRatio is the one sizing mutation a plugin may
    // emit, and a plugin view reports no intrinsic size of its own
    // (doc/design.md §8-6).
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        return _NativeAdView(
          adUnitId: widget.adUnitId,
          listener: widget.listener,
          factoryId: widget.factoryId,
          templateStyle: widget.nativeTemplateStyle,
          request: widget.request,
          options: widget.nativeAdOptions,
          customOptions: widget.customOptions,
          height: widget.resolvedHeight,
          width: width,
        );
      },
    );
  }
}

/// The leaf widget backed by a native view.
///
/// Only the leaf is registered with the reconciler; [NativeAd] is the public
/// wrapper. Same two-layer split as banners (`doc/design.md` §7-1).
class _NativeAdView extends Widget {
  const _NativeAdView({
    required this.adUnitId,
    required this.listener,
    required this.factoryId,
    required this.templateStyle,
    required this.request,
    required this.options,
    required this.customOptions,
    required this.height,
    required this.width,
  });

  final String adUnitId;
  final NativeAdListener listener;
  final String? factoryId;
  final NativeTemplateStyle? templateStyle;
  final AdRequest request;
  final NativeAdOptions? options;
  final Map<String, Object?>? customOptions;
  final double height;
  final double width;
}

/// The ad's Dart-side handle, passed to the listener callbacks.
class _NativeAdHandle extends Ad {
  _NativeAdHandle({required super.adUnitId});
}

/// Hosts the native `NativeAdView`.
class _NativeAdElement extends NativeElement {
  _NativeAdElement(_NativeAdView super.widget);

  _NativeAdView get _widget => widget as _NativeAdView;

  /// The FFI token this ad's events arrive on.
  int? _token;

  /// Bumped on every mount, so a deferred teardown can tell a permanent
  /// unmount from a list cell that was recycled straight back in.
  int _generation = 0;

  late final _NativeAdHandle _handle =
      _NativeAdHandle(adUnitId: _widget.adUnitId);

  @override
  int get viewType => _NativeViewType.nativeAd;

  @override
  ViewProps buildProps() => const ViewProps();

  /// Fills the parent's width; the height comes from the `SizedBox` that
  /// [NativeAd] wraps this in.
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
          'dartnative_mobile_ads',
          'The Mobile Ads SDK is not available on this platform.',
          null,
        ),
      );
      return;
    }

    // A plugin view reports no intrinsic size to Yoga, so without this the
    // native view measures zero and nothing is drawn — wrapping the widget in a
    // SizedBox is not enough, because that sizes the Dart-side box and not the
    // view inside it. A native ad's height is not derivable the way a banner's
    // is, so it comes from [NativeAd.resolvedHeight] (doc/design.md §8-6).
    if (_widget.height > 0 && _widget.width > 0) {
      emitMutation(SetFlexAspectRatio(id, _widget.width / _widget.height));
    }

    _token = AdsFFIBindings.registerSink(_handleEvent);

    // Register the configuration before the reconciler builds the view:
    // createView receives only a view type, so everything else is filed under
    // the view id ahead of time (same as banners, design.md §7-5).
    AdsFFIBindings.nativeAdCreate(
      token: _token!,
      viewId: id,
      adUnitId: _widget.adUnitId,
      requestJson: _widget.request.encode(),
      optionsJson: _encodeOptions(),
    );
  }

  /// Everything that is not targeting: which renderer to use, and its config.
  String _encodeOptions() {
    final NativeTemplateStyle? style = _widget.templateStyle;
    return AdsFFIBindings.encodeJson(<String, Object?>{
      if (style != null) 'templateStyle': style.toJson(),
      if (style == null && _widget.factoryId != null)
        'factoryId': _widget.factoryId,
      if (_widget.options != null) 'nativeAdOptions': _widget.options!.toJson(),
      if (_widget.customOptions != null)
        'customOptions': _widget.customOptions,
    });
  }

  void _handleEvent(int status, Map<String, Object?> payload) {
    final NativeAdListener l = _widget.listener;
    switch (status) {
      case AdEventStatus.loaded:
        _handle.responseInfo = ResponseInfo.fromJson(
            payload['responseInfo'] as Map<String, Object?>?);
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
    final _NativeAdView old = _widget;
    super.update(newWidget);
    final _NativeAdView now = _widget;

    // Re-emit only when the shape actually changed; the reconciler calls this
    // on every rebuild of the parent.
    final int? id = viewId;
    if (id != null &&
        (now.width != old.width || now.height != old.height) &&
        now.width > 0 &&
        now.height > 0) {
      emitMutation(SetFlexAspectRatio(id, now.width / now.height));
    }
  }

  @override
  void unmount() {
    final int? t = _token;
    if (t != null) {
      AdsFFIBindings.release(t);
      _token = null;
    }

    // Deferred for the same reason as banners: a recycled list cell unmounts
    // and remounts within the same frame, and tearing the ad down on every pass
    // would re-request it (doc/design.md §7-4). If the element mounted again,
    // [_generation] has moved on and the destroy is skipped.
    final int viewIdAtUnmount = viewId ?? -1;
    final int generationAtUnmount = _generation;
    if (viewIdAtUnmount >= 0) {
      scheduleMicrotask(() {
        if (_generation != generationAtUnmount) return;
        AdsFFIBindings.nativeAdDispose(viewIdAtUnmount);
      });
    }

    super.unmount();
  }
}

PrecisionType _precisionFromInt(int value) =>
    value >= 0 && value < PrecisionType.values.length
        ? PrecisionType.values[value]
        : PrecisionType.unknown;

/// Registers the native ad element factory.
///
/// Called from `initializeMobileAdsPlugin()`; apps do not call this directly.
void registerNativeAdElementFactory() {
  DartNativeReconciler.registerElementFactory<_NativeAdView>(
    (_NativeAdView w) => _NativeAdElement(w),
  );
}
