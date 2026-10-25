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
    /// A low score or a failed sanity check (other script, ends early, the same text as other songs): "Possible
    /// mismatch".
    public var isPossibleMismatch: Bool
    /// The user reported it: listed last, "Reported"; picking it takes the report back.
    public var isReported: Bool
    /// The song the source filed it under, only the parts that differ from the playing song ("“Title (Remix)”",
    /// "Other Artist"); nil when it names the same song.
    public var matchedName: String?
    /// Seconds the version is timed for, when the source says.
    public var length: TimeInterval?
    /// The album the source filed it under, if any.
    public var album: String?
    /// Fingerprint of the fetched words (nil when unfetched): versions of one source with the same words are one row.
    public var textFingerprint: String?

    public init(id: String, source: QTLyricsSource, syncKind: QTLyricsSyncKind, translationLanguage: String? = nil,
                confidence: Double = 1, durationDelta: TimeInterval? = nil, isPossibleMismatch: Bool? = nil,
                isReported: Bool = false, matchedName: String? = nil, length: TimeInterval? = nil, album: String? = nil,
                textFingerprint: String? = nil) {
        self.id = id
        self.source = source
        self.syncKind = syncKind
        self.translationLanguage = translationLanguage
        self.confidence = confidence
        self.durationDelta = durationDelta
        self.isPossibleMismatch = isPossibleMismatch ?? (confidence < 0.8)
        self.isReported = isReported
        self.matchedName = matchedName
        self.length = length
        self.album = album
        self.textFingerprint = textFingerprint
    }

    /// Menu row title: "LRCLIB · Line timing", plus the version's own translation language when it has one.
    public var menuTitle: String {
        let timing = switch syncKind {
        case .word: QTLoc.tr("Word timing")
        case .line: QTLoc.tr("Line timing")
        case .plain: QTLoc.tr("Unsynced", table: .lyrics)
        }
        var parts = [QTLoc.tr(source.name), timing]
        if let tl = translationLanguage { parts.append(QTLyricsTranslationTarget.nativeName(for: tl)) }
        return parts.joined(separator: " · ")
    }

    /// Menu row subtitle in plain words, no scores: "Reported", "Best match" or "Possible mismatch", then how much
    /// longer or shorter the version is timed when that is noticeable ("Possible mismatch · 12 s longer"). nil =
    /// nothing to say.
    public func menuDetail(isBest: Bool) -> String? {
        let parts = detailParts(isBest: isBest, distinguishing: false)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The subtitle's parts. `distinguishing`: the row shares its title with others, so it also says which song the
    /// source filed it under (when that isn't the playing one) and always says something about its length.
    func detailParts(isBest: Bool, distinguishing: Bool) -> [String] {
        // An imported file: its name.
        if source == .imported { return matchedName.map { [$0] } ?? [] }
        var parts: [String] = []
        if isReported {
            parts.append(QTLoc.tr("Reported"))
        } else if isPossibleMismatch {
            parts.append(QTLoc.tr("Possible mismatch", table: .lyrics))
        } else if isBest {
            parts.append(QTLoc.tr("Best match", table: .lyrics))
        }
        if distinguishing, let matchedName { parts.append(matchedName) }
        if let delta = durationDelta {
            // Within ±2 s the timing still lines up (the matcher scores it as the same length).
            let seconds = Int(delta.rounded())
            if seconds >= 2 { parts.append(QTLoc.tr("%lld s longer", table: .lyrics, seconds)) }
            else if seconds <= -2 { parts.append(QTLoc.tr("%lld s shorter", table: .lyrics, -seconds)) }
            else if distinguishing { parts.append(QTLoc.tr("Same length", table: .lyrics)) }
        } else if distinguishing, let length, length > 0 {
            parts.append(QTFormat.duration(length))
        }
        return parts
    }

    /// Two versions of one source with the same words, timing kind and translation: one row is enough.
    func isSameText(as other: QTLyricsVersion) -> Bool {
        guard let textFingerprint else { return false }
        return textFingerprint == other.textFingerprint && source == other.source && syncKind == other.syncKind
            && translationLanguage == other.translationLanguage && isReported == other.isReported
    }

    /// The "Lyrics Source" menu's rows for `versions` (best first). Versions of one source with the same words are
    /// one row — the one in `keeping` (showing or pinned) if any, else the best — so a source that files a song
    /// several times doesn't list it several times. A row whose title others share says what sets it apart: the
    /// song it was filed under when that isn't the playing one, its length, then its album; rows still alike are
    /// numbered ("Version 2") rather than left identical. Never a raw score.
    public static func menuRows(_ versions: [QTLyricsVersion], keeping keep: Set<String> = []) -> [QTLyricsSourceMenuRow] {
        var kept: [QTLyricsVersion] = []
        for v in versions {
            if let i = kept.firstIndex(where: { $0.isSameText(as: v) }) {
                if keep.contains(v.id) && !keep.contains(kept[i].id) { kept[i] = v }
            } else {
                kept.append(v)
            }
        }
        var rows = kept.enumerated().map { index, v in
            QTLyricsSourceMenuRow(version: v, title: v.menuTitle, detail: v.menuDetail(isBest: index == 0))
        }
        let titleCounts = Dictionary(rows.map { ($0.title, 1) }, uniquingKeysWith: +)
        for title in titleCounts.keys where titleCounts[title, default: 0] > 1 {
            let group = rows.indices.filter { rows[$0].title == title }
            var parts = Dictionary(uniqueKeysWithValues: group.map {
                ($0, rows[$0].version.detailParts(isBest: $0 == 0, distinguishing: true))
            })
            // Still alike: the album, where the alike rows' albums differ…
            for clash in clashes(in: group, parts) {
                guard Set(clash.map { rows[$0].version.album }).count > 1 else { continue }
                for i in clash { if let album = rows[i].version.album { parts[i, default: []].append(QTLoc.tr("From “%@”", table: .lyrics, album)) } }
            }
            // …then a number, so no two rows ever read the same.
            for clash in clashes(in: group, parts) {
                for (n, i) in clash.enumerated() { parts[i, default: []].append(QTLoc.tr("Version %lld", table: .lyrics, n + 1)) }
            }
            for i in group { rows[i].detail = parts[i].flatMap { $0.isEmpty ? nil : $0.joined(separator: " · ") } }
        }
        return rows
    }

    /// Clusters (of two or more, in menu order) of rows whose subtitles read the same.
    private static func clashes(in group: [Int], _ parts: [Int: [String]]) -> [[Int]] {
        var clusters: [[String]: [Int]] = [:]
        for i in group { clusters[parts[i] ?? [], default: []].append(i) }
        return clusters.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
    }
}

