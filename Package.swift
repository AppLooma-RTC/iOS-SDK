// swift-tools-version:5.9
// AppLooma RTC iOS SDK — © AppLooma LLC
import PackageDescription

let package = Package(
    name: "AppLoomaRTC",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(name: "AppLoomaRTC", targets: ["AppLoomaRTC"])
    ],
    dependencies: [
        // Media transport layer
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "AppLoomaRTC",
            dependencies: [.product(name: "LiveKit", package: "client-sdk-swift")],
            path: "Sources/AppLoomaRTC"
        )
    ]
)
