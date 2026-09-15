// JNI bridge between the Dart FFI entry points and the Kotlin AdsBridge.
//
// Dart cannot call Kotlin directly, so every call takes two hops:
//
//   Dart --(FFI, C ABI)--> this file --(JNI)--> AdsBridge.kt --> GMA SDK
//
// and events come back the other way:
//
//   GMA SDK --> AdsBridge.kt (hops to main) --(JNI)--> this file
//           --> the Dart dispatcher pointer
//
// The dispatcher pointer is never cached here: Kotlin passes it in on every
// delivery, having re-read its slot and checked the isolate generation, so a
// hot restart cannot dispatch into a dead isolate (doc/design.md §5-2).

#include <jni.h>

#include <android/log.h>

#include <cstdint>
#include <cstring>

#define LOG_TAG "dartnative_mobile_ads"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

JavaVM* g_vm = nullptr;

// Global ref to com.dartnative.mobile_ads.AdsBridge, plus its static methods.
// Resolved once in JNI_OnLoad, where the class loader is guaranteed to be the
// app's own — looking the class up later from an SDK thread would find only
// the system loader and fail.
jclass g_bridge_class = nullptr;
jmethodID g_initialize = nullptr;
jmethodID g_load_ad = nullptr;
jmethodID g_show_ad = nullptr;
jmethodID g_dispose_ad = nullptr;
jmethodID g_set_app_muted = nullptr;
jmethodID g_set_immersive_mode = nullptr;
jmethodID g_set_ssv = nullptr;
jmethodID g_preload_start = nullptr;
jmethodID g_preload_poll = nullptr;
jmethodID g_preload_is_available = nullptr;
jmethodID g_preload_num_available = nullptr;
jmethodID g_preload_destroy = nullptr;
jmethodID g_preload_destroy_all = nullptr;
jmethodID g_preload_read_json = nullptr;
jmethodID g_banner_create = nullptr;
jmethodID g_banner_dispose = nullptr;
jmethodID g_native_ad_create = nullptr;
jmethodID g_native_ad_dispose = nullptr;
jmethodID g_adaptive_banner_height = nullptr;

// The Dart-side callback: void (*)(int64_t token, int32_t status, const char* json).
using DartDispatch = void (*)(int64_t, int32_t, const char*);

// Returns a JNIEnv for the calling thread, attaching it if needed.
//
// Dart-originated calls arrive on the main thread, which is already attached.
// The deliver* path is called from Kotlin and is therefore attached too, but
// attaching defensively costs nothing and avoids a crash if that ever changes.
JNIEnv* GetEnv() {
  if (g_vm == nullptr) return nullptr;

  JNIEnv* env = nullptr;
  const jint rc = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (rc == JNI_OK) return env;
  if (rc != JNI_EDETACHED) return nullptr;
  if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
  return env;
}

// Clears any pending exception so it cannot leak across the FFI boundary into
// Dart, where it would abort the process rather than surface as an error.
void ClearPendingException(JNIEnv* env) {
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

// Wraps a jstring so it is always released, on every return path.
class ScopedUtf {
 public:
  ScopedUtf(JNIEnv* env, const char* value) : env_(env) {
    str_ = env->NewStringUTF(value != nullptr ? value : "");
  }
  ~ScopedUtf() {
    if (str_ != nullptr) env_->DeleteLocalRef(str_);
  }
  ScopedUtf(const ScopedUtf&) = delete;
  ScopedUtf& operator=(const ScopedUtf&) = delete;

  jstring get() const { return str_; }

 private:
  JNIEnv* env_;
  jstring str_ = nullptr;
};

bool BridgeReady() { return g_bridge_class != nullptr; }

// Looks up one static method on AdsBridge, clearing the failure if it is absent.
//
// A failed GetStaticMethodID leaves a NoSuchMethodError pending, and the *next*
// JNI call made with an exception pending aborts the process. So each lookup
// must clear its own — otherwise one method missing (a stale .so paired with a
// newer AdsBridge, or vice versa) takes the whole app down at startup instead of
// just disabling that one call. Every call site already null-checks its id.
jmethodID FindMethod(JNIEnv* env, const char* name, const char* signature) {
  jmethodID id = env->GetStaticMethodID(g_bridge_class, name, signature);
  if (id == nullptr) {
    // Clear without ExceptionDescribe: a missing method is reported once below,
    // and dumping a Java stack for it only buries the message.
    if (env->ExceptionCheck()) env->ExceptionClear();
    LOGE("AdsBridge.%s%s not found; that call will be inert", name, signature);
  }
  return id;
}

}  // namespace

