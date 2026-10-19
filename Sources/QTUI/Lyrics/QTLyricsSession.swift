import Foundation
import Observation
import QTCore

// Owner: builder "lyrics-ui". UI-side lyric state that isn't the document itself: other versions found for a track
// ("Wrong lyrics? / Other versions (n)", pinned per track), local wrong-lyrics reports, and the ⌥↑/⌥↓ timing nudge
// with its toast.

/// A lyrics candidate for the current track, as listed under "Other versions".
public struct QTLyricsVersion: Identifiable, Hashable, Sendable {
    public var id: String
    public var source: QTLyricsSource
    public var syncKind: QTLyricsSyncKind
    /// Language of the candidate's own translation lane, if it has one.
    public var translationLanguage: String?
    /// Match score 0…1.
    public var confidence: Double

    public init(id: String, source: QTLyricsSource, syncKind: QTLyricsSyncKind, translationLanguage: String? = nil,
                confidence: Double = 1) {
        self.id = id
        self.source = source
        self.syncKind = syncKind
        self.translationLanguage = translationLanguage
        self.confidence = confidence
    }
}

/// Candidates per track and the user's pinned choice. The lyrics module publishes candidates
/// (`publish(_:for:selected:)`) and listens to `onPin` to load the chosen version.
@MainActor
@Observable
public final class QTLyricsVersionStore {
    public static let shared = QTLyricsVersionStore()

    public private(set) var versions: [String: [QTLyricsVersion]] = [:]
    /// videoId → version id currently shown.
    public private(set) var selected: [String: String] = [:]
    /// videoId → version ids the user pinned explicitly (persisted by the lyrics module).
    public private(set) var pinned: [String: String] = [:]
    public private(set) var reported: Set<String> = []
    /// Called when the user picks another version; the lyrics module swaps the document.
    @ObservationIgnored public var onPin: (@MainActor (_ videoId: String, _ version: QTLyricsVersion) -> Void)?

    public init() {}

    public func publish(_ candidates: [QTLyricsVersion], for videoId: String, selected id: String?) {
        versions[videoId] = candidates
        if let id { selected[videoId] = id }
    }

    public func pin(_ version: QTLyricsVersion, for videoId: String) {
        pinned[videoId] = version.id
        selected[videoId] = version.id
        onPin?(videoId, version)
    }

    /// "Automatic": forget the pinned choice (the lyrics session re-resolves and publishes the automatic pick).
    public func unpin(_ videoId: String) {
        pinned[videoId] = nil
    }

    /// "Wrong lyrics": remembered locally (never sent anywhere) so the matcher can skip this candidate next time.
    public func reportWrong(_ videoId: String) {
        if let id = selected[videoId] { reported.insert("\(videoId)|\(id)") }
    }

    /// Versions other than the one showing.
    public func others(for videoId: String) -> [QTLyricsVersion] {
        let all = versions[videoId] ?? []
        return all.filter { $0.id != selected[videoId] }
    }

    /// Launch option `qt.lyrics.demoVersions`: plausible candidates for screenshots until the provider chain
    /// publishes real ones (M2).
    func installDemoVersions(for track: QTTrack, document: QTLyricsDocument) {
        guard versions[track.videoId] == nil else { return }
        let current = QTLyricsVersion(id: document.source.id, source: document.source, syncKind: document.syncKind,
                                      translationLanguage: document.translationLanguage, confidence: document.confidence)
        let extra: [QTLyricsVersion] = [
            .init(id: "kugou", source: .kugou, syncKind: .word, confidence: 0.91),
            .init(id: "lrclib", source: .lrclib, syncKind: .line, confidence: 0.86),
            .init(id: "youtubeMusic", source: .youtubeMusic, syncKind: .line, confidence: 0.8),
        ].filter { $0.id != current.id }
        publish([current] + extra, for: track.videoId, selected: current.id)
    }
}

/// ⌥↑ / ⌥↓ and the popover stepper: nudges the offset live and confirms with a toast ("Lyrics timing +0.1 s").
@MainActor
public enum QTLyricsTiming {
    public static let step: TimeInterval = 0.1

    public static func nudge(_ model: QTAppModel, by delta: TimeInterval) {
        guard let doc = model.player.lyrics, doc.syncKind != .plain else { return }
        model.player.nudgeLyricsOffset(by: delta)
        let offset = model.player.lyrics?.offset ?? 0
        model.showToast(QTLoc.tr("Lyrics timing %@ s", QTFormat.signedOffset(offset)))
    }
}
