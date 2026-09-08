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
        .package(url: "https://github.com/apploomadev/iOS-Core.git", from: "2.12.0")
    ],
    targets: [
        .target(
            name: "AppLoomaRTC",
            dependencies: [.product(name: "AppLoomaCore", package: "iOS-Core")],
            path: "Sources/AppLoomaRTC"
        )
    ]
)
