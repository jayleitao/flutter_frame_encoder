Pod::Spec.new do |s|
  s.name             = 'frame_encoder'
  s.version          = '0.1.0'
  s.summary          = 'Encode Flutter frames into an H.264 MP4 with AVAssetWriter.'
  s.homepage         = 'https://github.com/jayleitao/frame_encoder'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'jayleitao' => 'https://github.com/jayleitao' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'AVFoundation', 'Accelerate', 'CoreVideo'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
