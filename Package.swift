// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AceServer",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        // 🍃 APNs for Push Notifications
        .package(url: "https://github.com/vapor/apns.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporAPNS", package: "apns"),
            ],
            swiftSettings: [
                // Enable better concurrency checks
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