// ---------------------------------------------------------------------------
// JNI lifecycle
// ---------------------------------------------------------------------------

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_vm = vm;

  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }

  jclass local = env->FindClass("com/dartnative/mobile_ads/AdsBridge");
  if (local == nullptr) {
    ClearPendingException(env);
    LOGE("AdsBridge class not found; ad calls will be inert");
    return JNI_VERSION_1_6;
  }

  g_bridge_class = static_cast<jclass>(env->NewGlobalRef(local));
  env->DeleteLocalRef(local);

  g_initialize = FindMethod(env, "initialize", "(J)V");
  g_load_ad =
      FindMethod(env, "loadAd", "(JILjava/lang/String;Ljava/lang/String;)V");
  g_show_ad = FindMethod(env, "showAd", "(J)V");
  g_dispose_ad = FindMethod(env, "disposeAd", "(J)V");
  g_set_app_muted = FindMethod(env, "setAppMuted", "(Z)V");
  g_set_immersive_mode = FindMethod(env, "setImmersiveMode", "(JZ)V");
  g_set_ssv = FindMethod(env, "setServerSideVerification",
                         "(JLjava/lang/String;Ljava/lang/String;)V");

  g_preload_start = FindMethod(
      env, "preloadStart",
      "(JILjava/lang/String;Ljava/lang/String;Ljava/lang/String;I)V");
  g_preload_poll = FindMethod(env, "preloadPoll", "(ILjava/lang/String;)J");
  g_preload_is_available =
      FindMethod(env, "preloadIsAdAvailable", "(ILjava/lang/String;)Z");
  g_preload_num_available =
      FindMethod(env, "preloadNumAdsAvailable", "(ILjava/lang/String;)I");
  g_preload_destroy =
      FindMethod(env, "preloadDestroy", "(ILjava/lang/String;)V");
  g_preload_destroy_all = FindMethod(env, "preloadDestroyAll", "(I)V");
  g_preload_read_json = FindMethod(env, "preloadReadJson",
                                   "(IILjava/lang/String;)Ljava/lang/String;");

  g_banner_create = FindMethod(
      env, "bannerCreate", "(JJLjava/lang/String;Ljava/lang/String;II)V");
  g_banner_dispose = FindMethod(env, "bannerDispose", "(J)V");
  g_native_ad_create = FindMethod(
      env, "nativeAdCreate",
      "(JJLjava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
  g_native_ad_dispose = FindMethod(env, "nativeAdDispose", "(J)V");
  g_adaptive_banner_height =
      FindMethod(env, "adaptiveBannerHeight", "(I)I");

  return JNI_VERSION_1_6;
}

// ---------------------------------------------------------------------------
// Dart -> native
// ---------------------------------------------------------------------------

#define DN_EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))

// Hands the Dart dispatcher pointer to Kotlin, which stores it in a slot
// alongside the current isolate generation.
DN_EXPORT void DNAdsSetDispatcher(int64_t callback_ptr) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady()) return;

  const jmethodID set_dispatcher =
      env->GetStaticMethodID(g_bridge_class, "setDispatcher", "(J)V");
  if (set_dispatcher == nullptr) {
    ClearPendingException(env);
    return;
  }
  env->CallStaticVoidMethod(g_bridge_class, set_dispatcher,
                            static_cast<jlong>(callback_ptr));
  ClearPendingException(env);
}

DN_EXPORT void DNAdsInitialize(int64_t token) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_initialize == nullptr) return;

  env->CallStaticVoidMethod(g_bridge_class, g_initialize,
                            static_cast<jlong>(token));
  ClearPendingException(env);
}

DN_EXPORT void DNAdsLoadAd(int64_t token, int32_t format, const char* ad_unit_id,
                           const char* request_json) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_load_ad == nullptr) return;

  ScopedUtf unit(env, ad_unit_id);
  ScopedUtf request(env, request_json);
  env->CallStaticVoidMethod(g_bridge_class, g_load_ad,
                            static_cast<jlong>(token),
                            static_cast<jint>(format), unit.get(),
                            request.get());
  ClearPendingException(env);
}

DN_EXPORT void DNAdsShowAd(int64_t token) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_show_ad == nullptr) return;

  env->CallStaticVoidMethod(g_bridge_class, g_show_ad,
                            static_cast<jlong>(token));
  ClearPendingException(env);
}

DN_EXPORT void DNAdsDisposeAd(int64_t token) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_dispose_ad == nullptr) return;

  env->CallStaticVoidMethod(g_bridge_class, g_dispose_ad,
                            static_cast<jlong>(token));
  ClearPendingException(env);
}

DN_EXPORT void DNAdsSetAppMuted(int32_t muted) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_set_app_muted == nullptr) return;

  env->CallStaticVoidMethod(g_bridge_class, g_set_app_muted,
                            muted != 0 ? JNI_TRUE : JNI_FALSE);
  ClearPendingException(env);
}

