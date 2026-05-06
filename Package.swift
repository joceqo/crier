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
        .executable(name: "crier-keystroke-receiver", targets: ["CrierKeystrokeReceiver"]),
        .library(name: "CrierServer", targets: ["CrierServer"]),
        .library(name: "CrierEmitCore", targets: ["CrierEmitCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/madebywindmill/MarkdownToAttributedString.git", branch: "main"),
        // swift-markdown — Apple's official CommonMark-compatible parser.
        // Already transitive via MarkdownToAttributedString; declared
        // explicitly here so MarkdownContent.swift can import the
        // `Markdown` module directly and walk the AST itself.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/JohnSundell/Splash.git", from: "0.16.0"),
        // HighlighterSwift wraps highlight.js (~190 languages) — actively
        // maintained fork (Highlightr is unmaintained as of 2026). Same
        // NSAttributedString output, current highlight.js 11.x grammars.
        // Used for non-Swift code blocks where Splash can't help.
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", from: "1.1.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "CrierServer",
            dependencies: [
                "CrierEmitCore",
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
                "CrierEmitCore",
                "CrierServer",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownToAttributedString", package: "MarkdownToAttributedString"),
                .product(name: "Splash", package: "Splash"),
                .product(name: "Highlighter", package: "HighlighterSwift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/CrierUI",
            resources: [
                // Same SVGs as scripts/build-app.zip → Crier.app (repo: assets/icons).
                .copy("../../assets/icons"),
            ],
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"],
                    .when(platforms: [.macOS])
                ),
            ]
        ),
        .executableTarget(
            name: "CrierEmit",
            dependencies: ["CrierEmitCore"],
            path: "Sources/CrierEmit"
        ),
        .executableTarget(name: "CrierWrap", path: "Sources/CrierWrap"),
        .executableTarget(
            name: "CrierKeystrokeReceiver",
            path: "Sources/CrierKeystrokeReceiver"
        ),
        .testTarget(
            name: "CrierEmitCoreTests",
            dependencies: ["CrierEmitCore"],
            path: "Tests/CrierEmitCoreTests"
        ),
        .testTarget(
            name: "CrierServerTests",
            dependencies: ["CrierServer"],
            path: "Tests/CrierServerTests"
        ),
        .testTarget(
            name: "CrierEmitIntegrationTests",
            dependencies: ["CrierServer", "CrierEmitCore"],
            path: "Tests/CrierEmitIntegrationTests"
        ),
        .testTarget(
            name: "CrierE2ETests",
            dependencies: ["CrierServer"],
            path: "Tests/CrierE2ETests"
        ),
        .testTarget(
            name: "CrierKeystrokeE2ETests",
            path: "Tests/CrierKeystrokeE2ETests"
        ),
    ]
)
