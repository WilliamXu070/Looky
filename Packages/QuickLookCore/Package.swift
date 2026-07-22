// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuickLookCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuickLookCore", targets: ["QuickLookCore"]),
    ],
    targets: [
        .target(name: "QuickLookCore"),
        .testTarget(name: "QuickLookCoreTests", dependencies: ["QuickLookCore"]),
    ]
)