DN_EXPORT void DNAdsSetImmersiveMode(int64_t token, int32_t enabled) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_set_immersive_mode == nullptr) {
    return;
  }

  env->CallStaticVoidMethod(g_bridge_class, g_set_immersive_mode,
                            static_cast<jlong>(token),
                            enabled != 0 ? JNI_TRUE : JNI_FALSE);
  ClearPendingException(env);
}

DN_EXPORT void DNAdsSetServerSideVerification(int64_t token,
                                              const char* user_id,
                                              const char* custom_data) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_set_ssv == nullptr) return;

  ScopedUtf user(env, user_id);
  ScopedUtf data(env, custom_data);
  env->CallStaticVoidMethod(g_bridge_class, g_set_ssv,
                            static_cast<jlong>(token), user.get(), data.get());
  ClearPendingException(env);
}

// ---------------------------------------------------------------------------
// Banners
// ---------------------------------------------------------------------------

DN_EXPORT void DNAdsBannerCreate(int64_t token, int64_t view_id,
                                 const char* ad_unit_id,
                                 const char* request_json, int32_t width_dp,
                                 int32_t height_dp) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_banner_create == nullptr) return;

  ScopedUtf unit(env, ad_unit_id);
  ScopedUtf request(env, request_json);
  env->CallStaticVoidMethod(g_bridge_class, g_banner_create,
                            static_cast<jlong>(token),
                            static_cast<jlong>(view_id), unit.get(),
                            request.get(), static_cast<jint>(width_dp),
                            static_cast<jint>(height_dp));
  ClearPendingException(env);
}

DN_EXPORT void DNAdsBannerDispose(int64_t view_id) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_banner_dispose == nullptr) return;

  env->CallStaticVoidMethod(g_bridge_class, g_banner_dispose,
                            static_cast<jlong>(view_id));
  ClearPendingException(env);
}

// ---------------------------------------------------------------------------
// Native ads
// ---------------------------------------------------------------------------

DN_EXPORT void DNAdsNativeAdCreate(int64_t token, int64_t view_id,
                                   const char* ad_unit_id,
                                   const char* request_json,
                                   const char* options_json) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_native_ad_create == nullptr) return;

  ScopedUtf unit(env, ad_unit_id);
  ScopedUtf request(env, request_json);
  ScopedUtf options(env, options_json);
  env->CallStaticVoidMethod(g_bridge_class, g_native_ad_create,
                            static_cast<jlong>(token),
                            static_cast<jlong>(view_id), unit.get(),
                            request.get(), options.get());
  ClearPendingException(env);
}

DN_EXPORT void DNAdsNativeAdDispose(int64_t view_id) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_native_ad_dispose == nullptr) {
    return;
  }

  env->CallStaticVoidMethod(g_bridge_class, g_native_ad_dispose,
                            static_cast<jlong>(view_id));
  ClearPendingException(env);
}

DN_EXPORT int32_t DNAdsAdaptiveBannerHeight(int32_t width_dp) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() ||
      g_adaptive_banner_height == nullptr) {
    return 0;
  }

  const jint height = env->CallStaticIntMethod(
      g_bridge_class, g_adaptive_banner_height, static_cast<jint>(width_dp));
  if (env->ExceptionCheck()) {
    ClearPendingException(env);
    return 0;
  }
  return static_cast<int32_t>(height);
}

// ---------------------------------------------------------------------------
// Preloading
// ---------------------------------------------------------------------------

DN_EXPORT void DNAdsPreloadStart(int64_t token, int32_t format,
                                 const char* preload_id, const char* ad_unit_id,
                                 const char* request_json, int32_t buffer_size) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_start == nullptr) return;

  ScopedUtf id(env, preload_id);
  ScopedUtf unit(env, ad_unit_id);
  ScopedUtf request(env, request_json);
  env->CallStaticVoidMethod(g_bridge_class, g_preload_start,
                            static_cast<jlong>(token),
                            static_cast<jint>(format), id.get(), unit.get(),
                            request.get(), static_cast<jint>(buffer_size));
  ClearPendingException(env);
}

DN_EXPORT int64_t DNAdsPreloadPoll(int32_t format, const char* preload_id) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_poll == nullptr) return 0;

  ScopedUtf id(env, preload_id);
  const jlong token = env->CallStaticLongMethod(
      g_bridge_class, g_preload_poll, static_cast<jint>(format), id.get());
  if (env->ExceptionCheck()) {
    ClearPendingException(env);
    return 0;
  }
  return static_cast<int64_t>(token);
}

