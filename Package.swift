// swift-tools-version: 6.0

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
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SwiftExif",
            path: "Sources/SwiftExif"
        ),
        .executableTarget(
            name: "swift-exif",
            dependencies: [
                "SwiftExif",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "Benchmark",
            dependencies: ["SwiftExif"],
            path: "Sources/Benchmark"
        ),
        .testTarget(
            name: "SwiftExifTests",
            dependencies: ["SwiftExif"],
            path: "Tests/SwiftExifTests"
        ),
    ]
)
