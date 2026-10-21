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
        Toggle(isOn: Binding(get: { choice == .automatic }, set: { on in if on { store.unpin(id) } })) {
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
                .disabled(model.player.lyrics == nil)
        }
    }

    /// The menu's title for the current choice: "Automatic", the pinned source, or "Off".
    static func choiceTitle(for videoId: String) -> String {
        let store = QTLyricsVersionStore.shared
        switch store.choice(for: videoId) {
        case .automatic: return QTLoc.tr("Automatic", table: .lyrics)
        case .off: return QTLoc.tr("Off")
        case .version(let id): return store.versions[videoId]?.first { $0.id == id }.map { QTLoc.tr($0.source.name) }
            ?? QTLoc.tr("Automatic", table: .lyrics)
        }
    }

    /// One click: these lyrics are never shown for this song again and the next best version replaces them.
    static func report(_ model: QTAppModel) {
        guard let id = model.player.nowPlaying?.videoId, model.player.lyrics != nil else { return }
        QTLyricsVersionStore.shared.reportWrong(id)
        model.showToast(QTLoc.tr("Reported"))
    }
}