DN_EXPORT int32_t DNAdsPreloadIsAdAvailable(int32_t format,
                                            const char* preload_id) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_is_available == nullptr) {
    return 0;
  }

  ScopedUtf id(env, preload_id);
  const jboolean available = env->CallStaticBooleanMethod(
      g_bridge_class, g_preload_is_available, static_cast<jint>(format),
      id.get());
  if (env->ExceptionCheck()) {
    ClearPendingException(env);
    return 0;
  }
  return available == JNI_TRUE ? 1 : 0;
}

DN_EXPORT int32_t DNAdsPreloadNumAdsAvailable(int32_t format,
                                              const char* preload_id) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_num_available == nullptr) {
    return 0;
  }

  ScopedUtf id(env, preload_id);
  const jint count = env->CallStaticIntMethod(
      g_bridge_class, g_preload_num_available, static_cast<jint>(format),
      id.get());
  if (env->ExceptionCheck()) {
    ClearPendingException(env);
    return 0;
  }
  return static_cast<int32_t>(count);
}

DN_EXPORT void DNAdsPreloadDestroy(int32_t format, const char* preload_id) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_destroy == nullptr) return;

  ScopedUtf id(env, preload_id);
  env->CallStaticVoidMethod(g_bridge_class, g_preload_destroy,
                            static_cast<jint>(format), id.get());
  ClearPendingException(env);
}

DN_EXPORT void DNAdsPreloadDestroyAll(int32_t format) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_destroy_all == nullptr) {
    return;
  }

  env->CallStaticVoidMethod(g_bridge_class, g_preload_destroy_all,
                            static_cast<jint>(format));
  ClearPendingException(env);
}

// Copies a preloader JSON document into the caller's buffer.
//
// Returns the byte count written, 0 when there is nothing to report, or the
// negative required capacity when `capacity` is too small. Dart owns the
// buffer, so nothing has to be freed across the FFI boundary.
DN_EXPORT int32_t DNAdsPreloadReadJson(int32_t format, int32_t query,
                                       const char* preload_id, uint8_t* buffer,
                                       int32_t capacity) {
  JNIEnv* env = GetEnv();
  if (env == nullptr || !BridgeReady() || g_preload_read_json == nullptr) {
    return 0;
  }

  ScopedUtf id(env, preload_id);
  auto json = static_cast<jstring>(env->CallStaticObjectMethod(
      g_bridge_class, g_preload_read_json, static_cast<jint>(format),
      static_cast<jint>(query), id.get()));
  if (env->ExceptionCheck()) {
    ClearPendingException(env);
    return 0;
  }
  if (json == nullptr) return 0;

  const jsize length = env->GetStringUTFLength(json);
  if (length <= 0) {
    env->DeleteLocalRef(json);
    return 0;
  }
  if (length > capacity) {
    env->DeleteLocalRef(json);
    return -length;
  }

  const char* utf = env->GetStringUTFChars(json, nullptr);
  if (utf != nullptr) {
    std::memcpy(buffer, utf, static_cast<size_t>(length));
    env->ReleaseStringUTFChars(json, utf);
  }
  env->DeleteLocalRef(json);
  return static_cast<int32_t>(length);
}

// ---------------------------------------------------------------------------
// Native -> Dart
// ---------------------------------------------------------------------------

// Invokes the Dart dispatcher.
//
// Kotlin calls this only from the main thread, and only after confirming that
// `dispatcher_ptr` is the live isolate's — see AdsBridge.deliver. Dart's
// `Pointer.fromFunction` callbacks must run on the owning isolate's thread.
extern "C" JNIEXPORT void JNICALL
Java_com_dartnative_mobile_1ads_AdsBridge_nativeDeliver(
    JNIEnv* env, jclass /*clazz*/, jlong dispatcher_ptr, jlong token,
    jint status, jstring payload) {
  if (dispatcher_ptr == 0) return;

  const char* utf = nullptr;
  if (payload != nullptr) {
    utf = env->GetStringUTFChars(payload, nullptr);
  }

  auto dispatch = reinterpret_cast<DartDispatch>(
      static_cast<intptr_t>(dispatcher_ptr));
  dispatch(static_cast<int64_t>(token), static_cast<int32_t>(status),
           utf != nullptr ? utf : "");

  if (utf != nullptr) {
    env->ReleaseStringUTFChars(payload, utf);
  }
}

// Hot restart is handled entirely on the Kotlin side: the engine calls the hook
// registered with DNViewRegistry.registerResetHook before it tears the old
// isolate down, and AdsBridge zeroes its dispatcher slot there. Since this file
// never caches the pointer — Kotlin passes it in on every delivery, after
// re-reading the slot — there is nothing to invalidate here.
