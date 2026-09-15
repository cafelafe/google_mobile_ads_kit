package com.dartnative.mobile_ads

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.view.Gravity
import android.widget.FrameLayout
import android.os.Looper
import androidx.annotation.Keep
import com.dartnative.DNNavigator
import com.dartnative.DNPluginRegistry
import com.dartnative.DNViewRegistry
import com.google.android.libraries.ads.mobile.sdk.MobileAds
import com.google.android.libraries.ads.mobile.sdk.appopen.AppOpenAd
import com.google.android.libraries.ads.mobile.sdk.appopen.AppOpenAdEventCallback
import com.google.android.libraries.ads.mobile.sdk.appopen.AppOpenAdPreloader
import com.google.android.libraries.ads.mobile.sdk.banner.AdSize
import com.google.android.libraries.ads.mobile.sdk.banner.AdView
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAd
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAdEventCallback
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAdRequest
import com.google.android.libraries.ads.mobile.sdk.common.AdChoicesPlacement
import com.google.android.libraries.ads.mobile.sdk.common.AdLoadCallback
import com.google.android.libraries.ads.mobile.sdk.common.AdRequest
import com.google.android.libraries.ads.mobile.sdk.common.AdValue
import com.google.android.libraries.ads.mobile.sdk.common.BaseAdRequestBuilder
import com.google.android.libraries.ads.mobile.sdk.common.FullScreenContentError
import com.google.android.libraries.ads.mobile.sdk.common.LoadAdError
import com.google.android.libraries.ads.mobile.sdk.common.PreloadCallback
import com.google.android.libraries.ads.mobile.sdk.common.PreloadConfiguration
import com.google.android.libraries.ads.mobile.sdk.common.ResponseInfo
import com.google.android.libraries.ads.mobile.sdk.common.VideoOptions
import com.google.android.libraries.ads.mobile.sdk.initialization.InitializationConfig
import com.google.android.libraries.ads.mobile.sdk.interstitial.InterstitialAd
import com.google.android.libraries.ads.mobile.sdk.interstitial.InterstitialAdEventCallback
import com.google.android.libraries.ads.mobile.sdk.interstitial.InterstitialAdPreloader
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAd
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdEventCallback
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdLoader
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdLoaderCallback
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdRequest
import com.google.android.libraries.ads.mobile.sdk.nativead.NativeAdView
import com.google.android.libraries.ads.mobile.sdk.rewarded.RewardedAd
import com.google.android.libraries.ads.mobile.sdk.rewarded.RewardedAdEventCallback
import com.google.android.libraries.ads.mobile.sdk.rewarded.RewardedAdPreloader
import com.google.android.libraries.ads.mobile.sdk.rewarded.ServerSideVerificationOptions
import com.google.android.libraries.ads.mobile.sdk.rewardedinterstitial.RewardedInterstitialAd
import com.google.android.libraries.ads.mobile.sdk.rewardedinterstitial.RewardedInterstitialAdEventCallback
import com.google.android.libraries.ads.mobile.sdk.rewardedinterstitial.RewardedInterstitialAdPreloader
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * The Android half of the plugin: every Dart call lands here via the JNI shim
 * in `src/ads_bridge.cpp`, and every SDK event leaves here the same way.
 *
 * ## Threading
 *
 * The GMA Next-Gen SDK fires **all** callbacks on a background thread, and
 * `MobileAds.initialize` must itself be called off the main thread or it ANRs
 * (doc/design.md §6). Dart's `Pointer.fromFunction` callbacks, in contrast,
 * must run on the owning isolate's thread — the main thread. So:
 *
 *  - calls **into** the SDK that must not block the main thread go to [ioExecutor]
 *  - every event **out** of the SDK hops back through [deliver]
 *
 * ## Hot restart
 *
 * [dispatcherPtr] is a slot, re-read immediately before every fire rather than
 * cached in C++. The engine invokes the hook registered with
 * `DNViewRegistry.registerResetHook` before it tears the old isolate down, and
 * [reset] zeroes the slot there, so an ad event that arrives afterwards is
 * dropped instead of calling into a dead isolate. This matters more for ads
 * than for most plugins: load and presentation events arrive seconds to minutes
 * after the call that triggered them, so they routinely straddle a restart.
 */
@Keep
object AdsBridge {
    // Event kinds. Mirrors AdEventStatus in lib/src/ads_ffi_bindings.dart —
    // never renumber an existing value.
    private const val STATUS_INITIALIZED = 0
    private const val STATUS_LOADED = 1
    private const val STATUS_FAILED_TO_LOAD = 2
    private const val STATUS_SHOWED = 3
    private const val STATUS_FAILED_TO_SHOW = 4
    private const val STATUS_DISMISSED = 5
    private const val STATUS_IMPRESSION = 6
    private const val STATUS_CLICKED = 7
    private const val STATUS_USER_EARNED_REWARD = 8
    private const val STATUS_PAID_EVENT = 9
    private const val STATUS_AD_PRELOADED = 10
    private const val STATUS_ADS_EXHAUSTED = 11
    private const val STATUS_FAILED_TO_PRELOAD = 12

    // Ad formats. Mirrors AdFormat in lib/src/ads_ffi_bindings.dart.
    private const val FORMAT_INTERSTITIAL = 0
    private const val FORMAT_REWARDED = 1
    private const val FORMAT_REWARDED_INTERSTITIAL = 2
    private const val FORMAT_APP_OPEN = 3

    // Which document preloadReadJson should return. Mirrors PreloadQuery in
    // lib/src/ads_ffi_bindings.dart.
    private const val QUERY_POLLED_RESPONSE_INFO = 0
    private const val QUERY_CONFIGURATION = 1
    private const val QUERY_ALL_CONFIGURATIONS = 2

    /** The manifest key the AdMob App ID is read from. */
    private const val APP_ID_META_DATA = "com.google.android.gms.ads.APPLICATION_ID"

    /** The error domain reported for failures raised by this plugin itself. */
    private const val PLUGIN_ERROR_DOMAIN = "dartnative_mobile_ads"

    /** The error domain reported for failures raised by the Mobile Ads SDK. */
    private const val SDK_ERROR_DOMAIN = "com.google.android.libraries.ads.mobile.sdk"

