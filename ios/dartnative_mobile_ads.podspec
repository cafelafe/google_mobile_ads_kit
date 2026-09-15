#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint dartnative_mobile_ads.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'dartnative_mobile_ads'
  s.version          = '0.1.0'
  s.summary          = 'Google Mobile Ads (AdMob) for DartNative apps.'
  s.description      = <<-DESC
Google Mobile Ads (AdMob) for DartNative apps. Wraps the native Google Mobile
Ads SDK over dart:ffi — no platform channels. The API follows google_mobile_ads.
                       DESC
  s.homepage         = 'https://github.com/cafelafe/dartnative_mobile_ads'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'cafelafe'

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'

  # iOS 13 is the Google Mobile Ads SDK v13 floor and matches the plugin's
  # declared minimum (doc/design.md §1-2).
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'

  s.frameworks       = 'Foundation', 'UIKit', 'AdSupport', 'AppTrackingTransparency'

  # Declaring this dependency puts the build on the CocoaPods + xcodebuild path
  # rather than the fast direct-swiftc path, which is why `dn plugin build`
  # requires macOS + Xcode for this plugin (doc/design.md §11).
  #
  # Pinned to v13: v12 renamed the Swift API from GADMobileAds to MobileAds and
  # DNMobileAds.swift is written against the new spelling (doc/design.md §9-2).
  s.dependency 'Google-Mobile-Ads-SDK', '~> 13.0'

  # The @_cdecl entry points have no compile-time references — Dart looks them
  # up at runtime — so the Release linker would otherwise strip them.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'DEAD_CODE_STRIPPING' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
