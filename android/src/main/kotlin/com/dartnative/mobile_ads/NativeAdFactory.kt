package com.dartnative.mobile_ads

import androidx.annotation.Keep
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAd
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdView

/**
 * Builds the view for a native ad that Dart requested with a `factoryId`.
 *
 * Implement this when the built-in templates are not enough. Your
 * implementation inflates a layout, fills in the ad's assets, points the
 * `NativeAdView` at each asset view, and calls `registerNativeAd` — the same
 * shape as the `NativeAdFactory` in Flutter's `google_mobile_ads`, so an
 * existing implementation ports across with only the import changed.
 *
 * ```kotlin
 * class MyNativeAdFactory(private val inflater: LayoutInflater) : NativeAdFactory {
 *     override fun createNativeAdView(
 *         nativeAd: NativeAd,
 *         customOptions: Map<String, Any?>,
 *     ): NativeAdView {
 *         val view = inflater.inflate(R.layout.my_native_ad, null) as NativeAdView
 *         val headline = view.findViewById<TextView>(R.id.headline)
 *         headline.text = nativeAd.headline
 *         view.headlineView = headline
 *         // ...the other assets...
 *         view.registerNativeAd(nativeAd, view.findViewById(R.id.media))
 *         return view
 *     }
 * }
 * ```
 *
 * Register it before any ad using it is requested — typically in your
 * Activity's `onCreate`:
 *
 * ```kotlin
 * DartNativeMobileAdsPlugin.registerNativeAdFactory(
 *     this, "adFactoryExample", MyNativeAdFactory(layoutInflater))
 * ```
 *
 * ## Two things you must do
 *
 * Both are AdMob policy, not plugin detail. The SDK handles clicks and measures
 * viewability through the registered views, so an ad that skips them may not be
 * clickable, may not record impressions, and can put the account at risk:
 *
 * 1. Assign every asset you display to its `NativeAdView` property
 *    (`headlineView`, `iconView`, `callToActionView`, …).
 * 2. Call `registerNativeAd` last, after those assignments.
 *
 * Called on the main thread. [createNativeAdView] must return a view
 * synchronously — do no I/O in it.
 */
@Keep
interface NativeAdFactory {
    /**
     * Returns a view displaying [nativeAd].
     *
     * [customOptions] is whatever the Dart side passed as `customOptions`,
     * decoded from JSON; empty when none was given. Values are the types JSON
     * produces — `String`, `Boolean`, `Int`/`Double`, `List`, `Map`.
     */
    fun createNativeAdView(
        nativeAd: NativeAd,
        customOptions: Map<String, Any?>,
    ): NativeAdView
}
