#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_onnxruntime.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_onnxruntime'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  # Lowered from upstream's 16.0: onnxruntime-objc 1.22.0 itself only requires
  # iOS 15.1, and this lets the app run on devices that top out at iOS 15
  # (e.g. iPhone 6s/6s Plus). Vendored override of pub.dev flutter_onnxruntime 1.7.1.
  s.platform = :ios, '15.1'
  s.dependency 'onnxruntime-objc', '1.22.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '"${PODS_ROOT}/onnxruntime-objc/objectivec" "${PODS_ROOT}/onnxruntime-objc/objectivec/include"'
  }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_onnxruntime_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
