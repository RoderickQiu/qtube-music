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
    /// YouTube Music's web player in a headless WKWebView, ads included (free accounts; Premium until native ships).
    case web
    /// Native stream playback with gapless/crossfade/EQ/visualizer (Premium; M5 spike).
    case native
}

/// Picks the engine for an account (draft §11): free → web, Premium → native when available, else web;
/// mock data → simulated. Capabilities come from the chosen engine and drive UI greying.
public enum QTPlaybackEngineSelector {
    public static func kind(tier: QTPlaybackAccountTier, usesMockData: Bool,
                            nativeAvailable: Bool = QTNativePlaybackEngine.isAvailable) -> QTPlaybackEngineKind {
        if usesMockData { return .simulated }
        return tier == .premium && nativeAvailable ? .native : .web
    }

    /// Capabilities the UI should assume before an engine exists (e.g. Settings while signed out).
    public static func capabilities(of kind: QTPlaybackEngineKind, tier: QTPlaybackAccountTier) -> QTPlaybackCapabilities {
        switch kind {
        case .native: .premium
        case .web: .free
        case .simulated: tier == .premium ? .premium : .free
        }
    }

    @MainActor
    public static func makeEngine(_ kind: QTPlaybackEngineKind, tier: QTPlaybackAccountTier) -> any QTPlaybackEngine {
        switch kind {
        case .simulated: QTSimulatedPlaybackEngine(account: tier == .premium ? .premium : .free)
        case .web: QTWebPlaybackEngine()
        case .native: QTNativePlaybackEngine()
        }
    }
}

/// Premium engine placeholder until the M5 spike (stream resolution + `AVQueuePlayer`/`AVAudioEngine`).
/// `isAvailable` is false, so the selector never picks it yet; loading fails cleanly if forced.
@MainActor
public final class QTNativePlaybackEngine: QTPlaybackEngine {
    public nonisolated static let isAvailable = false

    public var capabilities: QTPlaybackCapabilities { .premium }
    public private(set) var state = QTPlaybackState()
    private var continuations: [UUID: AsyncStream<QTPlaybackState>.Continuation] = [:]

    public init() {}

    public func stateUpdates() -> AsyncStream<QTPlaybackState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<QTPlaybackState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations[id] = nil } }
        return stream
    }

    public func load(_ item: QTPlaybackItem, autoplay: Bool) async throws {
        state = QTPlaybackState(item: item, status: .failed(.engine("native engine not available")),
                                volume: state.volume, isMuted: state.isMuted)
        for c in continuations.values { c.yield(state) }
        throw QTPlaybackError.engine("native engine not available")
    }

    public func play() {}
    public func pause() {}
    public func seek(to time: TimeInterval) {}
    public func setVolume(_ volume: Double) { state.volume = min(1, max(0, volume)) }
    public func setMuted(_ muted: Bool) { state.isMuted = muted }
    public func skipAd() {}
    public func stop() { state = QTPlaybackState(volume: state.volume, isMuted: state.isMuted) }
}
