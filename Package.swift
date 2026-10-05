// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OpenCXVoice",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "OpenCXVoice", targets: ["OpenCXVoice"])],
    dependencies: [.package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.17.0")],
    targets: [
        .target(name: "OpenCXVoice", dependencies: [.product(name: "LiveKit", package: "client-sdk-swift")]),
        .testTarget(name: "OpenCXVoiceTests", dependencies: ["OpenCXVoice"])
    ]
)
