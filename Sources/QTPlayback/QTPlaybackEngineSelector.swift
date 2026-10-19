import Foundation
import QTCore

/// The account's YouTube Music tier as far as playback cares.
public enum QTPlaybackAccountTier: String, Sendable, Hashable, Codable {
    case free, premium
}

/// Which engine plays.
public enum QTPlaybackEngineKind: String, Sendable, Hashable, CaseIterable {
    /// Clock-driven fake for mock data (screenshots, UI work, tests).
    case simulated
    /// YouTube Music's web player in a headless WKWebView, ads included (free accounts; Premium unless opted in).
    case web
    /// Native stream playback with gapless/crossfade/EQ/visualizer, wrapping the web engine for videos and fallback
    /// (Premium, opt-in: Settings › Premium engine).
    case native
}

/// Picks the engine (draft §11): mock data → simulated; real data → web, or native for a Premium account that opted
/// in. Capabilities come from the chosen engine and drive UI greying.
public enum QTPlaybackEngineSelector {
    public static func kind(tier: QTPlaybackAccountTier, usesMockData: Bool, nativeOptIn: Bool = false,
                            nativeAvailable: Bool = QTNativePlaybackEngine.isAvailable) -> QTPlaybackEngineKind {
        if usesMockData { return .simulated }
        return tier == .premium && nativeOptIn && nativeAvailable ? .native : .web
    }

    /// Capabilities the UI should assume before an engine exists (e.g. Settings while signed out).
    public static func capabilities(of kind: QTPlaybackEngineKind, tier: QTPlaybackAccountTier) -> QTPlaybackCapabilities {
        switch kind {
        case .native: .premium
        case .web: .web
        case .simulated: tier == .premium ? .premium : .free
        }
    }
}
