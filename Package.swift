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
    targets: [
        .target(
            name: "SwiftExif",
            path: "Sources/SwiftExif"
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
