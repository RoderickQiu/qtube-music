import AppKit
import Observation
import QTCore
import QTInnerTube
import QTPlayback

// Owner: builder "stage-video" (M5). Song⇄Video as app behaviour, independent of which surface is on screen.

/// Keeps the loaded rendition in step with the listener's choice and owns Picture in Picture.
///
/// - `model.isVideoMode` is the intent (the Song | Video switch, ⇧⌘V, the Stage's Video swatch, "Play Music
///   Video"); it starts from Settings › "Prefer videos when available" and follows that setting when it changes.
///   The queue's `preferredMode` follows it, so every new track starts as its video when it has one.
/// - Switching reloads the counterpart at the same position (`QTQueueController.setMode`); the queue never changes.
/// - Counterparts for tracks that don't carry one come from InnerTube, read-only, for the current and the next track:
///   `next` (with the session when signed in — the same read the web player makes; only signed-in answers carry
///   counterparts), then a conservative search that is always anonymous (`QTInnerTubeClient.counterpart(for:)`;
///   a signed-in search would land in the account's search history).
/// - ⇧⌘P: native Picture in Picture of the music video (switches to Video first when the song is showing).
@MainActor
public final class QTVideoModeService {
    public static let shared = QTVideoModeService()

    private weak var model: QTAppModel?
    private var lastPreferVideos: Bool?
    private var pipTask: Task<Void, Never>?

    private init() {}

    /// Called once from `QTAppModel.bootstrap`.
    public func install(model: QTAppModel) {
        self.model = model
        let playback = model.player.playback
        playback.preferredMode = model.isVideoMode ? .video : .song
        lastPreferVideos = model.settings.settings.preferVideos
        let live = QTLiveCatalogStore.shared
        playback.counterpartResolver = { track in
            // Real YouTube ids only (demo tracks carry their music video already).
            guard track.videoId.count == 11 else { return nil }
            return try? await live.client.counterpart(for: track)
        }
        if let web = playback.engine as? QTWebPlaybackEngine {
            web.onModeSwitch = { report in
                QTVideoModeService.lastReports.append(report)
                if QTVideoModeService.lastReports.count > 32 { QTVideoModeService.lastReports.removeFirst() }
            }
        }
        observe()
    }

    /// Song⇄Video switches measured this session (DEBUG status file, acceptance).
    public private(set) static var lastReports: [QTModeSwitchReport] = []

    /// The web engine's video output (nil for the simulated engine).
    public var videoOutput: QTWebVideoOutput? { (model?.player.engine as? QTWebPlaybackEngine)?.video }

    // MARK: Picture in Picture

    /// Whether ⇧⌘P can do something now.
    public var canTogglePictureInPicture: Bool {
        guard let model, videoOutput != nil, let track = model.player.nowPlaying else { return false }
        return track.hasVideo || videoOutput?.isPictureInPictureActive == true
    }

    public var isPictureInPictureActive: Bool { videoOutput?.isPictureInPictureActive ?? false }

    /// ⇧⌘P: float the music video (switching to it first), or bring it back.
    public func togglePictureInPicture() {
        guard let model, let output = videoOutput else { return }
        pipTask?.cancel()
        if output.isPictureInPictureActive {
            pipTask = Task { await output.setPictureInPicture(false) }
            return
        }
        guard model.player.nowPlaying?.hasVideo == true else { return }
        if !model.isVideoMode { model.isVideoMode = true }
        pipTask = Task { @MainActor in
            // Wait for the video's first frame (a fresh switch loads the counterpart first).
            for _ in 0..<80 where !output.hasFrame {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard output.hasFrame else { return }
            await output.setPictureInPicture(true)
        }
    }

    // MARK: Keeping the rendition in step

    /// Belt and braces for the slots: once the song is what plays, the page goes back to the hidden host (144p)
    /// after the crossfade, even if a slot's view lingers in SwiftUI's hierarchy.
    private func releaseVideoIfUnused() {
        guard let model, let output = videoOutput, output.isPresenting, !model.isVideoMode else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int((QTVideoSlotHost.crossfade + 0.15) * 1000)))
            guard !model.isVideoMode, model.player.mode == .song, let container = output.container else { return }
            output.withdraw(from: container)
        }
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.isVideoMode
            _ = model.player.mode
            _ = model.player.nowPlaying?.hasVideo
            _ = model.player.nowPlaying?.videoId
            _ = model.settings.settings.preferVideos
        } onChange: {
            Task { @MainActor in
                QTVideoModeService.shared.sync()
                QTVideoModeService.shared.observe()
            }
        }
    }

    private func sync() {
        guard let model else { return }
        let prefer = model.settings.settings.preferVideos
        if prefer != lastPreferVideos {
            lastPreferVideos = prefer
            model.isVideoMode = prefer
        }
        let player = model.player
        player.playback.preferredMode = model.isVideoMode ? .video : .song
        releaseVideoIfUnused()
        let wanted: QTPlaybackMode = model.isVideoMode && player.nowPlaying?.hasVideo == true ? .video : .song
        guard wanted != player.mode, player.nowPlaying != nil else { return }
        Task { await player.setMode(wanted) }
    }
}
