// The two built-in native ad templates.
//
// Android inflates these from `res/layout/gmak_native_ad_*.xml`; iOS has no
// equivalent resource in a source-only pod, so the same two layouts are built
// in code here with Auto Layout. The structure and the default type sizes are
// deliberately kept in step with the XML so both platforms look alike
// (doc/design.md §8-4).
//
// ## The part that is not optional
//
// AdMob requires every displayed asset to be assigned to the matching
// `NativeAdView` property *before* `nativeAd` is set: that is when the SDK
// attaches its click handling and viewability measurement. An asset that is
// drawn but never assigned is dead to the SDK — no clicks, no impression — and
// will fail a policy review. So [GMAKNativeAdTemplate.render] assigns every view
// it populates and sets `nativeAd` last.

import Foundation
import GoogleMobileAds
import UIKit

/// Builds a `NativeAdView` for one of the built-in templates.
enum GMAKNativeAdTemplate {

  /// Mirrors `TemplateType` in lib/src/native_template_style.dart.
  private static let templateSmall = 0

  /// Mirrors `NativeTemplateFontStyle` in the same file.
  private enum FontStyle: Int {
    case normal = 0
    case bold = 1
    case italic = 2
    case monospace = 3
  }

  /// Renders [ad] with the template named in [style].
  ///
  /// [style] is the decoded `NativeTemplateStyle` JSON; anything absent leaves
  /// the template's own value alone.
  static func render(ad: NativeAd, style: [String: Any]) -> NativeAdView {
    let isSmall = (style["templateType"] as? Int ?? templateSmall) == templateSmall
    // The ad view keeps `translatesAutoresizingMaskIntoConstraints` on, so
    // GMAKAdContainer can frame it the same way it frames a banner. Turning it
    // off here would make both the frame assignment and the autoresizing mask
    // in GMAKNativeAd inert, leaving the view unconstrained — it would load and
    // draw nothing, which is the §8-7 symptom by another route. Everything
    // *inside* this view uses Auto Layout as normal.
    let adView = NativeAdView()

    let background = UIView()
    background.translatesAutoresizingMaskIntoConstraints = false
    adView.addSubview(background)
    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(equalTo: adView.leadingAnchor),
      background.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
      background.topAnchor.constraint(equalTo: adView.topAnchor),
      background.bottomAnchor.constraint(equalTo: adView.bottomAnchor),
    ])

    let assets = isSmall
      ? buildSmall(in: background, ad: ad, adView: adView)
      : buildMedium(in: background, ad: ad, adView: adView)

    applyStyle(style, background: background, assets: assets)

    // After styling, not before: `applyStyle` touches the call-to-action button,
    // and UIKit re-enables interaction on a UIButton when its appearance is
    // reconfigured.
    //
    // The SDK logs "User interactions must be disabled on the asset view" once
    // per ad regardless — it fires for the mere presence of a UIButton among
    // the assets, not because one is actually swallowing touches (verified:
    // nothing under `adView` but the media view and the containers on its path
    // is left interactive). Google's own native templates
    // have carried the same message since 2020 and the ads stay clickable. The
    // only way to silence it is to drop the UIButton for a UILabel, which would
    // cost the call to action its affordance.
    //
    // Everything except the media view, which needs touches for video controls
    // ("User interactions must be enabled on the GADMediaView view"). The
    // builders have already registered it on `adView`, so ask for it by name
    // rather than relying on a flag they set earlier that this sweep would
    // otherwise clear.
    let mediaView = adView.mediaView
    disableInteraction(in: adView, except: mediaView)
    mediaView?.isUserInteractionEnabled = true

    // Last, and only once every asset view above has been assigned: this is
    // what hands the SDK the tree it measures and attaches click handling to.
    adView.nativeAd = ad

    // Once more, because binding the ad is when the SDK inserts views of its
    // own — the AdChoices overlay in particular — and those land after the
    // sweep above. Re-running it is cheap and keeps the warning from coming
    // back through a view this code never created.
    disableInteraction(in: adView, except: mediaView)
    mediaView?.isUserInteractionEnabled = true

    return adView
  }

  /// The views a template built, so the styling pass can reach them.
  ///
  /// Every one is optional: a creative that carries no body, advertiser or
  /// rating gets no view for it, and the stack closes up instead.
  private struct Assets {
    var headline: UILabel?
    var body: UILabel?
    var advertiser: UILabel?
    var callToAction: UIButton
  }

  // MARK: - Small template

  /// Media, headline, body and a call to action on a single row.
  ///
  /// The leading square is a `MediaView`, not the icon. AdMob requires the main
  /// image or video asset to be rendered by a `MediaView` — a `UIImageView`
  /// there is an implementation issue the native ad validator flags, even in a
  /// compact layout. The icon is drawn only when there is no media to show.
  private static func buildSmall(
    in background: UIView,
    ad: NativeAd,
    adView: NativeAdView
  ) -> Assets {
    // The media view is always built and always on screen. Making it
    // conditional on `mediaContent` looking populated was wrong twice over: the
    // content can arrive after the view is built, and a MediaView that is
    // absent — or registered as nil — is reported by the SDK as a 0x0 media
    // view, which is the same demonetization risk as one that is too small.
    //
    // The icon is no longer a substitute for it; it is dropped from this
    // template entirely, because the row has room for one leading square and
    // AdMob requires that square to be the media.
    let media = MediaView()
    media.mediaContent = ad.mediaContent
    media.contentMode = .scaleAspectFill
    media.clipsToBounds = true

    // Registered as an asset but never drawn here — see above.
    let icon: UIImageView? = nil

    let headline = makeLabel(text: ad.headline, size: 15, weight: .bold)
    let body = makeLabel(text: ad.body, size: 13, weight: .regular)
    let rating = makeRatingView(ad)
    let cta = makeCallToAction(ad)

    let textColumn = UIStackView(arrangedSubviews: [headline, body, rating].compactMap { $0 })
    textColumn.axis = .vertical
    textColumn.alignment = .leading
    textColumn.spacing = 2

    let row = UIStackView(arrangedSubviews: [media, textColumn, cta])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(row)

    // Centred vertically, with the top and bottom only bounding it: the host
    // reserves the height (§8-6), so the row sits in the middle of whatever
    // space it is given rather than trying to define that height itself.
    //
    // The vertical bounds are deliberately NOT required. The container starts
    // at zero height — Yoga applies the reserved height from
    // `SetFlexAspectRatio` after the view is mounted, and the SDK measures the
    // media view in between. A required inset against a zero-height parent is
    // unsatisfiable, so Auto Layout breaks one of *our* constraints, and the one
    // it picked left the media at 0x0.
    let insetTop = row.topAnchor.constraint(
      greaterThanOrEqualTo: background.topAnchor, constant: 12)
    let insetBottom = row.bottomAnchor.constraint(
      lessThanOrEqualTo: background.bottomAnchor, constant: -12)
    insetTop.priority = .defaultHigh
    insetBottom.priority = .defaultHigh
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
      row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
      insetTop,
      insetBottom,
    ])
    // 48pt would satisfy the layout but not AdMob: a native *video* asset
    // requires the MediaView to be at least 120x120pt. The icon stand-in keeps
    // the compact 48pt square, since it is not the main asset.
    //
    // A square, deliberately: the media is cropped to fill it
    // (`.scaleAspectFill`) rather than given the creative's ratio, because this
    // row has one line's worth of height to work with. This square is why the
    // small template's default reservation is 144pt on iOS
    // (`NativeAd.defaultTemplateHeight`) where Android's icon-only row is 90.
    let side: CGFloat = 120
    let width = media.widthAnchor.constraint(equalToConstant: side)
    let height = media.heightAnchor.constraint(equalToConstant: side)
    width.priority = .required
    height.priority = .required
    NSLayoutConstraint.activate([width, height])
    // The call to action keeps its intrinsic width; the text column absorbs the
    // slack, so a long headline truncates instead of squeezing the button out.
    cta.setContentCompressionResistancePriority(.required, for: .horizontal)
    cta.setContentHuggingPriority(.required, for: .horizontal)

    assign(adView: adView, headline: headline, body: body, icon: icon, rating: rating, cta: cta)
    // Only when it is really on screen: registering a MediaView that is not in
    // the hierarchy is what the SDK complains about, not a missing one.
    adView.mediaView = media
    return Assets(headline: headline, body: body, advertiser: nil, callToAction: cta)
  }

  // MARK: - Medium template

  /// Adds the advertiser line and the media view below the header row.
  private static func buildMedium(
    in background: UIView,
    ad: NativeAd,
    adView: NativeAdView
  ) -> Assets {
    let icon = makeIconView(ad)
    let headline = makeLabel(text: ad.headline, size: 15, weight: .bold)
    let advertiser = makeLabel(text: ad.advertiser, size: 12, weight: .regular)
    let rating = makeRatingView(ad)
    let body = makeLabel(text: ad.body, size: 13, weight: .regular)
    let cta = makeCallToAction(ad)

    let headerText = UIStackView(
      arrangedSubviews: [headline, advertiser, rating].compactMap { $0 })
    headerText.axis = .vertical
    headerText.alignment = .leading
    headerText.spacing = 2

    let header = UIStackView(arrangedSubviews: [icon, headerText].compactMap { $0 })
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 12

    let mediaView = MediaView()
    mediaView.mediaContent = ad.mediaContent
    mediaView.contentMode = .scaleAspectFit

    let column = UIStackView(
      arrangedSubviews: [header, body, mediaView, cta].compactMap { $0 })
    column.axis = .vertical
    column.alignment = .fill
    column.spacing = 8
    column.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(column)

    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
      column.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
      column.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
      column.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
    ])
    if let icon = icon {
      NSLayoutConstraint.activate([
        icon.widthAnchor.constraint(equalToConstant: 40),
        icon.heightAnchor.constraint(equalToConstant: 40),
      ])
    }
    // A MediaView reports no intrinsic size, so without an explicit height it
    // collapses and the SDK logs "media view size has been detected to be WxH
    // ... too small". The column fixes the width, so the height follows from
    // the creative's own aspect ratio — never the other way round, or the ratio
    // fights the container and wins by shrinking (a 2.1 ratio once squeezed it
    // to 120x57).
    //
    // The media is what absorbs the slack, same as Android's `0dp` /
    // `layout_weight="1"`: the text and the call to action keep their natural
    // height, and the media takes whatever the reserved height leaves. Hence
    // the ratio sits at *low* priority and the text at just under required —
    // at equal priority (the default, 750 each) the stack squeezed the text
    // instead, and a 1.35 creative came out as a 250pt image over a 0pt body
    // and a 12pt button. Just under required rather than required so a
    // container reserved too short still shortens the text before the 120
    // floor below has to break.
    //
    // AdMob wants at least 120x120pt for a video asset, so a very wide creative
    // is floored rather than drawn as a letterbox strip (`doc/design.md` §8-6).
    for view in [header, body, cta].compactMap({ $0 }) {
      view.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
      view.setContentHuggingPriority(UILayoutPriority(999), for: .vertical)
    }
    let ratio = ad.mediaContent.aspectRatio
    let derived = mediaView.heightAnchor.constraint(
      equalTo: mediaView.widthAnchor,
      multiplier: 1.0 / (ratio > 0 ? ratio : 1.0))
    derived.priority = .defaultLow
    // Required, not merely high: a UIStackView distributes its arranged views
    // at required priority, so anything lower loses and the media is squeezed
    // (it came back as 120x106 against a 120 floor at .defaultHigh + 1).
    let floor = mediaView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
    floor.priority = .required
    NSLayoutConstraint.activate([derived, floor])

    assign(adView: adView, headline: headline, body: body, icon: icon, rating: rating, cta: cta)
    adView.advertiserView = advertiser
    adView.mediaView = mediaView

    return Assets(
      headline: headline, body: body, advertiser: advertiser, callToAction: cta)
  }

  /// Turns off user interaction across the whole ad view, sparing [exception].
  ///
  /// The SDK installs its own tap handling on the ad view, so any subview that
  /// consumes touches swallows the click. Walking the tree — rather than the
  /// list of registered assets — is what makes this reliable: a container the
  /// template happens to add is just as capable of eating the tap as a button.
  private static func disableInteraction(in view: UIView, except exception: UIView?) {
    for subview in view.subviews {
      if subview === exception { continue }
      // The AdChoices overlay is the user's route to ad settings and must stay
      // tappable; the SDK owns it and its subtree.
      if subview is AdChoicesView { continue }
      // The exception's own containers stay enabled too. Hit testing walks down
      // from the root and stops at the first disabled view, so a disabled
      // `background` or row would cut the media view off from every touch no
      // matter how the view itself is flagged — video playback and mute
      // controls would be dead. A plain container that gets a touch it has no
      // use for does not swallow it: the SDK's recogniser on the ad view still
      // sees the touch, so leaving these on costs nothing.
      let isAncestorOfException = exception.map { $0.isDescendant(of: subview) } ?? false
      if !isAncestorOfException { subview.isUserInteractionEnabled = false }
      disableInteraction(in: subview, except: exception)
    }
  }

  // MARK: - Asset registration

  /// Points the ad view at every asset the template drew.
  ///
  /// A hidden asset is still registered: the SDK tolerates that, and keeping
  /// the assignments in one place is what stops one being forgotten.
  private static func assign(
    adView: NativeAdView,
    headline: UILabel?,
    body: UILabel?,
    icon: UIImageView?,
    rating: UIView?,
    cta: UIButton
  ) {
    adView.headlineView = headline
    adView.bodyView = body
    adView.iconView = icon
    adView.starRatingView = rating
    adView.callToActionView = cta

    // Every asset view must let touches through: the SDK puts its own gesture
    // recognizer on the ad view and reports "User interactions must be disabled
    // on the asset view to enable click handling" for any that swallows them.
    // A UIButton is the obvious culprit, but this is a property of the whole
    // set, so disable it on all of them rather than the one that warned.
    for view in [headline, body, icon, rating, cta].compactMap({ $0 }) {
      view.isUserInteractionEnabled = false
    }
  }

  // MARK: - Asset views

  /// Returns a label, or nil when the asset is absent.
  ///
  /// Nil rather than an empty label so the stack view closes up around it,
  /// which is what Android's `View.GONE` does.
  private static func makeLabel(
    text: String?,
    size: CGFloat,
    weight: UIFont.Weight
  ) -> UILabel? {
    guard let text = text, !text.isEmpty else { return nil }
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: size, weight: weight)
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }

  private static func makeIconView(_ ad: NativeAd) -> UIImageView? {
    guard let image = ad.icon?.image else { return nil }
    let view = UIImageView(image: image)
    view.contentMode = .scaleAspectFit
    return view
  }

  /// A button whose intrinsic size includes its layout margins.
  ///
  /// `UIButton` sizes itself from the title alone, so with the padding
  /// expressed as margins (see [makeCallToAction]) it asked for 24pt less than
  /// the title needed and the small template's row truncated "インストール" to
  /// "インス…" — even at required compression resistance, since that only
  /// defends the intrinsic size, which was already too small.
  ///
  /// Sized from the title label rather than `super`, whose height already
  /// accounted for the margins while its width did not — adding the margins to
  /// both grew the button from 28pt to 40pt.
  private final class PaddedButton: UIButton {
    override var intrinsicContentSize: CGSize {
      guard let title = titleLabel else { return super.intrinsicContentSize }
      let text = title.intrinsicContentSize
      let margins = directionalLayoutMargins
      return CGSize(
        width: text.width + margins.leading + margins.trailing,
        height: text.height + margins.top + margins.bottom)
    }
  }

  private static func makeCallToAction(_ ad: NativeAd) -> UIButton {
    let button = PaddedButton(type: .system)
    button.setTitle(ad.callToAction, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 13)
    button.titleLabel?.lineBreakMode = .byTruncatingTail

    // Padding is expressed as a layout margin rather than with
    // `contentEdgeInsets` (deprecated from iOS 15) or a `UIButton.Configuration`
    // (iOS 15+, and it would take ownership of the title and colours, silently
    // defeating applyButtonStyle below). This works unchanged across the whole
    // iOS 13+ range the pod supports.
    button.contentMode = .center
    button.insetsLayoutMarginsFromSafeArea = false
    button.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 6, leading: 12, bottom: 6, trailing: 12)
    if let title = button.titleLabel {
      title.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: button.layoutMarginsGuide.leadingAnchor),
        title.trailingAnchor.constraint(equalTo: button.layoutMarginsGuide.trailingAnchor),
        title.topAnchor.constraint(equalTo: button.layoutMarginsGuide.topAnchor),
        title.bottomAnchor.constraint(equalTo: button.layoutMarginsGuide.bottomAnchor),
      ])
    }
    return button
  }

  /// Renders the star rating, or nil when the creative carries none.
  ///
  /// Drawn as text rather than with a control: UIKit has no rating view, and a
  /// row of star glyphs matches Android's small indicator closely enough.
  private static func makeRatingView(_ ad: NativeAd) -> UIView? {
    guard let rating = ad.starRating?.doubleValue, rating > 0 else { return nil }
    let label = UILabel()
    let filled = Int(rating.rounded())
    label.text = String(repeating: "★", count: min(filled, 5))
      + String(repeating: "☆", count: max(0, 5 - filled))
    label.font = .systemFont(ofSize: 12)
    label.textColor = .systemOrange
    return label
  }

  // MARK: - Styling

  /// Applies the Dart-side style over the template's defaults.
  private static func applyStyle(
    _ style: [String: Any],
    background: UIView,
    assets: Assets
  ) {
    let cornerRadius = style["cornerRadius"] as? Double

    if let color = style["mainBackgroundColor"] as? Int {
      background.backgroundColor = gmakColor(fromARGB: color)
    }
    if let radius = cornerRadius {
      background.layer.cornerRadius = CGFloat(radius)
      background.clipsToBounds = true
    }

    applyTextStyle(style["primaryTextStyle"] as? [String: Any], to: assets.headline)
    applyTextStyle(style["secondaryTextStyle"] as? [String: Any], to: assets.body)
    applyTextStyle(style["tertiaryTextStyle"] as? [String: Any], to: assets.advertiser)

    let ctaStyle = style["callToActionTextStyle"] as? [String: Any]
    applyButtonStyle(ctaStyle, to: assets.callToAction, cornerRadius: cornerRadius)
  }

  private static func applyTextStyle(_ style: [String: Any]?, to label: UILabel?) {
    guard let style = style, let label = label else { return }

    if let color = style["textColor"] as? Int {
      label.textColor = gmakColor(fromARGB: color)
    }
    if let color = style["backgroundColor"] as? Int {
      label.backgroundColor = gmakColor(fromARGB: color)
    }
    let size = (style["size"] as? Double).map { CGFloat($0) } ?? label.font.pointSize
    label.font = font(for: style["style"] as? Int, size: size)
  }

  /// Styles the call to action.
  ///
  /// The button is the one element whose `backgroundColor` colours the control
  /// rather than the text behind it — same rule as the Android renderer.
  private static func applyButtonStyle(
    _ style: [String: Any]?,
    to button: UIButton,
    cornerRadius: Double?
  ) {
    if let radius = cornerRadius {
      button.layer.cornerRadius = CGFloat(radius)
      button.clipsToBounds = true
    }
    guard let style = style else { return }

    if let color = style["textColor"] as? Int {
      button.setTitleColor(gmakColor(fromARGB: color), for: .normal)
    }
    if let color = style["backgroundColor"] as? Int {
      button.backgroundColor = gmakColor(fromARGB: color)
    }
    let size = (style["size"] as? Double).map { CGFloat($0) }
      ?? button.titleLabel?.font.pointSize ?? 13
    button.titleLabel?.font = font(for: style["style"] as? Int, size: size)
  }

  private static func font(for style: Int?, size: CGFloat) -> UIFont {
    switch FontStyle(rawValue: style ?? FontStyle.normal.rawValue) ?? .normal {
    case .bold:
      return .boldSystemFont(ofSize: size)
    case .italic:
      return .italicSystemFont(ofSize: size)
    case .monospace:
      return .monospacedSystemFont(ofSize: size, weight: .regular)
    case .normal:
      return .systemFont(ofSize: size)
    }
  }
}

/// Converts a 32-bit ARGB integer to a `UIColor`.
///
/// The Dart style types carry plain ints rather than `dart:ui` colors, so the
/// style stays usable without importing `dart:ui` (`doc/design.md` §2-2).
func gmakColor(fromARGB value: Int) -> UIColor {
  UIColor(
    red: CGFloat((value >> 16) & 0xFF) / 255.0,
    green: CGFloat((value >> 8) & 0xFF) / 255.0,
    blue: CGFloat(value & 0xFF) / 255.0,
    alpha: CGFloat((value >> 24) & 0xFF) / 255.0)
}
