# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(dartnative_mobile_ads_library VERSION 0.1.0 LANGUAGES CXX)

# The bridge is C++ (not C, unlike the plugin_ffi template): JNI is far less
# error-prone with RAII around local references and the JNIEnv attach/detach
# dance. The exported entry points are still extern "C".
add_library(dartnative_mobile_ads SHARED
  "ads_bridge.cpp"
)

set_target_properties(dartnative_mobile_ads PROPERTIES
  OUTPUT_NAME "dartnative_mobile_ads"
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
)

target_compile_definitions(dartnative_mobile_ads PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # `log` for __android_log_print; the JNI symbols themselves come from the
  # NDK's libc, which is linked by default.
  find_library(log-lib log)
  target_link_libraries(dartnative_mobile_ads ${log-lib})

  # Support Android 15 16k page size.
  target_link_options(dartnative_mobile_ads PRIVATE "-Wl,-z,max-page-size=16384")
endif()
