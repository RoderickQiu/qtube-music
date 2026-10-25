import AppKit
import QTCore
import QTLyrics
import SwiftUI
import UniformTypeIdentifiers

// Owner: builder "lyrics-ui". Lyrics from a file for the playing song: "Import Lyrics…" (Lyrics Source menu, the
// "No lyrics" state) and a file dropped on the lyrics. The lyrics session keeps the file and pins it.

@MainActor
enum QTLyricsImport {
    /// LRC, TTML and plain text.
    static let contentTypes: [UTType] = [UTType(filenameExtension: "lrc"), UTType(filenameExtension: "ttml"), .xml, .plainText]
        .compactMap { $0 }

    static func canImport(_ model: QTAppModel) -> Bool {
        model.player.nowPlaying != nil && model.lyricsSession?.engine == .live
    }

    /// "Import Lyrics…": an Open panel, then the file is imported for the song that was playing when it opened.
    static func choose(_ model: QTAppModel) {
        guard canImport(model), let track = model.player.nowPlaying else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = QTLoc.tr("Choose an LRC, TTML or text file with the lyrics of “%@”.", table: .lyrics, track.title)
        panel.prompt = QTLoc.tr("Import", table: .lyrics)
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { _ = importFile(url, for: track.videoId, model: model) }
        }
    }

    /// Imports `url` for `videoId` if that song is still the one playing. Says how it went in a toast.
    @discardableResult
    static func importFile(_ url: URL, for videoId: String? = nil, model: QTAppModel) -> Bool {
        guard let session = model.lyricsSession, let track = model.player.nowPlaying,
              videoId == nil || videoId == track.videoId else { return false }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url), let file = QTImportedLyrics(fileName: name, data: data),
              session.importLyrics(file) else {
            model.showToast(QTLoc.tr("“%@” has no lyrics QTube Music can read", table: .lyrics, name))
            return false
        }
        model.showToast(QTLoc.tr("Lyrics imported for “%@”", table: .lyrics, track.title))
        return true
    }
}

extension View {
    /// A lyrics file dropped here is imported for the playing song.
    func qtLyricsFileDrop(_ model: QTAppModel) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            guard QTLyricsImport.canImport(model), let url = urls.first(where: \.isFileURL) else { return false }
            return QTLyricsImport.importFile(url, model: model)
        }
    }
}
