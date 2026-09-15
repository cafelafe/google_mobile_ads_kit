/// Banner ad sizes.
library;

import 'dart:async';

import 'ads_ffi_bindings.dart';

/// The size of a banner ad, in density-independent pixels.
///
/// Use one of the constants for a fixed size, or
/// [getCurrentOrientationAnchoredAdaptiveBannerAdSize] for a banner that fills
/// the available width with a Google-optimized height.
class AdSize {
  /// Constructs an [AdSize] with the given [width] and [height].
  const AdSize({required this.width, required this.height});

  /// The horizontal span of an ad.
  final int width;

  /// The vertical span of an ad.
  final int height;

  /// The standard banner (320x50) size.
  static const AdSize banner = AdSize(width: 320, height: 50);

  /// The large banner (320x100) size.
  static const AdSize largeBanner = AdSize(width: 320, height: 100);

  /// The medium rectangle (300x250) size.
  static const AdSize mediumRectangle = AdSize(width: 300, height: 250);

  /// The full banner (468x60) size.
  static const AdSize fullBanner = AdSize(width: 468, height: 60);

  /// The leaderboard (728x90) size.
  static const AdSize leaderboard = AdSize(width: 728, height: 90);

  /// Returns an [AdSize] spanning [width] with a Google-optimized height.
  ///
  /// Suitable for anchoring near the top or bottom of the screen. The height is
  /// never more than 15% of the screen height and never less than 50, and is
  /// stable for a given width and device, so it can be computed before the
  /// request goes out.
  ///
  /// Returns null when no suitable height exists, or off Android and iOS.
  ///
  /// Get the width from a `LayoutBuilder`, so the ad is sized to the space it
  /// will actually occupy:
  ///
  /// ```dart
  /// LayoutBuilder(
  ///   builder: (context, constraints) {
  ///     final size = AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
  ///       constraints.maxWidth.truncate(),
  ///     );
  ///     // ...
  ///   },
  /// )
  /// ```
  ///
  /// Unlike `google_mobile_ads` this is synchronous — the underlying call is a
  /// pure calculation, and FFI has no async mode, so there is nothing to await
  /// (`doc/design.md` §2-2). [getAnchoredAdaptiveBannerAdSize] is the
  /// `Future`-returning form for code ported from Flutter.
  static AnchoredAdaptiveBannerAdSize?
      getCurrentOrientationAnchoredAdaptiveBannerAdSize(int width) {
    AdsFFIBindings.loadSymbols();
    if (!AdsFFIBindings.isAvailable) return null;

    final int height = AdsFFIBindings.adaptiveBannerHeight(width);
    if (height <= 0) return null;
    return AnchoredAdaptiveBannerAdSize(width: width, height: height);
  }

  /// The `Future`-returning form of
  /// [getCurrentOrientationAnchoredAdaptiveBannerAdSize].
  ///
  /// Provided so code ported from `google_mobile_ads` compiles unchanged; it
  /// completes immediately.
  static Future<AnchoredAdaptiveBannerAdSize?> getAnchoredAdaptiveBannerAdSize(
    int width,
  ) =>
      Future<AnchoredAdaptiveBannerAdSize?>.value(
        getCurrentOrientationAnchoredAdaptiveBannerAdSize(width),
      );

  @override
  bool operator ==(Object other) =>
      other is AdSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'AdSize(width: $width, height: $height)';
}

/// An [AdSize] whose height was chosen by the SDK for a given width.
class AnchoredAdaptiveBannerAdSize extends AdSize {
  /// Creates an adaptive size. Obtained from
  /// [AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize].
  const AnchoredAdaptiveBannerAdSize({
    required super.width,
    required super.height,
  });
}
