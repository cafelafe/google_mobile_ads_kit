/// Styling for the built-in native ad templates.
///
/// These describe the *small* and *medium* layouts this plugin ships, not
/// anything the Mobile Ads SDK provides: the Next-Gen SDK has no template
/// support of its own, so the layouts and the code that styles them live here
/// (`doc/design.md` §8-4).
library;

/// How text in a native template is weighted.
enum NativeTemplateFontStyle {
  /// The platform's default text style.
  normal,

  /// Bold text.
  bold,

  /// Italic text.
  italic,

  /// A monospaced face.
  monospace,
}

/// Which built-in layout a [NativeTemplateStyle] applies to.
enum TemplateType {
  /// A compact layout: icon, headline, one line of body, call to action.
  ///
  /// About 90dp tall — see [NativeAd.defaultTemplateHeight].
  small,

  /// A taller layout that also shows the ad's media (image or video).
  ///
  /// About 350dp tall — see [NativeAd.defaultTemplateHeight].
  medium,
}

/// Colors and typography for one text element of a native template.
///
/// Every field is optional; anything left null keeps the template's default.
class NativeTemplateTextStyle {
  /// Creates a text style. Every field is optional.
  const NativeTemplateTextStyle({
    this.textColor,
    this.backgroundColor,
    this.style,
    this.size,
  });

  /// The text color, as a 32-bit ARGB value.
  ///
  /// Given as an `int` rather than a `Color` so that this library does not
  /// depend on `dart:ui`, which keeps it usable from tests and from code that
  /// runs off-device.
  final int? textColor;

  /// The background color behind the text, as a 32-bit ARGB value.
  final int? backgroundColor;

  /// The weight or face to draw the text with.
  final NativeTemplateFontStyle? style;

  /// The text size, in scale-independent pixels.
  final double? size;

  /// This style as the JSON the native side reads.
  ///
  /// Keys are omitted when null so the native side can tell "unset" from an
  /// explicit value, and leave its own default in place.
  Map<String, Object?> toJson() => <String, Object?>{
        if (textColor != null) 'textColor': textColor,
        if (backgroundColor != null) 'backgroundColor': backgroundColor,
        if (style != null) 'style': style!.index,
        if (size != null) 'size': size,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeTemplateTextStyle &&
      textColor == other.textColor &&
      backgroundColor == other.backgroundColor &&
      style == other.style &&
      size == other.size;

  @override
  int get hashCode => Object.hash(textColor, backgroundColor, style, size);
}

/// Styling for a native ad rendered with one of the built-in templates.
///
/// Pass this to [NativeAd] instead of a `factoryId` to get a ready-made layout:
///
/// ```dart
/// NativeAd(
///   adUnitId: 'ca-app-pub-3940256099942544/2247696110',  // test unit
///   nativeTemplateStyle: NativeTemplateStyle(
///     templateType: TemplateType.medium,
///     mainBackgroundColor: 0xFFFFFFFF,
///     callToActionTextStyle: NativeTemplateTextStyle(textColor: 0xFFFFFFFF),
///   ),
///   listener: NativeAdListener(),
/// )
/// ```
class NativeTemplateStyle {
  /// Creates a template style. Only [templateType] is required.
  const NativeTemplateStyle({
    required this.templateType,
    this.callToActionTextStyle,
    this.primaryTextStyle,
    this.secondaryTextStyle,
    this.tertiaryTextStyle,
    this.mainBackgroundColor,
    this.cornerRadius,
  });

  /// Which built-in layout to render.
  final TemplateType templateType;

  /// The style of the call-to-action button's label.
  final NativeTemplateTextStyle? callToActionTextStyle;

  /// The style of the headline.
  final NativeTemplateTextStyle? primaryTextStyle;

  /// The style of the second row, which holds the body or the star rating.
  final NativeTemplateTextStyle? secondaryTextStyle;

  /// The style of the third row, which holds the store name or advertiser.
  final NativeTemplateTextStyle? tertiaryTextStyle;

  /// The template's background color, as a 32-bit ARGB value.
  final int? mainBackgroundColor;

  /// The corner radius applied to the icon and the call-to-action button.
  final double? cornerRadius;

  /// This style as the JSON the native side reads.
  Map<String, Object?> toJson() => <String, Object?>{
        'templateType': templateType.index,
        if (callToActionTextStyle != null)
          'callToActionTextStyle': callToActionTextStyle!.toJson(),
        if (primaryTextStyle != null)
          'primaryTextStyle': primaryTextStyle!.toJson(),
        if (secondaryTextStyle != null)
          'secondaryTextStyle': secondaryTextStyle!.toJson(),
        if (tertiaryTextStyle != null)
          'tertiaryTextStyle': tertiaryTextStyle!.toJson(),
        if (mainBackgroundColor != null)
          'mainBackgroundColor': mainBackgroundColor,
        if (cornerRadius != null) 'cornerRadius': cornerRadius,
      };

  @override
  bool operator ==(Object other) =>
      other is NativeTemplateStyle &&
      templateType == other.templateType &&
      callToActionTextStyle == other.callToActionTextStyle &&
      primaryTextStyle == other.primaryTextStyle &&
      secondaryTextStyle == other.secondaryTextStyle &&
      tertiaryTextStyle == other.tertiaryTextStyle &&
      mainBackgroundColor == other.mainBackgroundColor &&
      cornerRadius == other.cornerRadius;

  @override
  int get hashCode => Object.hash(
        templateType,
        callToActionTextStyle,
        primaryTextStyle,
        secondaryTextStyle,
        tertiaryTextStyle,
        mainBackgroundColor,
        cornerRadius,
      );
}
