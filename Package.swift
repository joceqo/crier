// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Crier",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "crier-daemon", targets: ["CrierDaemon"]),
        .executable(name: "crier-ui", targets: ["CrierUI"]),
        .executable(name: "crier-emit", targets: ["CrierEmit"]),
        .executable(name: "crier-wrap", targets: ["CrierWrap"]),
        .library(name: "CrierServer", targets: ["CrierServer"]),
        .library(name: "CrierEmitCore", targets: ["CrierEmitCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/zats/permiso.git", branch: "main"),
        .package(url: "https://github.com/madebywindmill/MarkdownToAttributedString.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "CrierServer",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/CrierServer"
        ),
        .target(
            name: "CrierEmitCore",
            path: "Sources/CrierEmitCore"
        ),
        .executableTarget(
            name: "CrierDaemon",
            dependencies: ["CrierServer"],
            path: "Sources/CrierDaemon"
        ),
        .executableTarget(
            name: "CrierUI",
            dependencies: [
                "CrierServer",
                .product(name: "Permiso", package: "permiso"),
                .product(name: "MarkdownToAttributedString", package: "MarkdownToAttributedString"),
            ],
            path: "Sources/CrierUI"
        ),
        .executableTarget(
            name: "CrierEmit",
            dependencies: ["CrierEmitCore"],
            path: "Sources/CrierEmit"
        ),
        .executableTarget(name: "CrierWrap", path: "Sources/CrierWrap"),
        .testTarget(
            name: "CrierEmitCoreTests",
            dependencies: ["CrierEmitCore"],
            path: "Tests/CrierEmitCoreTests"
        ),
    ]
)
