// swift-tools-version: 6.2
// QTube Music — native macOS YouTube Music client. Module map and ownership: docs/architecture.md.
import PackageDescription

let package = Package(
    name: "QTubeMusic",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "QTubeMusic", targets: ["QTubeMusicApp"]),
    ],
    // No third-party dependencies. QTLyrics has its own LRC/YRC/QRC/KRC/TTML parsers and decrypters
    // (LyricsKit's are not public API). Sparkle comes later (ask first for anything else).
    dependencies: [],
    targets: [
        .target(
            name: "QTCore",
            resources: [.process("Resources")]
        ),
        .target(name: "QTInnerTube", dependencies: ["QTCore"]),
        .target(name: "QTAuth", dependencies: ["QTInnerTube"]),
        .target(name: "QTPlayback", dependencies: ["QTCore", "QTInnerTube"]),
        .target(name: "QTLyrics", dependencies: ["QTCore"]),
        .target(
            name: "QTUI",
            dependencies: ["QTCore", "QTInnerTube", "QTAuth", "QTPlayback", "QTLyrics"]
        ),
        .executableTarget(name: "QTubeMusicApp", dependencies: ["QTUI"]),
        // Dev-only harness: drives QTWebPlaybackEngine live (anonymous, silent). `swift run QTPlaybackLab --help`.
        .executableTarget(name: "QTPlaybackLab", dependencies: ["QTPlayback"]),
        // Dev-only (DEBUG): import/inspect the shared dev session (HANDOFF §8). `swift run QTDevSession status`.
        .executableTarget(name: "QTDevSession", dependencies: ["QTAuth"]),

        .testTarget(name: "QTCoreTests", dependencies: ["QTCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTLyricsTests", dependencies: ["QTLyrics"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTInnerTubeTests", dependencies: ["QTInnerTube", "QTAuth"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTPlaybackTests", dependencies: ["QTPlayback"]),
        .testTarget(name: "QTUITests", dependencies: ["QTUI"]),
    ],
    swiftLanguageModes: [.v6]
)
