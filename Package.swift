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
    // Two third-party dependencies, both approved: Sparkle (updates — no feed / automatic checks off until Developer
    // ID) and SwiftyOpenCC (OpenCC, Traditional ⇄ Simplified Chinese lyrics). QTLyrics has its own
    // LRC/YRC/QRC/KRC/TTML parsers and decrypters (LyricsKit's are not public API). Ask the user before adding
    // anything else.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // 2.0.0-beta builds OpenCC from source (1.x links a system libopencc).
        .package(url: "https://github.com/ddddxxx/SwiftyOpenCC", exact: "2.0.0-beta"),
    ],
    targets: [
        .target(
            name: "QTCore",
            resources: [.process("Resources")]
        ),
        .target(name: "QTInnerTube", dependencies: ["QTCore"]),
        .target(name: "QTAuth", dependencies: ["QTInnerTube"]),
        .target(name: "QTPlayback", dependencies: ["QTCore", "QTInnerTube"]),
        .target(name: "QTLyrics", dependencies: ["QTCore", .product(name: "OpenCC", package: "SwiftyOpenCC")]),
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
        // Dev-only (DEBUG) M5 spike: native stream resolution + AVAudioEngine, muted. docs/native-engine-spike.md.
        .executableTarget(name: "QTNativeSpike", dependencies: ["QTPlayback", "QTAuth"]),

        .testTarget(name: "QTCoreTests", dependencies: ["QTCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTLyricsTests", dependencies: ["QTLyrics"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTInnerTubeTests", dependencies: ["QTInnerTube", "QTAuth"], resources: [.copy("Fixtures")]),
        .testTarget(name: "QTPlaybackTests", dependencies: ["QTPlayback"]),
        .testTarget(name: "QTUITests", dependencies: ["QTUI"]),
        .testTarget(name: "QTIntegrationsTests", dependencies: ["QTIntegrations"]),
    ],
    swiftLanguageModes: [.v6]
)