    @Volatile
    private var dispatcherPtr: Long = 0L

    @Volatile
    private var initialized = false

    /** Whether [reset] has been wired to the engine's hot-restart hook. */
    private var resetHookInstalled = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * Off-main work: SDK initialization, and ad loads so that a slow network
     * stack on the request path cannot jank the frame Dart is building.
     */
    private val ioExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "dn-mobile-ads").apply { isDaemon = true }
    }

    /** Live ads, keyed by the Dart-side token that owns each one. */
    private val ads = HashMap<Long, Any>()

    private external fun nativeDeliver(
        dispatcherPtr: Long,
        token: Long,
        status: Int,
        payload: String,
    )

    // -----------------------------------------------------------------------
    // Dart -> native entry points (called from ads_bridge.cpp)
    // -----------------------------------------------------------------------

    @Keep
    @JvmStatic
    fun setDispatcher(ptr: Long) {
        dispatcherPtr = ptr
        installResetHook()
    }

    /**
     * Registers [reset] with the engine's hot-restart teardown, once.
     *
     * The hook fires before the outgoing isolate is destroyed, which is the only
     * point at which the stale callback pointer can be dropped safely.
     */
    private fun installResetHook() {
        if (resetHookInstalled) return
        resetHookInstalled = true
        DNViewRegistry.registerResetHook { reset() }
    }

    /**
     * Drops the dispatcher and every live ad ahead of a hot restart.
     *
     * The ads are released rather than shown again: their Dart-side owners died
     * with the old isolate, so nothing can present or dispose them afterwards.
     */
    private fun reset() {
        dispatcherPtr = 0L
        ads.clear()

        // Banners hold a real AdView each, so they have to be destroyed rather
        // than just dropped; their Dart owners died with the old isolate.
        // destroy() touches the view hierarchy, hence the main-thread hop.
        val stale = banners.values.toList()
        banners.clear()
        pendingContainers.clear()

        // Native ads hold a NativeAdView each, torn down the same way.
        val staleNative = nativeAds.values.toList()
        nativeAds.clear()
        pendingNativeContainers.clear()

        if (stale.isNotEmpty() || staleNative.isNotEmpty()) {
            mainHandler.post {
                for (holder in stale) {
                    holder.adView?.destroy()
                    holder.container.removeAllViews()
                }
                for (holder in staleNative) {
                    holder.adView?.destroy()
                    holder.container.removeAllViews()
                }
            }
        }
    }

    @Keep
    @JvmStatic
    fun initialize(token: Long) {
        if (initialized) {
            deliver(token, STATUS_INITIALIZED, initializationJson())
            return
        }

        val context = DNNavigator.activity()?.applicationContext
        if (context == null) {
            // No activity yet, so there is no Context to initialize with.
            // Report completion anyway: the Dart future must not hang.
            deliver(token, STATUS_INITIALIZED, errorPayload("No Activity available yet."))
            return
        }

        val appId = readAppId(context)
        if (appId == null) {
            // A missing App ID is a setup mistake. Report it rather than
            // throwing: an exception here would take the app down at startup
            // (doc/design.md §9-3).
            deliver(
                token,
                STATUS_INITIALIZED,
                errorPayload(
                    "Missing $APP_ID_META_DATA <meta-data> in AndroidManifest.xml. " +
                        "Add your AdMob App ID; see the dartnative_mobile_ads README.",
                ),
            )
            return
        }

        // Must not run on the main thread: GMA Next-Gen's initialize() ANRs.
        ioExecutor.execute {
            try {
                val config = InitializationConfig.Builder(appId).build()
                MobileAds.initialize(context, config) {
                    initialized = true
                    deliver(token, STATUS_INITIALIZED, initializationJson())
                }
            } catch (t: Throwable) {
                deliver(token, STATUS_INITIALIZED, errorPayload(t.message ?: t.toString()))
            }
        }
    }

    @Keep
    @JvmStatic
    fun loadAd(token: Long, format: Int, adUnitId: String, requestJson: String) {
        val request = buildRequest(adUnitId, requestJson)
        ioExecutor.execute {
            try {
                when (format) {
                    FORMAT_INTERSTITIAL -> loadInterstitial(token, request)
                    FORMAT_REWARDED -> loadRewarded(token, request)
                    FORMAT_REWARDED_INTERSTITIAL -> loadRewardedInterstitial(token, request)
                    FORMAT_APP_OPEN -> loadAppOpen(token, request)
                    else -> deliverLoadFailure(token, "Unknown ad format: $format")
                }
            } catch (t: Throwable) {
                deliverLoadFailure(token, t.message ?: t.toString())
            }
        }
    }

    @Keep
    @JvmStatic
    fun showAd(token: Long) {
        // Presentation touches the view hierarchy, so it must be on main. Dart
        // calls arrive on main already; post anyway to keep the guarantee local.
        mainHandler.post {
            val activity = DNNavigator.activity() ?: return@post
            when (val ad = ads[token]) {
                is InterstitialAd -> ad.show(activity)
                is AppOpenAd -> ad.show(activity)
                is RewardedAd -> ad.show(activity) { reward ->
                    deliverReward(token, reward.amount, reward.type)
                }
                is RewardedInterstitialAd -> ad.show(activity) { reward ->
                    deliverReward(token, reward.amount, reward.type)
                }
            }
        }
    }

    @Keep
    @JvmStatic
    fun disposeAd(token: Long) {
        mainHandler.post { ads.remove(token) }
    }

    @Keep
    @JvmStatic
    fun setAppMuted(muted: Boolean) {
        MobileAds.setUserMutedApp(muted)
    }

    /**
     * Turns immersive mode on or off for one full-screen ad.
     *
     * Android-only; the Dart layer skips this call on other platforms.
     */
    @Keep
    @JvmStatic
    fun setImmersiveMode(token: Long, enabled: Boolean) {
        mainHandler.post {
            when (val ad = ads[token]) {
                is InterstitialAd -> ad.setImmersiveMode(enabled)
                is RewardedAd -> ad.setImmersiveMode(enabled)
                is RewardedInterstitialAd -> ad.setImmersiveMode(enabled)
                is AppOpenAd -> ad.setImmersiveMode(enabled)
            }
        }
    }

    /**
     * Attaches server-side verification options to a rewarded ad.
     *
     * Only the rewarded formats support SSV; anything else is ignored.
     */
    @Keep
    @JvmStatic
    fun setServerSideVerification(token: Long, userId: String, customData: String) {
        mainHandler.post {
            val options = ServerSideVerificationOptions(userId, customData)
            when (val ad = ads[token]) {
                is RewardedAd -> ad.setServerSideVerificationOptions(options)
                is RewardedInterstitialAd -> ad.setServerSideVerificationOptions(options)
            }
        }
    }

    // -----------------------------------------------------------------------
    // Loading
    //
    // Each format has its own ad type and its own event-callback interface, so
    // the four loads cannot be collapsed into one generic call. The event
    // handling itself is shared: every per-format interface extends
    // AdEventCallback, which [AdEvents] implements once.
    // -----------------------------------------------------------------------

    private fun loadInterstitial(token: Long, request: AdRequest) {
        InterstitialAd.load(
            request,
            object : AdLoadCallback<InterstitialAd> {
                override fun onAdLoaded(ad: InterstitialAd) {
                    ad.adEventCallback = object : AdEvents(token), InterstitialAdEventCallback {}
                    store(token, ad)
                }

                override fun onAdFailedToLoad(adError: LoadAdError) {
                    deliver(token, STATUS_FAILED_TO_LOAD, loadErrorJson(adError))
                }
            },
        )
    }

    private fun loadRewarded(token: Long, request: AdRequest) {
        RewardedAd.load(
            request,
            object : AdLoadCallback<RewardedAd> {
                override fun onAdLoaded(ad: RewardedAd) {
                    ad.adEventCallback = object : AdEvents(token), RewardedAdEventCallback {}
                    store(token, ad)
                }

                override fun onAdFailedToLoad(adError: LoadAdError) {
                    deliver(token, STATUS_FAILED_TO_LOAD, loadErrorJson(adError))
                }
            },
        )
    }

    private fun loadRewardedInterstitial(token: Long, request: AdRequest) {
        RewardedInterstitialAd.load(
            request,
            object : AdLoadCallback<RewardedInterstitialAd> {
                override fun onAdLoaded(ad: RewardedInterstitialAd) {
                    ad.adEventCallback =
                        object : AdEvents(token), RewardedInterstitialAdEventCallback {}
                    store(token, ad)
                }

                override fun onAdFailedToLoad(adError: LoadAdError) {
                    deliver(token, STATUS_FAILED_TO_LOAD, loadErrorJson(adError))
                }
            },
        )
    }

    private fun loadAppOpen(token: Long, request: AdRequest) {
        AppOpenAd.load(
            request,
            object : AdLoadCallback<AppOpenAd> {
                override fun onAdLoaded(ad: AppOpenAd) {
                    ad.adEventCallback = object : AdEvents(token), AppOpenAdEventCallback {}
                    store(token, ad)
                }

                override fun onAdFailedToLoad(adError: LoadAdError) {
                    deliver(token, STATUS_FAILED_TO_LOAD, loadErrorJson(adError))
                }
            },
        )
    }

    /** Retains a loaded ad and tells Dart it is ready to show. */
    private fun store(token: Long, ad: Any) {
        mainHandler.post {
            ads[token] = ad
            deliver(token, STATUS_LOADED, "{}")
        }
    }

    /**
     * Forwards one ad's presentation events to Dart.
     *
     * Open rather than an interface implementation, because each format demands
     * its own sub-interface; the load sites mix this in with theirs.
     */
    private open class AdEvents(private val token: Long) :
        com.google.android.libraries.ads.mobile.sdk.common.AdEventCallback {

        override fun onAdShowedFullScreenContent() {
            deliver(token, STATUS_SHOWED, "{}")
        }

        override fun onAdFailedToShowFullScreenContent(fullScreenContentError: FullScreenContentError) {
            deliver(token, STATUS_FAILED_TO_SHOW, showErrorJson(fullScreenContentError))
        }

        override fun onAdDismissedFullScreenContent() {
            deliver(token, STATUS_DISMISSED, "{}")
        }

        override fun onAdImpression() {
            deliver(token, STATUS_IMPRESSION, "{}")
        }

        override fun onAdClicked() {
            deliver(token, STATUS_CLICKED, "{}")
        }

        override fun onAdPaid(value: AdValue) {
            deliver(token, STATUS_PAID_EVENT, paidJson(value))
        }
    }

    // -----------------------------------------------------------------------
    // Banners
    //
    // A banner is one AdView that the SDK draws itself, so the work here is
    // plumbing: create a container the reconciler can mount immediately, load
    // into it, and forward the events.
    // -----------------------------------------------------------------------

    /**
     * The key both sides claim the banner view type under.
     *
     * Must match `ViewType.claim(...)` in lib/src/banner_ad.dart. `claimViewType`
     * is idempotent per key, so resolving it here yields the same number the
     * Dart side got without either hard-coding one.
     */
    private const val BANNER_VIEW_TYPE_KEY = "dartnative_mobile_ads/banner"

    /** The reconciler's view type for our banners. */
    val bannerViewType: Int by lazy {
        DNPluginRegistry.claimViewType(BANNER_VIEW_TYPE_KEY)
    }

    /** Registers the banner provider with the reconciler, once. */
    private var providerRegistered = false

    internal fun ensureBannerProviderRegistered() {
        if (providerRegistered) return
        providerRegistered = true
        DNPluginRegistry.register(BannerAdProvider())
    }

    /** Live banners, keyed by the reconciler's view id. */
    private val banners = HashMap<Long, BannerHolder>()

    /** Banner containers built but not yet handed to [BannerAdProvider]. */
    private val pendingContainers = ArrayDeque<FrameLayout>()

    /** One banner's container plus the SDK objects attached to it. */
    private class BannerHolder(
        val container: FrameLayout,
        var adView: AdView? = null,
        var bannerAd: BannerAd? = null,
    )

    /**
     * The Context banners are built against.
     *
     * Banners only exist while a screen is mounted, so an Activity is present.
     */
    internal fun requireContext(): android.content.Context =
        DNNavigator.activity() ?: throw IllegalStateException("No Activity")

    /**
     * Hands [BannerAdProvider] the container prepared by the most recent
     * [bannerCreate].
     *
     * Returns an empty container if the queue is empty, which should not happen
     * — createView always follows a bannerCreate for the same view.
     */
    internal fun takePendingBannerContainer(): FrameLayout =
        pendingContainers.removeFirstOrNull() ?: FrameLayout(requireContext())

    /**
     * Builds a banner's container and starts loading the ad into it.
     *
     * Called from the Dart element's `mount`, before the reconciler asks
     * [BannerAdProvider] for the view.
     */
    @Keep
    @JvmStatic
    fun bannerCreate(
        token: Long,
        viewId: Long,
        adUnitId: String,
        requestJson: String,
        widthDp: Int,
        heightDp: Int,
    ) {
        val activity = DNNavigator.activity() ?: return
        ensureBannerProviderRegistered()

        // Must be synchronous: the reconciler calls createView right after this
        // returns, and the container has to be queued before it does.
        val container = FrameLayout(activity)
        val holder = BannerHolder(container)
        banners[viewId] = holder
        pendingContainers.addLast(container)

        val adSize = resolveAdSize(widthDp, heightDp)
        val request = buildBannerRequest(adUnitId, requestJson, adSize)

        // AdView.loadAd (rather than the deprecated BannerAd.load) both loads
        // and registers the ad with the view, so there is no separate attach
        // step and no window where the view is mounted but unregistered.
        mainHandler.post {
            try {
                val adView = AdView(activity)
                adView.resize(adSize)
                holder.adView = adView
                // Size the AdView to the ad, not to the container. AdMob
                // forbids scaling or cropping ad content, and the SDK returns a
                // fixed size even for an adaptive request, so stretching it
                // would clip the creative. Centring leaves any slack as margin.
                val density = activity.resources.displayMetrics.density
                holder.container.addView(
                    adView,
                    FrameLayout.LayoutParams(
                        (adSize.width * density).toInt(),
                        (adSize.height * density).toInt(),
                        Gravity.CENTER,
                    ),
                )

                adView.loadAd(
                    request,
                    object : AdLoadCallback<BannerAd> {
                        override fun onAdLoaded(ad: BannerAd) {
                            ad.adEventCallback =
                                object : AdEvents(token), BannerAdEventCallback {}
                            holder.bannerAd = ad
                            deliver(token, STATUS_LOADED, "{}")
                        }

                        override fun onAdFailedToLoad(adError: LoadAdError) {
                            deliver(token, STATUS_FAILED_TO_LOAD, loadErrorJson(adError))
                        }
                    },
                )
            } catch (t: Throwable) {
                deliverLoadFailure(token, t.message ?: t.toString())
            }
        }
    }

    /**
     * Destroys the banner mounted at [viewId].
     *
     * Only called on an explicit Dart-side dispose — never from unmount, so a
     * recycled list cell does not re-request an ad (`doc/design.md` §7-4).
     */
    @Keep
    @JvmStatic
    fun bannerDispose(viewId: Long) {
        mainHandler.post {
            val holder = banners.remove(viewId) ?: return@post
            holder.adView?.destroy()
            holder.container.removeAllViews()
        }
    }

    /**
     * Returns the Google-optimized banner height for [widthDp], or 0.
     *
     * A pure calculation — no network — so Dart can call it synchronously while
     * laying out (`doc/design.md` §7-3).
     */
    @Keep
    @JvmStatic
    fun adaptiveBannerHeight(widthDp: Int): Int = try {
        val activity = DNNavigator.activity()
        if (activity == null) {
            0
        } else {
            AdSize.getLargeAnchoredAdaptiveBannerAdSize(activity, widthDp)
                .height
        }
    } catch (_: Throwable) {
        0
    }

    /**
     * Maps a width/height onto the SDK's own AdSize where one matches.
     *
     * A freshly constructed `AdSize(320, 50)` is *not* treated the same as
     * `AdSize.BANNER`: AdMob reads a custom size as a flexible slot and will
     * happily fill it with a differently shaped creative (a 320x50 request came
     * back as a 468x60 ad). Passing the canonical constant asks for the
     * standard slot, which is what the Dart-side `AdSize.banner` means.
     *
     * Anything that is not a standard size — an adaptive height, or a size the
     * caller made up — falls through to a custom AdSize, which is correct for
     * those.
     */
    private fun resolveAdSize(widthDp: Int, heightDp: Int): AdSize = when {
        widthDp == AdSize.BANNER_WIDTH && heightDp == AdSize.BANNER_HEIGHT ->
            AdSize.BANNER
        widthDp == AdSize.LARGE_BANNER_WIDTH &&
            heightDp == AdSize.LARGE_BANNER_HEIGHT -> AdSize.LARGE_BANNER
        widthDp == AdSize.MEDIUM_RECTANGLE_WIDTH &&
            heightDp == AdSize.MEDIUM_RECTANGLE_HEIGHT -> AdSize.MEDIUM_RECTANGLE
        widthDp == AdSize.FULL_BANNER_WIDTH &&
            heightDp == AdSize.FULL_BANNER_HEIGHT -> AdSize.FULL_BANNER
        widthDp == AdSize.LEADERBOARD_WIDTH &&
            heightDp == AdSize.LEADERBOARD_HEIGHT -> AdSize.LEADERBOARD
        else -> AdSize(widthDp, heightDp)
    }

    private fun buildBannerRequest(
        adUnitId: String,
        requestJson: String,
        adSize: AdSize,
    ): BannerAdRequest {
        val builder = BannerAdRequest.Builder(adUnitId, adSize)
        applyTargeting(builder, requestJson)
        return builder.build()
    }

    // -----------------------------------------------------------------------
    // Native ads
    //
    // Same view-id handover as banners, but the view is built by the app rather
    // than the SDK: either from a built-in template (NativeAdRenderer) or from a
    // factory the app registered (doc/design.md §8-2).
    // -----------------------------------------------------------------------

    /** Must match `ViewType.claim(...)` in lib/src/native_ad.dart. */
    private const val NATIVE_VIEW_TYPE_KEY = "dartnative_mobile_ads/native"

    /** The reconciler's view type for our native ads. */
    val nativeAdViewType: Int by lazy {
        DNPluginRegistry.claimViewType(NATIVE_VIEW_TYPE_KEY)
    }

    /** Live native ads, keyed by the reconciler's view id. */
    private val nativeAds = HashMap<Long, NativeAdHolder>()

    /** Native ad containers built but not yet handed to [NativeAdProvider]. */
    private val pendingNativeContainers = ArrayDeque<FrameLayout>()

    /** Factories registered by the app, keyed by the id Dart names them with. */
    private val nativeAdFactories = HashMap<String, NativeAdFactory>()

    /** One native ad's container plus the SDK objects attached to it. */
    private class NativeAdHolder(
        val container: FrameLayout,
        var adView: NativeAdView? = null,
        var nativeAd: NativeAd? = null,
    )

    /**
     * Registers [factory] under [factoryId].
     *
     * Called through [DartNativeMobileAdsPlugin.registerNativeAdFactory];
     * returns false if that id is taken, matching the Flutter plugin.
     */
    internal fun addNativeAdFactory(factoryId: String, factory: NativeAdFactory): Boolean {
        if (nativeAdFactories.containsKey(factoryId)) return false
        nativeAdFactories[factoryId] = factory
        return true
    }

    /** Removes the factory registered under [factoryId], returning it if any. */
    internal fun removeNativeAdFactory(factoryId: String): NativeAdFactory? =
        nativeAdFactories.remove(factoryId)

    /** Registers the native ad provider with the reconciler, once. */
    private var nativeProviderRegistered = false

    internal fun ensureNativeAdProviderRegistered() {
        if (nativeProviderRegistered) return
        nativeProviderRegistered = true
        DNPluginRegistry.register(NativeAdProvider())
    }

    /** Hands [NativeAdProvider] the container prepared by [nativeAdCreate]. */
    internal fun takePendingNativeContainer(): FrameLayout =
        pendingNativeContainers.removeFirstOrNull() ?: FrameLayout(requireContext())

    /**
     * Builds a native ad's container and starts loading the ad into it.
     *
     * Called from the Dart element's `mount`, before the reconciler asks
     * [NativeAdProvider] for the view. [optionsJson] says which renderer to use
     * — `templateStyle` for a built-in template, `factoryId` for a registered
     * factory — plus the request options and any custom options.
     */
    @Keep
    @JvmStatic
    fun nativeAdCreate(
        token: Long,
        viewId: Long,
        adUnitId: String,
        requestJson: String,
        optionsJson: String,
    ) {
        val activity = DNNavigator.activity() ?: return
        ensureNativeAdProviderRegistered()

        // Synchronous for the same reason as bannerCreate: createView follows
        // immediately, and the container has to be queued before it does.
        val container = FrameLayout(activity)
        val holder = NativeAdHolder(container)
        nativeAds[viewId] = holder
        pendingNativeContainers.addLast(container)

        val options = try {
            JSONObject(optionsJson)
        } catch (_: Throwable) {
            JSONObject()
        }

        val templateStyle = options.optJSONObject("templateStyle")
        val factoryId = options.optString("factoryId", "")

        // Fail fast and in Dart's terms: without one of these there is nothing
        // to render the ad into, and finding that out after a network round trip
        // just delays the same error.
        if (templateStyle == null && factoryId.isEmpty()) {
            deliverLoadFailure(token, "Provide either nativeTemplateStyle or factoryId.")
            return
        }
        if (templateStyle == null && !nativeAdFactories.containsKey(factoryId)) {
            deliverLoadFailure(
                token,
                "No NativeAdFactory registered for id: $factoryId. Register it with " +
                    "DartNativeMobileAdsPlugin.registerNativeAdFactory before requesting the ad.",
            )
            return
        }

        val request = buildNativeAdRequest(adUnitId, requestJson, options)

        ioExecutor.execute {
            try {
                NativeAdLoader.load(
                    request,
                    object : NativeAdLoaderCallback {
                        override fun onNativeAdLoaded(nativeAd: NativeAd) {
                            nativeAd.adEventCallback =
                                object : AdEvents(token), NativeAdEventCallback {}
                            holder.nativeAd = nativeAd
                            // Inflating and registering touches the view
                            // hierarchy, so it has to happen on the main thread;
                            // the SDK delivered this on a background one.
                            mainHandler.post {
                                attachNativeAd(token, holder, nativeAd, templateStyle, factoryId, options)
                            }
                        }

                        override fun onAdFailedToLoad(adError: LoadAdError) {
                            deliver(token, STATUS_FAILED_TO_LOAD, loadErrorJson(adError))
                        }
                    },
                )
            } catch (t: Throwable) {
                deliverLoadFailure(token, t.message ?: t.toString())
            }
        }
    }

    /** Builds the ad's view and puts it in the container. Main thread only. */
    private fun attachNativeAd(
        token: Long,
        holder: NativeAdHolder,
        nativeAd: NativeAd,
        templateStyle: JSONObject?,
        factoryId: String,
        options: JSONObject,
    ) {
        // The element may have unmounted while the request was in flight.
        if (holder.container.parent == null && holder.adView != null) return

        try {
            val context = DNNavigator.activity() ?: return
            val adView = if (templateStyle != null) {
                NativeAdRenderer.render(context, nativeAd, templateStyle)
            } else {
                val factory = nativeAdFactories[factoryId]
                if (factory == null) {
                    deliverLoadFailure(token, "No NativeAdFactory registered for id: $factoryId")
                    return
                }
                factory.createNativeAdView(nativeAd, jsonToMap(options.optJSONObject("customOptions")))
            }

            holder.adView = adView
            holder.container.removeAllViews()
            holder.container.addView(
                adView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
            deliver(token, STATUS_LOADED, "{}")
        } catch (t: Throwable) {
            // A factory that throws is an app bug, but it must not take the
            // process down — report it as a load failure instead.
            deliverLoadFailure(token, "Failed to build the native ad view: ${t.message ?: t}")
        }
    }

    /**
     * Destroys the native ad mounted at [viewId].
     *
     * Note `NativeAd` itself has no destroy() in the Next-Gen SDK — the view
     * owns the teardown (doc/design.md §8-3).
     */
    @Keep
    @JvmStatic
    fun nativeAdDispose(viewId: Long) {
        mainHandler.post {
            val holder = nativeAds.remove(viewId) ?: return@post
            holder.adView?.destroy()
            holder.container.removeAllViews()
        }
    }

    private fun buildNativeAdRequest(
        adUnitId: String,
        requestJson: String,
        options: JSONObject,
    ): NativeAdRequest {
        val builder = NativeAdRequest.Builder(
            adUnitId,
            listOf(NativeAd.NativeAdType.NATIVE),
        )
        applyTargeting(builder, requestJson)

        val adOptions = options.optJSONObject("nativeAdOptions") ?: return builder.build()

        if (adOptions.has("mediaAspectRatio")) {
            NativeAd.NativeMediaAspectRatio.values()
                .getOrNull(adOptions.getInt("mediaAspectRatio"))
                ?.let { builder.setMediaAspectRatio(it) }
        }
        if (adOptions.has("adChoicesPlacement")) {
            // Dart's enum is ordered topRight, topLeft, bottomRight, bottomLeft
            // (matching google_mobile_ads); the SDK's is TOP_LEFT first, so the
            // index cannot be used directly.
            val placement = when (adOptions.getInt("adChoicesPlacement")) {
                0 -> AdChoicesPlacement.TOP_RIGHT
                1 -> AdChoicesPlacement.TOP_LEFT
                2 -> AdChoicesPlacement.BOTTOM_RIGHT
                3 -> AdChoicesPlacement.BOTTOM_LEFT
                else -> null
            }
            placement?.let { builder.setAdChoicesPlacement(it) }
        }
        adOptions.optJSONObject("videoOptions")?.let { video ->
            // Only the keys Dart actually sent are applied: the builder's own
            // defaults are the SDK's, and startMuted in particular defaults to
            // true, so writing an unset field would silently change behaviour.
            val videoBuilder = VideoOptions.Builder()
            if (video.has("startMuted")) {
                videoBuilder.setStartMuted(video.getBoolean("startMuted"))
            }
            if (video.has("customControlsRequested")) {
                videoBuilder.setCustomControlsRequested(
                    video.getBoolean("customControlsRequested"),
                )
            }
            if (video.has("clickToExpandRequested")) {
                videoBuilder.setClickToExpandRequested(
                    video.getBoolean("clickToExpandRequested"),
                )
            }
            builder.setVideoOptions(videoBuilder.build())
        }
        if (adOptions.optBoolean("shouldReturnUrlsForImageAssets", false)) {
            // One-way in the Next-Gen SDK: there is no re-enable, which is why
            // the Dart doc says passing false leaves the default alone.
            builder.disableImageDownloading()
        }

        return builder.build()
    }

    /** Flattens a JSON object into the map a [NativeAdFactory] receives. */
    private fun jsonToMap(json: JSONObject?): Map<String, Any?> {
        if (json == null) return emptyMap()
        val out = HashMap<String, Any?>(json.length())
        for (key in json.keys()) {
            out[key] = when (val value = json.get(key)) {
                JSONObject.NULL -> null
                is JSONObject -> jsonToMap(value)
                else -> value
            }
        }
        return out
    }

    // -----------------------------------------------------------------------
    // Preloading
    //
    // The SDK keeps the buffers itself, keyed by a caller-chosen preload id, so
    // there is nothing to cache here beyond the response info of the ad each
    // poll removed — `peekAdResponseInfo` describes the *next* ad in the
    // buffer, not the one just taken, so it is captured before polling.
    // -----------------------------------------------------------------------

    /** Response info of the most recently polled ad, keyed by "format:preloadId". */
    private val polledResponseInfo = HashMap<String, ResponseInfo>()

    @Keep
    @JvmStatic
    fun preloadStart(
        token: Long,
        format: Int,
        preloadId: String,
        adUnitId: String,
        requestJson: String,
        bufferSize: Int,
    ) {
        val config = PreloadConfiguration(
            buildRequest(adUnitId, requestJson),
            bufferSize,
        )
        val callback = object : PreloadCallback {
            override fun onAdPreloaded(preloadId: String, responseInfo: ResponseInfo) {
                deliver(
                    token,
                    STATUS_AD_PRELOADED,
                    JSONObject()
                        .put("preloadId", preloadId)
                        .put("responseInfo", responseInfoJson(responseInfo))
                        .toString(),
                )
            }

            override fun onAdsExhausted(preloadId: String) {
                deliver(
                    token,
                    STATUS_ADS_EXHAUSTED,
                    JSONObject().put("preloadId", preloadId).toString(),
                )
            }

            override fun onAdFailedToPreload(preloadId: String, adError: LoadAdError) {
                deliver(
                    token,
                    STATUS_FAILED_TO_PRELOAD,
                    JSONObject(loadErrorJson(adError)).put("preloadId", preloadId).toString(),
                )
            }
        }

        // Starting a preloader issues ad requests, so keep it off the main thread
        // for the same reason loads are off it.
        ioExecutor.execute {
            try {
                when (format) {
                    FORMAT_INTERSTITIAL ->
                        InterstitialAdPreloader.start(preloadId, config, callback)
                    FORMAT_REWARDED ->
                        RewardedAdPreloader.start(preloadId, config, callback)
                    FORMAT_REWARDED_INTERSTITIAL ->
                        RewardedInterstitialAdPreloader.start(preloadId, config, callback)
                    FORMAT_APP_OPEN ->
                        AppOpenAdPreloader.start(preloadId, config, callback)
                }
            } catch (t: Throwable) {
                deliver(
                    token,
                    STATUS_FAILED_TO_PRELOAD,
                    JSONObject()
                        .put("preloadId", preloadId)
                        .put("code", -1)
                        .put("domain", PLUGIN_ERROR_DOMAIN)
                        .put("message", t.message ?: t.toString())
                        .toString(),
                )
            }
        }
    }

    /**
     * Takes one ad out of a buffer and files it under a fresh token.
     *
     * Returns that token, or 0 when the buffer is empty. Synchronous: the SDK
     * answers from the buffer it already holds.
     */
    @Keep
    @JvmStatic
    fun preloadPoll(format: Int, preloadId: String): Long {
        // Capture before polling: peek describes the next ad, not this one.
        val info = try {
            when (format) {
                FORMAT_INTERSTITIAL -> InterstitialAdPreloader.peekAdResponseInfo(preloadId)
                FORMAT_REWARDED -> RewardedAdPreloader.peekAdResponseInfo(preloadId)
                FORMAT_REWARDED_INTERSTITIAL ->
                    RewardedInterstitialAdPreloader.peekAdResponseInfo(preloadId)
                FORMAT_APP_OPEN -> AppOpenAdPreloader.peekAdResponseInfo(preloadId)
                else -> null
            }
        } catch (_: Throwable) {
            null
        }

        val ad: Any? = try {
            when (format) {
                FORMAT_INTERSTITIAL -> InterstitialAdPreloader.pollAd(preloadId)
                FORMAT_REWARDED -> RewardedAdPreloader.pollAd(preloadId)
                FORMAT_REWARDED_INTERSTITIAL ->
                    RewardedInterstitialAdPreloader.pollAd(preloadId)
                FORMAT_APP_OPEN -> AppOpenAdPreloader.pollAd(preloadId)
                else -> null
            }
        } catch (_: Throwable) {
            null
        }
        if (ad == null) return 0L

        val token = nextPreloadToken()
        when (ad) {
            is InterstitialAd ->
                ad.adEventCallback = object : AdEvents(token), InterstitialAdEventCallback {}
            is RewardedAd ->
                ad.adEventCallback = object : AdEvents(token), RewardedAdEventCallback {}
            is RewardedInterstitialAd ->
                ad.adEventCallback =
                    object : AdEvents(token), RewardedInterstitialAdEventCallback {}
            is AppOpenAd ->
                ad.adEventCallback = object : AdEvents(token), AppOpenAdEventCallback {}
        }

        if (info != null) {
            polledResponseInfo["$format:$preloadId"] = info
        } else {
            polledResponseInfo.remove("$format:$preloadId")
        }

        // The ad map is read on the main thread by show/dispose, so publish there.
        mainHandler.post { ads[token] = ad }
        return token
    }

    @Keep
    @JvmStatic
    fun preloadIsAdAvailable(format: Int, preloadId: String): Boolean = try {
        when (format) {
            FORMAT_INTERSTITIAL -> InterstitialAdPreloader.isAdAvailable(preloadId)
            FORMAT_REWARDED -> RewardedAdPreloader.isAdAvailable(preloadId)
            FORMAT_REWARDED_INTERSTITIAL ->
                RewardedInterstitialAdPreloader.isAdAvailable(preloadId)
            FORMAT_APP_OPEN -> AppOpenAdPreloader.isAdAvailable(preloadId)
            else -> false
        }
    } catch (_: Throwable) {
        false
    }

    @Keep
    @JvmStatic
    fun preloadNumAdsAvailable(format: Int, preloadId: String): Int = try {
        when (format) {
            FORMAT_INTERSTITIAL -> InterstitialAdPreloader.getNumAdsAvailable(preloadId)
            FORMAT_REWARDED -> RewardedAdPreloader.getNumAdsAvailable(preloadId)
            FORMAT_REWARDED_INTERSTITIAL ->
                RewardedInterstitialAdPreloader.getNumAdsAvailable(preloadId)
            FORMAT_APP_OPEN -> AppOpenAdPreloader.getNumAdsAvailable(preloadId)
            else -> 0
        }
    } catch (_: Throwable) {
        0
    }

    @Keep
    @JvmStatic
    fun preloadDestroy(format: Int, preloadId: String) {
        polledResponseInfo.remove("$format:$preloadId")
        try {
            when (format) {
                FORMAT_INTERSTITIAL -> InterstitialAdPreloader.destroy(preloadId)
                FORMAT_REWARDED -> RewardedAdPreloader.destroy(preloadId)
                FORMAT_REWARDED_INTERSTITIAL ->
                    RewardedInterstitialAdPreloader.destroy(preloadId)
                FORMAT_APP_OPEN -> AppOpenAdPreloader.destroy(preloadId)
            }
        } catch (_: Throwable) {
            // Destroying an unknown preload id is not an error worth reporting.
        }
    }

    @Keep
    @JvmStatic
    fun preloadDestroyAll(format: Int) {
        polledResponseInfo.keys.removeAll { it.startsWith("$format:") }
        try {
            when (format) {
                FORMAT_INTERSTITIAL -> InterstitialAdPreloader.destroyAll()
                FORMAT_REWARDED -> RewardedAdPreloader.destroyAll()
                FORMAT_REWARDED_INTERSTITIAL -> RewardedInterstitialAdPreloader.destroyAll()
                FORMAT_APP_OPEN -> AppOpenAdPreloader.destroyAll()
            }
        } catch (_: Throwable) {
            // As above.
        }
    }

    /**
     * Returns one of the preloader's JSON documents, selected by [query].
     *
     * Returns an empty string when there is nothing to report, which the Dart
     * side reads as "absent".
     */
    @Keep
    @JvmStatic
    fun preloadReadJson(format: Int, query: Int, preloadId: String): String = try {
        when (query) {
            QUERY_POLLED_RESPONSE_INFO ->
                polledResponseInfo["$format:$preloadId"]
                    ?.let { responseInfoJson(it).toString() }
                    ?: ""

            QUERY_CONFIGURATION -> {
                val config = when (format) {
                    FORMAT_INTERSTITIAL -> InterstitialAdPreloader.getConfiguration(preloadId)
                    FORMAT_REWARDED -> RewardedAdPreloader.getConfiguration(preloadId)
                    FORMAT_REWARDED_INTERSTITIAL ->
                        RewardedInterstitialAdPreloader.getConfiguration(preloadId)
                    FORMAT_APP_OPEN -> AppOpenAdPreloader.getConfiguration(preloadId)
                    else -> null
                }
                config?.let { configJson(it).toString() } ?: ""
            }

            QUERY_ALL_CONFIGURATIONS -> {
                val configs = when (format) {
                    FORMAT_INTERSTITIAL -> InterstitialAdPreloader.getConfigurations()
                    FORMAT_REWARDED -> RewardedAdPreloader.getConfigurations()
                    FORMAT_REWARDED_INTERSTITIAL ->
                        RewardedInterstitialAdPreloader.getConfigurations()
                    FORMAT_APP_OPEN -> AppOpenAdPreloader.getConfigurations()
                    else -> emptyMap()
                }
                val json = JSONObject()
                for ((key, config) in configs) {
                    json.put(key, configJson(config))
                }
                json.toString()
            }

            else -> ""
        }
    } catch (_: Throwable) {
        ""
    }

    private fun configJson(config: PreloadConfiguration): JSONObject = JSONObject()
        .put("adUnitId", config.request.adUnitId)
        .put("bufferSize", config.bufferSize ?: 0)

    private fun responseInfoJson(info: ResponseInfo): JSONObject = JSONObject()
        .put("responseId", info.responseId)
        .put("mediationAdapterClassName", info.adapterClassName)

    /**
     * Allocates a token for an ad that arrived from a preloader.
     *
     * Dart hands out tokens for ads it requested; preloaded ads have no Dart
     * object yet, so they are numbered from the top down to keep the two ranges
     * from ever colliding.
     */
    private fun nextPreloadToken(): Long = preloadTokenCounter.decrementAndGet()

    private val preloadTokenCounter = java.util.concurrent.atomic.AtomicLong(-1L)

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private fun buildRequest(adUnitId: String, requestJson: String): AdRequest {
        val builder = AdRequest.Builder(adUnitId)
        applyTargeting(builder, requestJson)
        return builder.build()
    }

    /**
     * Applies the Dart-side AdRequest JSON to any request builder.
     *
     * Shared by the full-screen formats and banners, which use different
     * builder types but the same targeting fields (both extend
     * BaseAdRequestBuilder).
     *
     * A malformed body is ignored rather than failing the load: the documented
     * default is an untargeted request.
     */
    private fun applyTargeting(
        builder: BaseAdRequestBuilder<*>,
        requestJson: String,
    ) {
        try {
            val json = JSONObject(requestJson)

            json.optJSONArray("keywords")?.let { array ->
                for (i in 0 until array.length()) {
                    builder.addKeyword(array.optString(i))
                }
            }
            json.optString("contentUrl").takeIf { it.isNotEmpty() }?.let {
                builder.setContentUrl(it)
            }
            json.optJSONArray("neighboringContentUrls")?.let { array ->
                val urls = LinkedHashSet<String>(array.length())
                for (i in 0 until array.length()) {
                    urls.add(array.optString(i))
                }
                builder.setNeighboringContentUrls(urls)
            }
            if (json.optBoolean("nonPersonalizedAds", false)) {
                // "npa=1" is the documented signal for a non-personalized request.
                builder.putCustomTargeting("npa", "1")
            }
            json.optJSONObject("extras")?.let { extras ->
                for (key in extras.keys()) {
                    builder.putCustomTargeting(key, extras.optString(key))
                }
            }
        } catch (_: Throwable) {
            // See above: fall through to an untargeted request.
        }
    }

    private fun readAppId(context: Context): String? = try {
        val info = context.packageManager.getApplicationInfo(
            context.packageName,
            PackageManager.GET_META_DATA,
        )
        info.metaData?.getString(APP_ID_META_DATA)?.takeIf { it.isNotEmpty() }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    /**
     * Serializes a load failure.
     *
     * Next-Gen reports error codes as enums; `value` is the integer the legacy
     * SDK and the iOS side use, so Dart sees one numbering.
     */
    private fun loadErrorJson(error: LoadAdError): String {
        val response = error.responseInfo
        val json = JSONObject()
            .put("code", error.code.value)
            .put("domain", SDK_ERROR_DOMAIN)
            .put("message", error.message)
        if (response != null) {
            json.put(
                "responseInfo",
                JSONObject()
                    .put("responseId", response.responseId)
                    .put("mediationAdapterClassName", response.adapterClassName),
            )
        }
        return json.toString()
    }

    private fun showErrorJson(error: FullScreenContentError): String = JSONObject()
        .put("code", error.code.value)
        .put("domain", SDK_ERROR_DOMAIN)
        .put("message", error.message)
        .toString()

    private fun paidJson(value: AdValue): String = JSONObject()
        .put("valueMicros", value.valueMicros)
        .put("currencyCode", value.currencyCode)
        .put("precision", value.precisionType.ordinal)
        .toString()

    private fun errorPayload(message: String): String = JSONObject()
        .put("error", message)
        .toString()

    /**
     * Builds the initialization payload.
     *
     * Mediation is out of scope for v1.0 (doc/design.md §1-3), so the adapter
     * map is reported empty rather than half-populated.
     */
    private fun initializationJson(): String =
        JSONObject().put("adapterStatuses", JSONObject()).toString()

    private fun deliverLoadFailure(token: Long, message: String) {
        deliver(
            token,
            STATUS_FAILED_TO_LOAD,
            JSONObject()
                .put("code", -1)
                .put("domain", PLUGIN_ERROR_DOMAIN)
                .put("message", message)
                .toString(),
        )
    }

    private fun deliverReward(token: Long, amount: Int, type: String) {
        deliver(
            token,
            STATUS_USER_EARNED_REWARD,
            JSONObject().put("amount", amount).put("type", type).toString(),
        )
    }

    /**
     * Delivers one event to Dart on the main thread.
     *
     * Every SDK callback funnels through here — calling [nativeDeliver] directly
     * from an SDK thread would violate Dart's isolate-thread requirement and
     * crash. The slot is re-read inside the posted block, so an event queued
     * before a hot restart sees the zero written by [reset] and is dropped.
     */
    private fun deliver(token: Long, status: Int, payload: String) {
        mainHandler.post {
            val ptr = dispatcherPtr
            if (ptr == 0L) return@post
            nativeDeliver(ptr, token, status, payload)
        }
    }
}
