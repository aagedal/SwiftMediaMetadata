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
        // Pure modulemap for zlib — no `pkgConfig` because that drags in
        // Homebrew's macOS libz.a during Linux-musl cross-compile. The
        // musl SDK's libz.a is passed via `-Xlinker` in Scripts/build-release.sh.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.brew(["zlib"]), .apt(["zlib1g-dev"])]
        ),
        .target(
            name: "SwiftExif",
            dependencies: ["CZlib"],
            path: "Sources/SwiftExif",
            linkerSettings: [
                // `-lz` is enough on macOS (default sysroot search finds libz).
                // For Linux-musl we pass the absolute libz.a path in the build
                // script — see Scripts/build-release.sh.
                .linkedLibrary("z", .when(platforms: [.macOS, .iOS]))
            ]
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
