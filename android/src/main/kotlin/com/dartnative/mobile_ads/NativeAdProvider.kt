package com.dartnative.mobile_ads

import android.view.View
import androidx.annotation.Keep
import com.dartnative.DNAndroidPluginProvider

/**
 * Supplies the native view behind a Dart [NativeAd].
 *
 * Structurally identical to [BannerAdProvider] — the reconciler's contract is
 * the same — but what goes *inside* the container differs: a banner's `AdView`
 * is drawn by the SDK, while a native ad's view is built here, either from a
 * built-in template or by an app-registered [NativeAdFactory]
 * (`doc/design.md` §8-2).
 *
 * The "cannot insert child views" limit applies to the Dart→native direction
 * only, so building that tree natively is fine: `NativeAdView` is a
 * `FrameLayout` subclass and this code is on the native side of the boundary.
 */
@Keep
class NativeAdProvider : DNAndroidPluginProvider {

    /**
     * Returns the container for the next native ad the Dart side registered.
     *
     * Empty at first: the reconciler needs a view synchronously, and the ad's
     * own view only exists once the request comes back.
     */
    override fun createView(typeIndex: Int): View? {
        if (typeIndex != AdsBridge.nativeAdViewType) {
            // Not ours — see the note in BannerAdProvider: the registry takes
            // the first non-null result, so anything but null here would
            // hijack other view types.
            return null
        }
        return AdsBridge.takePendingNativeContainer()
    }

    /**
     * Native ads carry no per-view mutations: the template style and options are
     * fixed at request time, since re-styling a live ad would mean re-registering
     * its asset views with the SDK.
     *
     * Note this is broadcast to *every* registered provider, so it must ignore
     * anything it does not recognise (`doc/design.md` §5-1).
     */
    override fun handleMutation(viewId: Long, eventTag: Int, data: ByteArray) {
    }
}
