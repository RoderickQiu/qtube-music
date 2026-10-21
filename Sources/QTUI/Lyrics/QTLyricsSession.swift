import Foundation
import Observation
import QTCore

// Owner: builder "lyrics-ui". UI-side lyric state that isn't the document itself: the versions found for a track
// (the "Lyrics Source" menu: a pinned version, Automatic, or no lyrics for this song — persisted by the lyrics
// session), "Report Wrong Lyrics", and the ⌥↑/⌥↓ timing nudge with its toast.

/// A lyrics version for the current track, as listed in the "Lyrics Source" menu.
public struct QTLyricsVersion: Identifiable, Hashable, Sendable {
    /// The pin id that turns lyrics off for a track ("No Lyrics for This Song"; `QTLyricsCache.noLyricsPin`).
    public static let noLyricsID = "none"

    public var id: String
    public var source: QTLyricsSource
    public var syncKind: QTLyricsSyncKind
    /// Language of the candidate's own translation lane, if it has one.
    public var translationLanguage: String?
    /// Match score 0…1.
    public var confidence: Double
    /// Seconds the version is timed longer (+) or shorter (−) than the track; nil when the source doesn't say.
    public var durationDelta: TimeInterval?
    /// A low score or a failed sanity check (other script, gibberish, ends early): "Possible mismatch".
    public var isPossibleMismatch: Bool

    public init(id: String, source: QTLyricsSource, syncKind: QTLyricsSyncKind, translationLanguage: String? = nil,
                confidence: Double = 1, durationDelta: TimeInterval? = nil, isPossibleMismatch: Bool? = nil) {
        self.id = id
        self.source = source
        self.syncKind = syncKind
        self.translationLanguage = translationLanguage
        self.confidence = confidence
        self.durationDelta = durationDelta
        self.isPossibleMismatch = isPossibleMismatch ?? (confidence < 0.8)
    }

    /// Menu row title: "LRCLIB · Line timing", plus the version's own translation language when it has one.
    public var menuTitle: String {
        var parts = [QTLoc.tr(source.name), QTLoc.tr(syncKind == .word ? "Word timing" : "Line timing")]
        if let tl = translationLanguage { parts.append(QTLyricsTranslationTarget.nativeName(for: tl)) }
        return parts.joined(separator: " · ")
    }

