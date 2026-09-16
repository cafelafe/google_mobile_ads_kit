#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint google_mobile_ads_kit.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'google_mobile_ads_kit'
  s.version          = '0.1.0'
  s.summary          = 'Google Mobile Ads (AdMob) for DartNative apps.'
  s.description      = <<-DESC
Google Mobile Ads (AdMob) for DartNative apps. Wraps the native Google Mobile
Ads SDK over dart:ffi — no platform channels. The API follows google_mobile_ads.
                       DESC
  s.homepage         = 'https://github.com/cafelafe/google_mobile_ads_kit'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'cafelafe'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  # iOS 15 because Xcode 27 refuses to build anything older ("the range of
  # supported deployment target versions is 15.0 to 27.0.x"), not because the
  # SDK needs it — Google-Mobile-Ads-SDK 13.x itself still declares 12.0.
  # Raising this is what the toolchain permits; see doc/design.md §1-2.
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  s.frameworks       = 'Foundation', 'UIKit', 'AdSupport', 'AppTrackingTransparency'

  # Declaring this dependency puts the build on the CocoaPods + xcodebuild path
  # rather than the fast direct-swiftc path, which is why `dn plugin build`
  # requires macOS + Xcode for this plugin (doc/design.md §11).
  #
  # Pinned to v13: v12 renamed the Swift API from GADMobileAds to MobileAds and
  # GMAKMobileAds.swift is written against the new spelling (doc/design.md §9-2).
  s.dependency 'Google-Mobile-Ads-SDK', '~> 13.0'

  # Required because the Mobile Ads SDK (and the User Messaging Platform it
  # pulls in) ship as static frameworks. Without this, an app using
  # `use_frameworks!` fails at `pod install` with "has transitive dependencies
  # that include statically linked binaries" — it never reaches a compiler.
  # `google_mobile_ads` declares the same thing for the same reason.
  s.static_framework = true

  # The @_cdecl entry points have no compile-time references — Dart looks them
  # up at runtime — so the Release linker would otherwise strip them.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'DEAD_CODE_STRIPPING' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
