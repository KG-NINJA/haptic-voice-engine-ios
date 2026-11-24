// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HapticVoiceKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "HapticVoiceKit", targets: ["HapticVoiceKit"])],
    targets: [
        .target(name: "HapticVoiceKit"),
        .testTarget(name: "HapticVoiceKitTests", dependencies: ["HapticVoiceKit"]),
    ]
)
