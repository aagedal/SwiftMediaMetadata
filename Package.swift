// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftExif",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "SwiftExif",
            targets: ["SwiftExif"]
        ),
    ],
    targets: [
        .target(
            name: "SwiftExif",
            path: "Sources/SwiftExif"
        ),
        .testTarget(
            name: "SwiftExifTests",
            dependencies: ["SwiftExif"],
            path: "Tests/SwiftExifTests"
        ),
    ]
)