    /// Menu row subtitle in plain words, no scores: "Best match" or "Possible mismatch", then how much longer or
    /// shorter the version is timed when that is noticeable ("Possible mismatch · 12 s longer"). nil = nothing to say.
    public func menuDetail(isBest: Bool) -> String? {
        var parts: [String] = []
        if isPossibleMismatch {
            parts.append(QTLoc.tr("Possible mismatch", table: .lyrics))
        } else if isBest {
            parts.append(QTLoc.tr("Best match", table: .lyrics))
        }
        if let delta = durationDelta {
            // Within ±2 s the timing still lines up (the matcher scores it as the same length).
            let seconds = Int(delta.rounded())
            if seconds >= 2 { parts.append(QTLoc.tr("%lld s longer", table: .lyrics, seconds)) }
            if seconds <= -2 { parts.append(QTLoc.tr("%lld s shorter", table: .lyrics, -seconds)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// What the "Lyrics Source" menu has checked for a track.
public enum QTLyricsSourceChoice: Hashable, Sendable {
    case automatic
    case version(String)
    /// "No Lyrics for This Song".
    case off
}

/// Versions per track and the user's choice. The lyrics session publishes the versions and its persisted choice
/// (`publish(_:for:selected:)`, `setChoice(_:for:)`) and listens to the callbacks to act on a new one.
@MainActor
@Observable
public final class QTLyricsVersionStore {
    public static let shared = QTLyricsVersionStore()

    /// videoId → versions found, best first.
    public private(set) var versions: [String: [QTLyricsVersion]] = [:]
    /// videoId → version id currently shown.
    public private(set) var selected: [String: String] = [:]
    /// videoId → the pinned version id, or `QTLyricsVersion.noLyricsID` (persisted by the lyrics module).
    public private(set) var pinned: [String: String] = [:]
    /// The user picked another version; the lyrics module swaps the document.
    @ObservationIgnored public var onPin: (@MainActor (_ videoId: String, _ version: QTLyricsVersion) -> Void)?
    /// "Automatic": the lyrics module drops the pin and shows its own pick.
    @ObservationIgnored public var onUnpin: (@MainActor (_ videoId: String) -> Void)?
    /// "No Lyrics for This Song".
    @ObservationIgnored public var onLyricsOff: (@MainActor (_ videoId: String) -> Void)?
    /// "Report Wrong Lyrics": the lyrics module never shows that version for the track again and shows the next best.
    @ObservationIgnored public var onReport: (@MainActor (_ videoId: String, _ versionID: String) -> Void)?

    public init() {}

    public func publish(_ candidates: [QTLyricsVersion], for videoId: String, selected id: String?) {
        versions[videoId] = candidates
        if let id { selected[videoId] = id }
    }

    /// The lyrics session's persisted choice.
    public func setChoice(_ choice: QTLyricsSourceChoice, for videoId: String) {
        switch choice {
        case .automatic: pinned[videoId] = nil
        case .version(let id): pinned[videoId] = id
        case .off: pinned[videoId] = QTLyricsVersion.noLyricsID
        }
    }

    public func choice(for videoId: String) -> QTLyricsSourceChoice {
        switch pinned[videoId] {
        case nil: .automatic
        case QTLyricsVersion.noLyricsID?: .off
        case let id?: .version(id)
        }
    }

    public func pin(_ version: QTLyricsVersion, for videoId: String) {
        pinned[videoId] = version.id
        selected[videoId] = version.id
        onPin?(videoId, version)
    }

    /// "Automatic": forget the pinned choice (the lyrics session re-resolves and publishes the automatic pick).
    public func unpin(_ videoId: String) {
        pinned[videoId] = nil
        onUnpin?(videoId)
    }

    /// "No Lyrics for This Song": hides lyrics for this track until a version or Automatic is picked.
    public func turnOffLyrics(_ videoId: String) {
        pinned[videoId] = QTLyricsVersion.noLyricsID
        onLyricsOff?(videoId)
    }

    /// "Report Wrong Lyrics": the version showing leaves the list at once; the lyrics session keeps the report on
    /// this Mac (never sent anywhere), so that version is never chosen or offered for this track again.
    public func reportWrong(_ videoId: String) {
        guard let id = selected[videoId] else { return }
        versions[videoId]?.removeAll { $0.id == id }
        selected[videoId] = nil
        if pinned[videoId] == id { pinned[videoId] = nil }
        onReport?(videoId, id)
    }

    /// Versions other than the one showing.
    public func others(for videoId: String) -> [QTLyricsVersion] {
        let all = versions[videoId] ?? []
        return all.filter { $0.id != selected[videoId] }
    }

    /// Launch option `qt.lyrics.demoVersions`: plausible versions for screenshots (the mock engine has no provider
    /// chain to find them).
    func installDemoVersions(for track: QTTrack, document: QTLyricsDocument) {
        guard versions[track.videoId] == nil else { return }
        let current = QTLyricsVersion(id: document.source.id, source: document.source, syncKind: document.syncKind,
                                      translationLanguage: document.translationLanguage, confidence: document.confidence)
        let extra: [QTLyricsVersion] = [
            .init(id: "kugou", source: .kugou, syncKind: .word, confidence: 0.91, durationDelta: 1),
            .init(id: "lrclib", source: .lrclib, syncKind: .line, confidence: 0.86, durationDelta: 3),
            .init(id: "youtubeMusic", source: .youtubeMusic, syncKind: .line, confidence: 0.7, durationDelta: -14),
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
