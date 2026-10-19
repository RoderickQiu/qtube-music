import Foundation
import Observation
import QTAuth
import QTCore
import QTPlayback

// Owner: builder "native-engine". Decides when the native Premium engine plays (docs/native-engine-spike.md,
// option B, approved 2026-10-19): Settings › Premium engine › Native engine is on (or `-qt.playback.native YES` for
// the session), the account is signed in and Premium, and the app plays real data with the user's session. Anything
// else plays through YouTube's player, exactly as before. The swap keeps the queue and the position
// (`QTQueueController.replaceEngine`), and the web engine object stays the same one, wrapped or not, so its page,
// video surface and hooks carry over.
// Also feeds the engine the Gapless / Crossfade / Equalizer settings.

@MainActor
public final class QTNativeEngineCoordinator {
    public static let shared = QTNativeEngineCoordinator()

    private weak var model: QTAppModel?
    private var swapTask: Task<Void, Never>?

    private init() {}

    /// Called once from `QTPlaybackServices.install`.
    func install(model: QTAppModel) {
        self.model = model
        observe()
        sync()
    }

    /// The native engine, when it is the one playing.
    public var engine: QTNativePlaybackEngine? { model?.player.engine as? QTNativePlaybackEngine }

    /// Whether the account could use the native engine (Premium, signed in, real data) — Settings enables the
    /// opt-in from this.
    public var isEligible: Bool {
        guard let model, let setup = QTPlaybackServices.shared.setup else { return false }
        guard setup.source == .live, setup.engine == .web, !setup.isAnonymous else { return false }
        guard model.launch.account != .free, model.account == .premium else { return false }
        let auth = QTLiveCatalogStore.shared.auth
        guard case .signedIn(_, let premium) = auth.state else { return false }
        return premium || auth.account?.isPremium == true
    }

    private var wantsNative: Bool {
        guard let model else { return false }
        return model.settings.settings.playbackEffects.nativeEngine && isEligible
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.settings.settings.playbackEffects
            _ = model.account
            _ = QTLiveCatalogStore.shared.auth.state
            _ = QTLiveCatalogStore.shared.auth.account
            _ = model.player.engine
        } onChange: {
            Task { @MainActor in
                QTNativeEngineCoordinator.shared.sync()
                QTNativeEngineCoordinator.shared.observe()
            }
        }
    }

    private func sync() {
        guard let model else { return }
        let playback = model.player.playback
        if let native = playback.engine as? QTNativePlaybackEngine {
            native.effects = Self.effects(model.settings.settings.playbackEffects)
        }
        guard swapTask == nil else { return }
        let current = playback.engine
        if wantsNative, current is QTWebPlaybackEngine, let web = current.webEngine {
            let store = QTLiveCatalogStore.shared.auth.sessionStore
            let native = QTNativePlaybackEngine(web: web, credentials: { await store.credentials() })
            native.effects = Self.effects(model.settings.settings.playbackEffects)
            swapTask = Task { @MainActor [weak self] in
                await playback.replaceEngine(native)
                self?.swapTask = nil
                self?.sync()
            }
        } else if !wantsNative, let native = current as? QTNativePlaybackEngine {
            swapTask = Task { @MainActor [weak self] in
                await playback.replaceEngine(native.web)
                native.shutdownNative()
                self?.swapTask = nil
                self?.sync()
            }
        }
    }

    static func effects(_ prefs: QTPlaybackEffectsPrefs) -> QTNativeEffects {
        QTNativeEffects(gapless: prefs.gapless, crossfadeSeconds: prefs.crossfadeSeconds, equalizer: prefs.equalizer)
    }
}
