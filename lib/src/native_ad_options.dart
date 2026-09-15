/// Request-time options for native ads.
library;

/// The shape of media the ad request prefers.
///
/// A preference, not a guarantee: the SDK applies no restriction for
/// [MediaAspectRatio.unknown], and otherwise favours matching creatives.
enum MediaAspectRatio {
  /// No preference; applies no restriction.
  unknown,

  /// Any aspect ratio.
  any,

  /// Prefer landscape media.
  landscape,

  /// Prefer portrait media.
  portrait,

  /// Prefer roughly square media. Not a strict 1:1.
  square,
}

/// Where the AdChoices overlay sits within the ad.
enum AdChoicesPlacement {
  /// The top right corner. The SDK's default.
  topRightCorner,

  /// The top left corner.
  topLeftCorner,

  /// The bottom right corner.
  bottomRightCorner,

  /// The bottom left corner.
  bottomLeftCorner,
}

/// Video playback options for native ads that carry video media.
class VideoOptions {
  /// Creates video options. Every field is optional.
  const VideoOptions({
    this.clickToExpandRequested,
    this.customControlsRequested,
    this.startMuted,
  });

  /// Whether the video may expand when tapped.
  final bool? clickToExpandRequested;

  /// Whether your app supplies its own play/pause/mute controls.
  final bool? customControlsRequested;

  /// Whether the video starts muted. Defaults to true.
  final bool? startMuted;

  /// These options as the JSON the native side reads.
  Map<String, Object?> toJson() => <String, Object?>{
        if (clickToExpandRequested != null)
          'clickToExpandRequested': clickToExpandRequested,
        if (customControlsRequested != null)
          'customControlsRequested': customControlsRequested,
        if (startMuted != null) 'startMuted': startMuted,
      };

  @override
  bool operator ==(Object other) =>
      other is VideoOptions &&
      clickToExpandRequested == other.clickToExpandRequested &&
      customControlsRequested == other.customControlsRequested &&
      startMuted == other.startMuted;

  @override
  int get hashCode =>
      Object.hash(clickToExpandRequested, customControlsRequested, startMuted);
}

/// Options that further customize a native ad request.
///
/// ```dart
/// NativeAd(
///   adUnitId: ...,
///   nativeAdOptions: const NativeAdOptions(
///     mediaAspectRatio: MediaAspectRatio.landscape,
///     adChoicesPlacement: AdChoicesPlacement.topLeftCorner,
///   ),
///   ...
/// )
/// ```
class NativeAdOptions {
  /// Creates native ad options. Every field is optional.
  const NativeAdOptions({
    this.adChoicesPlacement,
    this.mediaAspectRatio,
    this.videoOptions,
    this.shouldReturnUrlsForImageAssets,
  });

  /// Where to place the AdChoices overlay. Defaults to the top right.
  final AdChoicesPlacement? adChoicesPlacement;

  /// The preferred media shape. Defaults to no restriction.
  final MediaAspectRatio? mediaAspectRatio;

  /// Playback options for video media.
  final VideoOptions? videoOptions;

  /// Whether to skip downloading image assets and return their URLs instead.
  ///
  /// Set this when your app fetches and caches the images itself. Defaults to
  /// false, in which case the SDK downloads them.
  ///
  /// Note this maps to the Next-Gen SDK's `disableImageDownloading()`, which
  /// only turns downloading *off* — passing false leaves the default in place
  /// rather than forcing it on.
  final bool? shouldReturnUrlsForImageAssets;

  /// These options as the JSON the native side reads.
  Map<String, Object?> toJson() => <String, Object?>{
        if (adChoicesPlacement != null)
          'adChoicesPlacement': adChoicesPlacement!.index,
        if (mediaAspectRatio != null)
          'mediaAspectRatio': mediaAspectRatio!.index,
        if (videoOptions != null) 'videoOptions': videoOptions!.toJson(),
        if (shouldReturnUrlsForImageAssets != null)
          'shouldReturnUrlsForImageAssets': shouldReturnUrlsForImageAssets,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeAdOptions &&
      adChoicesPlacement == other.adChoicesPlacement &&
      mediaAspectRatio == other.mediaAspectRatio &&
      videoOptions == other.videoOptions &&
      shouldReturnUrlsForImageAssets == other.shouldReturnUrlsForImageAssets;

  @override
  int get hashCode => Object.hash(
        adChoicesPlacement,
        mediaAspectRatio,
        videoOptions,
        shouldReturnUrlsForImageAssets,
      );
}
