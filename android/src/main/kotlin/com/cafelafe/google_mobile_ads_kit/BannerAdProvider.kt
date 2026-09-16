package com.cafelafe.google_mobile_ads_kit

import android.view.View
import androidx.annotation.Keep
import com.dartnative.DNAndroidPluginProvider

/**
 * Supplies the native view behind a Dart [BannerAd].
 *
 * The reconciler hands a plugin exactly two hooks — `createView(Int)` and
 * `handleMutation(Long, Int, ByteArray)` — and no way to insert child views.
 * That is enough for a banner: the Mobile Ads SDK's `AdView` draws the whole ad
 * itself, so this returns one view and writes no layout. (A *native ad* would
 * need the app to build the layout; see `doc/design.md` §8.)
 *
 * ## Why createView takes no ad configuration
 *
 * `createView` receives only a view type, so it cannot know which ad unit the
 * view is for. The Dart element therefore calls `AdsBridge.bannerCreate` first,
 * filing the configuration under the view id the reconciler assigned; this
 * provider then hands back the container [AdsBridge] prepared for it.
 */
@Keep
class BannerAdProvider : DNAndroidPluginProvider {

    /**
     * Returns the container for the next banner the Dart side registered.
     *
     * The SDK's `AdView` is added to it once the ad loads, so the view exists
     * immediately and fills in later — the reconciler needs a view synchronously.
     */
    override fun createView(typeIndex: Int): View? {
        if (typeIndex != AdsBridge.bannerViewType) {
            // Not ours — and null is how that is said. DNPluginRegistry walks
            // the registered providers and takes the FIRST non-null result, so
            // returning a placeholder view here would swallow every other
            // plugin's view type, this package's own native ads included.
            return null
        }
        return AdsBridge.takePendingBannerContainer()
    }

    /**
     * Banners carry no per-view mutations yet — size is handled by Yoga via
     * `SetFlexAspectRatio`, which the reconciler applies itself.
     *
     * Note this is broadcast to *every* registered provider, so it must ignore
     * anything it does not recognise (`doc/design.md` §5-1).
     */
    override fun handleMutation(viewId: Long, eventTag: Int, data: ByteArray) {
    }
}
