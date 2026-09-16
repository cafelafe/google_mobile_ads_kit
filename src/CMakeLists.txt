# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(google_mobile_ads_kit_library VERSION 0.1.0 LANGUAGES CXX)

# The bridge is C++ (not C, unlike the plugin_ffi template): JNI is far less
# error-prone with RAII around local references and the JNIEnv attach/detach
# dance. The exported entry points are still extern "C".
add_library(google_mobile_ads_kit SHARED
  "ads_bridge.cpp"
)

set_target_properties(google_mobile_ads_kit PROPERTIES
  OUTPUT_NAME "google_mobile_ads_kit"
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(google_mobile_ads_kit PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # `log` for __android_log_print; the JNI symbols themselves come from the
  # NDK's libc, which is linked by default.
  find_library(log-lib log)
  target_link_libraries(google_mobile_ads_kit ${log-lib})

  # Support Android 15 16k page size.
  target_link_options(google_mobile_ads_kit PRIVATE "-Wl,-z,max-page-size=16384")
endif()
