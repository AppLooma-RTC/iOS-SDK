// swift-tools-version:5.9
// Lio Live iOS SDK — © AppLooma LLC
import PackageDescription

let package = Package(
    name: "LioRTC",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "LioRTC", targets: ["LioRTC"])
    ],
    dependencies: [
        // Media engine (internal implementation detail)
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "LioRTC",
            dependencies: [.product(name: "LiveKit", package: "client-sdk-swift")],
            path: "Sources/LioRTC"
        )
    ]
)
