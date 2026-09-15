package com.dartnative.mobile_ads

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.RatingBar
import android.widget.TextView
import com.google.android.libraries.ads.mobile.sdk.nativead.MediaView
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAd
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdView
import org.json.JSONObject

/**
 * Renders a native ad with one of the two built-in templates.
 *
 * The Next-Gen SDK ships no templates, so the layouts (`res/layout/
 * dn_native_ad_*.xml`) and this code belong to the plugin (doc/design.md §8-4).
 *
 * ## The part that is not optional
 *
 * AdMob requires each displayed asset to be registered with the `NativeAdView`
 * before `registerNativeAd` is called: the SDK attaches its click handlers and
 * viewability measurement to those views. Skipping a registration makes that
 * asset dead to the SDK — no clicks, no impression — so [render] assigns every
 * view it populates, and calls `registerNativeAd` last.
 */
internal object NativeAdRenderer {

    /** Mirrors `TemplateType` in lib/src/native_template_style.dart. */
    private const val TEMPLATE_SMALL = 0

    /** Mirrors `NativeTemplateFontStyle` in the same file. */
    private const val FONT_NORMAL = 0
    private const val FONT_BOLD = 1
    private const val FONT_ITALIC = 2
    private const val FONT_MONOSPACE = 3

    /**
     * Inflates a template for [ad] and binds its assets.
     *
     * [style] is the decoded `NativeTemplateStyle` JSON; anything absent from it
     * leaves the layout's own value alone.
     */
    fun render(context: Context, ad: NativeAd, style: JSONObject): NativeAdView {
        val templateType = style.optInt("templateType", TEMPLATE_SMALL)
        val layout = if (templateType == TEMPLATE_SMALL) {
            R.layout.dn_native_ad_small
        } else {
            R.layout.dn_native_ad_medium
        }

        val view = LayoutInflater.from(context)
            .inflate(layout, null) as NativeAdView

        bindAssets(view, ad)
        applyStyle(view, style)

        // Last, and only after every asset view is assigned above: this is what
        // hands the SDK the view tree it measures and attaches click handling to.
        view.registerNativeAd(ad, view.findViewById(R.id.dn_native_media))
        return view
    }

    /**
     * Fills in each asset and points the [view] at it.
     *
     * Assets are optional in a native ad — a creative may carry no icon, body or
     * rating — so anything missing is hidden rather than left blank. A hidden
     * view is still registered: the SDK tolerates that, and it keeps the
     * assignment in one place.
     */
    private fun bindAssets(view: NativeAdView, ad: NativeAd) {
        val headline = view.findViewById<TextView>(R.id.dn_native_headline)
        headline.text = ad.headline
        view.headlineView = headline

        bindText(view.findViewById(R.id.dn_native_body), ad.body) {
            view.bodyView = it
        }

        val cta = view.findViewById<Button>(R.id.dn_native_cta)
        bindText(cta, ad.callToAction) { view.callToActionView = it }

        val icon = view.findViewById<ImageView>(R.id.dn_native_icon)
        val iconDrawable = ad.icon?.drawable
        if (iconDrawable != null) {
            icon.setImageDrawable(iconDrawable)
            icon.visibility = View.VISIBLE
        } else {
            // Gone rather than invisible: the row should close up around the
            // missing icon instead of leaving a 48dp hole.
            icon.visibility = View.GONE
        }
        view.iconView = icon

        // The medium template only.
        view.findViewById<TextView>(R.id.dn_native_advertiser)?.let { advertiser ->
            bindText(advertiser, ad.advertiser) { view.advertiserView = it }
        }

        val rating = view.findViewById<RatingBar>(R.id.dn_native_rating)
        val stars = ad.starRating
        if (rating != null) {
            if (stars != null && stars > 0) {
                rating.rating = stars.toFloat()
                rating.visibility = View.VISIBLE
                view.starRatingView = rating
            } else {
                rating.visibility = View.GONE
            }
        }

        // MediaView is present in the medium template only, but registerNativeAd
        // needs one either way, so the small template's null is handled by the
        // caller passing findViewById's result straight through.
        view.findViewById<MediaView>(R.id.dn_native_media)?.let { media ->
            media.visibility =
                if (ad.mediaContent != null) View.VISIBLE else View.GONE
        }
    }

    /** Sets [text] on [target], hiding it when there is nothing to show. */
    private inline fun bindText(
        target: TextView?,
        text: String?,
        assign: (View) -> Unit,
    ) {
        if (target == null) return
        if (text.isNullOrEmpty()) {
            target.visibility = View.GONE
        } else {
            target.text = text
            target.visibility = View.VISIBLE
        }
        assign(target)
    }

    /** Applies the Dart-side [style] over the layout's defaults. */
    @SuppressLint("DiscouragedApi")
    private fun applyStyle(view: NativeAdView, style: JSONObject) {
        val background = view.findViewById<View>(R.id.dn_native_background)
        val cornerRadius = style.optDouble("cornerRadius", Double.NaN)

        if (style.has("mainBackgroundColor")) {
            val color = style.getInt("mainBackgroundColor")
            if (cornerRadius.isNaN()) {
                background.setBackgroundColor(color)
            } else {
                // A rounded background needs a drawable; a plain color cannot
                // carry a radius.
                background.background = GradientDrawable().apply {
                    setColor(color)
                    this.cornerRadius = dp(view, cornerRadius.toFloat())
                }
            }
        }

        applyTextStyle(
            view.findViewById(R.id.dn_native_headline),
            style.optJSONObject("primaryTextStyle"),
        )
        applyTextStyle(
            view.findViewById(R.id.dn_native_body),
            style.optJSONObject("secondaryTextStyle"),
        )
        applyTextStyle(
            view.findViewById(R.id.dn_native_advertiser),
            style.optJSONObject("tertiaryTextStyle"),
        )

        val cta = view.findViewById<Button>(R.id.dn_native_cta)
        val ctaStyle = style.optJSONObject("callToActionTextStyle")
        applyTextStyle(cta, ctaStyle)
        // The call to action's background is its own: the button is the one
        // element whose backgroundColor styles the button rather than the text.
        if (ctaStyle != null && ctaStyle.has("backgroundColor")) {
            val color = ctaStyle.getInt("backgroundColor")
            cta.background = GradientDrawable().apply {
                setColor(color)
                this.cornerRadius =
                    if (cornerRadius.isNaN()) 0f else dp(view, cornerRadius.toFloat())
            }
        }
    }

    private fun applyTextStyle(target: TextView?, style: JSONObject?) {
        if (target == null || style == null) return

        if (style.has("textColor")) target.setTextColor(style.getInt("textColor"))
        if (style.has("size")) {
            target.textSize = style.getDouble("size").toFloat()
        }
        // A Button's background is handled by the caller, so only non-buttons
        // take backgroundColor as a text background here.
        if (style.has("backgroundColor") && target !is Button) {
            target.setBackgroundColor(style.getInt("backgroundColor"))
        }
        if (style.has("style")) {
            when (style.getInt("style")) {
                FONT_BOLD -> target.setTypeface(null, Typeface.BOLD)
                FONT_ITALIC -> target.setTypeface(null, Typeface.ITALIC)
                FONT_MONOSPACE -> target.typeface = Typeface.MONOSPACE
                FONT_NORMAL -> target.setTypeface(null, Typeface.NORMAL)
            }
        }
    }

    private fun dp(view: View, value: Float): Float =
        value * view.resources.displayMetrics.density
}
