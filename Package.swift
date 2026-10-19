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
    dependencies: [
        // MPL-2.0. Lyrics parsers/providers (NetEase, QQ QRC, Kugou KRC, LRCLIB). Used only by QTLyrics.
        .package(url: "https://github.com/MxIris-LyricsX-Project/LyricsKit", from: "1.9.0"),
    ],
    targets: [
        .target(
            name: "QTCore",
            resources: [.process("Resources")]
        ),
        .target(name: "QTInnerTube", dependencies: ["QTCore"]),
        .target(name: "QTAuth", dependencies: ["QTInnerTube"]),
        .target(name: "QTPlayback", dependencies: ["QTCore", "QTInnerTube"]),
        .target(
            name: "QTLyrics",
            dependencies: ["QTCore", .product(name: "LyricsKit", package: "LyricsKit")]
        ),
        .target(
            name: "QTUI",
            dependencies: ["QTCore", "QTInnerTube", "QTAuth", "QTPlayback", "QTLyrics"]
        ),
        .executableTarget(name: "QTubeMusicApp", dependencies: ["QTUI"]),

        .testTarget(name: "QTCoreTests", dependencies: ["QTCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTLyricsTests", dependencies: ["QTLyrics"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTInnerTubeTests", dependencies: ["QTInnerTube"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTPlaybackTests", dependencies: ["QTPlayback"]),
        .testTarget(name: "QTUITests", dependencies: ["QTUI"]),
    ],
    swiftLanguageModes: [.v6]
)
