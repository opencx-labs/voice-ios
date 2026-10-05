# OpenCXVoice

Voice calling for OpenCX in iOS apps. iOS 15 or later is required.

This is an opt-in preview. Your organization needs access enabled and a compatible OpenCX backend deployment. Public availability requires a published version tag.

Once a release is available, add `https://github.com/opencx-labs/voice-ios` in Xcode's package dependencies and select the corresponding version. Add the `OpenCXVoice` product to your app.

Include `NSMicrophoneUsageDescription` in your app settings. Your authenticated server creates the call credentials; never put your OpenCX API key in the app.

See the [integration guide](https://docs.open.cx/phone/voice-sdk) for authentication, call controls, and lifecycle requirements.

Licensed under MIT. See [LICENSE](LICENSE).
