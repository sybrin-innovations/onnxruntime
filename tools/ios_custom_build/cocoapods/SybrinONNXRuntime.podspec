Pod::Spec.new do |spec|
  spec.name = "SybrinONNXRuntime"
  spec.version = "1.27.0-custom.1"

  spec.summary = "Custom ONNX Runtime build for Sybrin iOS SDKs."

  spec.description = <<-DESC
    A reduced static ONNX Runtime XCFramework built by Sybrin Innovations.
    The runtime contains the standard and custom operators required by
    Sybrin's supported document detection models.
  DESC

  spec.homepage = "https://github.com/sybrin-innovations/onnxruntime"

  spec.license = {
    type: "MIT",
    file: "LICENSE"
  }

  spec.authors = {
    "Sybrin Innovations" => "support@sybrin.com"
  }

  spec.platform = :ios, "15.0"

  spec.source = {
    http: "https://github.com/sybrin-innovations/onnxruntime/releases/download/ios-1.27.0-custom.1/onnxruntime-ios-custom-1.27.0-custom.1.zip"
  }

  spec.vendored_frameworks = "onnxruntime.xcframework"
  spec.static_framework = true
  spec.requires_arc = true

  spec.frameworks = [
    "Foundation"
  ]

  spec.libraries = [
    "c++"
  ]

  spec.pod_target_xcconfig = {
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++17"
  }
end