/// A row of the "Lyrics Source" menu: the version, its title and its subtitle (`QTLyricsVersion.menuRows`).
public struct QTLyricsSourceMenuRow: Identifiable, Hashable, Sendable {
    public var version: QTLyricsVersion
    public var title: String
    public var detail: String?
    public var id: String { version.id }
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
    /// "Report Wrong Lyrics": the lyrics module never chooses that version for the track again and shows the next
    /// best. Returns false when it can't act on it (nothing is reported then).
    @ObservationIgnored public var onReport: (@MainActor (_ videoId: String, _ versionID: String) -> Bool)?
    /// Undo on the "Reported" toast.
    @ObservationIgnored public var onUndoReport: (@MainActor (_ videoId: String, _ versionID: String) -> Void)?

    public init() {}

    /// - Parameter id: the version showing, nil when none is (no lyrics, or lyrics that aren't one of the versions).
    public func publish(_ candidates: [QTLyricsVersion], for videoId: String, selected id: String?) {
        versions[videoId] = candidates
        selected[videoId] = id
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

    /// A version is showing, so there is something to report.
    public func canReport(_ videoId: String) -> Bool {
        guard let id = selected[videoId] else { return false }
        // The user's own file isn't a source's mistake.
        return versions[videoId]?.first { $0.id == id }?.source != .imported
    }

    /// "Report Wrong Lyrics": the version showing moves to the end of the list as reported at once; the lyrics
    /// session keeps the report on this Mac (never sent anywhere), so that version is never chosen for this track
    /// again unless it is picked. Returns the reported version's id, nil when nothing was reported.
    @discardableResult
    public func reportWrong(_ videoId: String) -> String? {
        guard let id = selected[videoId] else { return nil }
        if let onReport, !onReport(videoId, id) { return nil }
        if var list = versions[videoId], let i = list.firstIndex(where: { $0.id == id }) {
            var v = list.remove(at: i)
            v.isReported = true
            list.append(v)
            versions[videoId] = list
        }
        selected[videoId] = nil
        if pinned[videoId] == id { pinned[videoId] = nil }
        return id
    }

    /// Undo for `reportWrong`: the lyrics session takes the report back and shows that version again.
    public func undoReport(_ versionID: String, for videoId: String) {
        if let i = versions[videoId]?.firstIndex(where: { $0.id == versionID }) { versions[videoId]?[i].isReported = false }
        onUndoReport?(videoId, versionID)
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
