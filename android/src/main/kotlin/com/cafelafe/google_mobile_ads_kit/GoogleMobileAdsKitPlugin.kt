package com.cafelafe.google_mobile_ads_kit

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Registration entry point for the plugin's Android side.
 *
 * Its only job is to load the native library so that `JNI_OnLoad` runs and the
 * C++ bridge can cache the JVM and the method IDs it calls back into.
 *
 * The pubspec declares this class under `pluginClass` (rather than
 * `ffiPlugin: true`) precisely so that this runs: an ffi-only Android plugin is
 * never added to GeneratedPluginRegistrant, `System.loadLibrary` never fires,
 * and the ad callbacks' reverse-JNI would fail with UnsatisfiedLinkError.
 *
 * ## Why `FlutterPlugin` in a DartNative plugin
 *
 * DartNative reuses the Flutter tool's Android registration plumbing: the
 * generated `io.flutter.plugins.GeneratedPluginRegistrant` calls
 * `flutterEngine.getPlugins().add(new GoogleMobileAdsKitPlugin())`, and that
 * `add()` takes a `FlutterPlugin`. DartNative's own first-party
 * `com.dartnative.DartNativeAndroidPlugin` implements the same interface. It is
 * a registration hook only — no method channels are involved, and no Flutter
 * rendering. All Dart traffic still goes over FFI.
 *
 * Native views are a separate contract: implement `DNAndroidPluginProvider`
 * (`createView(Int)` / `handleMutation(Long, Int, ByteArray)`) for those, not
 * this class. Ad logic lives in AdsBridge.
 */
class GoogleMobileAdsKitPlugin : FlutterPlugin {

    companion object {
        /**
         * Registers [factory] so Dart can name it with `NativeAd(factoryId: ...)`.
         *
         * Call this before requesting any ad that uses [factoryId] — typically
         * from your Activity's `onCreate`:
         *
         * ```kotlin
         * GoogleMobileAdsKitPlugin.registerNativeAdFactory(
         *     this, "adFactoryExample", MyNativeAdFactory(layoutInflater))
         * ```
         *
         * Returns false, and registers nothing, if [factoryId] is already taken.
         *
         * ## Why this takes a Context
         *
         * Flutter's `google_mobile_ads` takes a `FlutterEngine` here, because it
         * looks the plugin instance up in the engine's plugin registry. DartNative
         * has no `FlutterEngine`, and the ad bridge is a singleton, so the
         * parameter is a plain `Context` instead. That is the only difference —
         * the factory interface and the Dart-side call are unchanged
         * (`doc/design.md` §8-5).
         *
         * The [context] is currently unused; it is part of the signature so that
         * the call site matches the Flutter one, and so a future implementation
         * can scope factories to a context without a breaking change.
         */
        @JvmStatic
        fun registerNativeAdFactory(
            context: Context,
            factoryId: String,
            factory: NativeAdFactory,
        ): Boolean = AdsBridge.addNativeAdFactory(factoryId, factory)

        /**
         * Removes the factory registered under [factoryId].
         *
         * Returns the factory that was registered, or null if there was none.
         * Ads already showing keep their views; only later requests are affected.
         */
        @JvmStatic
        fun unregisterNativeAdFactory(factoryId: String): NativeAdFactory? =
            AdsBridge.removeNativeAdFactory(factoryId)
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Triggers JNI_OnLoad in src/ads_bridge.cpp, which caches the JVM and
        // resolves AdsBridge's method IDs while the app's own class loader is
        // still the one in context.
        System.loadLibrary("google_mobile_ads_kit")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    }
}
