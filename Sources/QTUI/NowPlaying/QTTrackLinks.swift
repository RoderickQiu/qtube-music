import QTCore
import SwiftUI

// The now-playing title and "Artist — Album" line as links (player bar, lyrics panel, Stage): the title and the album
// name open the album page, each artist's name opens that artist's page — the same places as the song menu's
// Go to Album / Go to Artist.

/// One clickable name of a now-playing line, with the text that leads up to it (", " between artists, " — " before
/// the album).
struct QTTrackLinkSegment: Hashable {
    var lead: String
    var text: String
    var destination: QTDestination
}

extension QTTrack {
    /// Where the title goes: the song's album page (nil when the song has no album).
    var qtTitleDestination: QTDestination? { album.map { QTDestination.album($0) } }

    /// The artists, then the album when `albumSeparator` is given and the album adds something
    /// (see `qtNowPlayingSubtitle`). Joined, the segments read exactly as the plain subtitle does.
    func qtLinkSegments(albumSeparator: String?) -> [QTTrackLinkSegment] {
        var segments: [QTTrackLinkSegment] = []
        // The locale's list format decides what stands between the names; take it from the formatted line.
        let line = artistLine
        var cursor = line.startIndex
        for (i, artist) in artists.enumerated() where !artist.name.isEmpty {
            if let range = line.range(of: artist.name, range: cursor..<line.endIndex) {
                segments.append(.init(lead: String(line[cursor..<range.lowerBound]), text: artist.name, destination: .artist(artist)))
                cursor = range.upperBound
            } else {
                segments.append(.init(lead: i == 0 ? "" : ", ", text: artist.name, destination: .artist(artist)))
            }
        }
        if let albumSeparator, let album, !QTTrackSubtitle.albumRepeatsTitle(album.title, title: title) {
            segments.append(.init(lead: segments.isEmpty ? "" : albumSeparator, text: album.title, destination: .album(album)))
        }
        return segments
    }
}

@MainActor
enum QTTrackLinks {
    /// Opens the page in the main window's content column, leaving the mini player / in-window Stage first.
    static func open(_ destination: QTDestination, model: QTAppModel) {
        let desktop = QTDesktopCoordinator.shared
        if model.surface == .mini || desktop.mainWindow?.isVisible != true { desktop.showMainWindow() }
        if model.surface == .stage { withAnimation(QTTheme.Motion.ui) { model.surface = .window } }
        QTNavigator.shared.go(destination)
    }

    static func help(for destination: QTDestination, name: String) -> String {
        switch destination {
        case .album: QTLoc.tr("Go to Album · %@", name)
        case .artist: QTLoc.tr("Go to Artist · %@", name)
        default: name
        }
    }
}

/// A name that opens its page: underlined under the pointer, otherwise it looks like the plain text it replaces.
private struct QTTrackLinkText: View {
    var lead = ""
    let text: String
    let destination: QTDestination
    let open: (QTDestination) -> Void
    @State private var isHovered = false

    var body: some View {
        let help = QTTrackLinks.help(for: destination, name: text)
        Button {
            open(destination)
        } label: {
            (Text(verbatim: lead) + Text(verbatim: text).underline(isHovered))
                .contentShape(Rectangle())
        }
        .buttonStyle(QTTrackLinkButtonStyle())
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Keeps the surrounding text's colour (a plain button would reset it to primary) and dims while pressed.
private struct QTTrackLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The song title; a link to its album when it has one. Font, colour and line limit come from the caller.
struct QTTrackTitleLink: View {
    let track: QTTrack?
    var open: ((QTDestination) -> Void)?
    @Environment(QTAppModel.self) private var model

    var body: some View {
        if let track, let destination = track.qtTitleDestination {
            QTTrackLinkText(text: track.title, destination: destination, open: open ?? { QTTrackLinks.open($0, model: model) })
        } else {
            Text(verbatim: track?.title ?? "")
        }
    }
}

/// One line of artist links, then the album link when `albumSeparator` is given. Truncates like the text it replaces.
struct QTTrackLinkLine: View {
    let track: QTTrack?
    var albumSeparator: String?
    var open: ((QTDestination) -> Void)?
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let segments = track?.qtLinkSegments(albumSeparator: albumSeparator) ?? []
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                QTTrackLinkText(lead: segment.lead, text: segment.text, destination: segment.destination,
                                open: open ?? { QTTrackLinks.open($0, model: model) })
            }
            // Keeps the line's height when there is nothing to show.
            if segments.isEmpty { Text(verbatim: "") }
        }
        .lineLimit(1)
    }
}
