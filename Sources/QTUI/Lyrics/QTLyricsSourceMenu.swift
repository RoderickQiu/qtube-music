import QTCore
import SwiftUI

// Owner: builder "lyrics-ui". The "Lyrics Source" menu, shared by Controls › Lyrics Source and the lyrics options
// popover, so both always offer the same choices.

/// Automatic (checked unless the user chose otherwise; the default goes first, as in any Mac picker), the versions
/// found for this song best first — "LRCLIB · Line timing" over a plain-words subtitle ("Best match", "Possible
/// mismatch · 12 s longer") — then "No Lyrics for This Song", and optionally "Report Wrong Lyrics".
struct QTLyricsSourceMenu: View {
    let model: QTAppModel
    /// The popover has its own one-click Report button beside the menu.
    var includesReport = true
    private var store: QTLyricsVersionStore { .shared }

    var body: some View {
        let id = model.player.nowPlaying?.videoId ?? ""
        let versions = store.versions[id] ?? []
        let choice = store.choice(for: id)
        // Always unpins, even when it already looks checked (a stale pin is cleared this way too).
        Toggle(isOn: Binding(get: { choice == .automatic }, set: { _ in store.unpin(id) })) {
            Text(QTLoc.tr("Automatic", table: .lyrics))
        }
        .accessibilityIdentifier("qt.lyrics.sourceAutomatic")
        if !versions.isEmpty {
            Divider()
            ForEach(Array(versions.enumerated()), id: \.element.id) { index, v in
                Toggle(isOn: Binding(get: { choice == .version(v.id) }, set: { _ in store.pin(v, for: id) })) {
                    // Two texts: the menu item's title and its subtitle (macOS 14+ menus).
                    Text(verbatim: v.menuTitle)
                    if let detail = v.menuDetail(isBest: index == 0) { Text(verbatim: detail) }
                }
            }
        }
        Divider()
        Toggle(isOn: Binding(get: { choice == .off }, set: { on in if on { store.turnOffLyrics(id) } })) {
            Text(QTLoc.tr("No Lyrics for This Song", table: .lyrics))
        }
        .disabled(id.isEmpty)
        .accessibilityIdentifier("qt.lyrics.sourceNone")
        if includesReport {
            Divider()
            Button(QTLoc.tr("Report Wrong Lyrics", table: .lyrics)) { Self.report(model) }
                .disabled(!Self.canReport(model))
        }
    }

    /// The menu's title for the current choice: "Automatic", the pinned source, or "Off". A pinned version that
    /// wasn't found this time still names its source (picking Automatic clears it).
    static func choiceTitle(for videoId: String) -> String {
        let store = QTLyricsVersionStore.shared
        switch store.choice(for: videoId) {
        case .automatic: return QTLoc.tr("Automatic", table: .lyrics)
        case .off: return QTLoc.tr("Off")
        case .version(let id):
            if let v = store.versions[videoId]?.first(where: { $0.id == id }) { return QTLoc.tr(v.source.name) }
            let sourceID = id.split(separator: ":", maxSplits: 1).first.map(String.init)
            return knownSources.first { $0.id == sourceID }.map { QTLoc.tr($0.name) } ?? QTLoc.tr("Automatic", table: .lyrics)
        }
    }

    private static let knownSources: [QTLyricsSource] = [.youtubeMusic, .amll, .lrclib, .netease, .kugou, .qq]

    /// Lyrics are showing and they are one of the versions found (not the bundled demo lyrics).
    static func canReport(_ model: QTAppModel) -> Bool {
        guard let id = model.player.nowPlaying?.videoId, model.player.lyrics != nil else { return false }
        return QTLyricsVersionStore.shared.canReport(id)
    }

    /// One click: these lyrics are never chosen for this song again and the next best version replaces them. The
    /// toast's Undo takes the report back.
    static func report(_ model: QTAppModel) {
        guard canReport(model), let id = model.player.nowPlaying?.videoId else { return }
        let store = QTLyricsVersionStore.shared
        guard let versionID = store.reportWrong(id) else { return }
        model.showToast(QTLoc.tr("Reported")) { store.undoReport(versionID, for: id) }
    }
}
