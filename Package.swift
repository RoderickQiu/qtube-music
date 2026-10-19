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
    // One third-party dependency: Sparkle (approved; updates — no feed / automatic checks off until Developer ID).
    // QTLyrics has its own LRC/YRC/QRC/KRC/TTML parsers and decrypters (LyricsKit's are not public API).
    // Ask the user before adding anything else.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "QTCore",
            resources: [.process("Resources")]
        ),
        .target(name: "QTInnerTube", dependencies: ["QTCore"]),
        .target(name: "QTAuth", dependencies: ["QTInnerTube"]),
        .target(name: "QTPlayback", dependencies: ["QTCore", "QTInnerTube"]),
        .target(name: "QTLyrics", dependencies: ["QTCore"]),
        // Opt-in integrations (spec §10): Last.fm scrobbling, Discord Rich Presence. Off by default; nothing is sent
        // until the user turns one on in Settings › Integrations.
        .target(name: "QTIntegrations", dependencies: ["QTCore"]),
        .target(
            name: "QTUI",
            dependencies: ["QTCore", "QTInnerTube", "QTAuth", "QTPlayback", "QTLyrics", "QTIntegrations"]
        ),
        // App Intents + AppleScript terminology + Sparkle live in the app target; `Resources/` (sdef, intent
        // String Catalogs) is copied/compiled into the bundle by Scripts/build-app.sh.
        .executableTarget(
            name: "QTubeMusicApp",
            dependencies: ["QTUI", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Resources"]
        ),
        // Dev-only harness: drives QTWebPlaybackEngine live (anonymous, silent). `swift run QTPlaybackLab --help`.
        .executableTarget(name: "QTPlaybackLab", dependencies: ["QTPlayback"]),
        // Dev-only (DEBUG): import/inspect the shared dev session (HANDOFF §8). `swift run QTDevSession status`.
        .executableTarget(name: "QTDevSession", dependencies: ["QTAuth"]),

        .testTarget(name: "QTCoreTests", dependencies: ["QTCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTLyricsTests", dependencies: ["QTLyrics"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTInnerTubeTests", dependencies: ["QTInnerTube", "QTAuth"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTPlaybackTests", dependencies: ["QTPlayback"]),
        .testTarget(name: "QTUITests", dependencies: ["QTUI"]),
        .testTarget(name: "QTIntegrationsTests", dependencies: ["QTIntegrations"]),
    ],
    swiftLanguageModes: [.v6]
)
