import AppIntents
import Foundation
import QTUI

// Owner: builder "desktop". Shortcuts / App Intents (spec §8): play/pause, next, previous, like (this app only —
// nothing is written to YouTube Music), play a playlist, current track. They run inside the app without bringing
// it forward. Titles come from `Resources/AppIntents.xcstrings` and phrases from `Resources/AppShortcuts.xcstrings`
// (compiled into the bundle by Scripts/build-app.sh, which also extracts the App Intents metadata Shortcuts reads).

struct QTPlayPauseIntent: AppIntent {
    static let title = LocalizedStringResource("Play or Pause", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("Plays or pauses the current song.", table: "AppIntents"))
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        QTScripting.perform(.playPause)
        return .result()
    }
}

struct QTPlayIntent: AppIntent {
    static let title = LocalizedStringResource("Play", table: "AppIntents")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        QTScripting.perform(.play)
        return .result()
    }
}

struct QTPauseIntent: AppIntent {
    static let title = LocalizedStringResource("Pause", table: "AppIntents")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        QTScripting.perform(.pause)
        return .result()
    }
}

struct QTNextTrackIntent: AppIntent {
    static let title = LocalizedStringResource("Next Song", table: "AppIntents")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        QTScripting.perform(.next)
        return .result()
    }
}

struct QTPreviousTrackIntent: AppIntent {
    static let title = LocalizedStringResource("Previous Song", table: "AppIntents")
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult {
        QTScripting.perform(.previous)
        return .result()
    }
}

struct QTLikeCurrentTrackIntent: AppIntent {
    static let title = LocalizedStringResource("Like Current Song", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("Adds the current song to Liked Songs in QTube Music.", table: "AppIntents"))
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let title = QTScripting.likeCurrentTrack() else {
            return .result(dialog: IntentDialog(LocalizedStringResource("Nothing is playing.", table: "AppIntents")))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("Liked “\(title)”.", table: "AppIntents")))
    }
}

struct QTCurrentTrackIntent: AppIntent {
    static let title = LocalizedStringResource("Get Current Song", table: "AppIntents")
    static let description = IntentDescription(LocalizedStringResource("Returns the title and artist of what is playing.", table: "AppIntents"))
    static let openAppWhenRun = false

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let summary = QTScripting.currentTrackSummary else {
            return .result(value: "", dialog: IntentDialog(LocalizedStringResource("Nothing is playing.", table: "AppIntents")))
        }
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: Playlists

struct QTPlaylistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Playlist", table: "AppIntents"))
    static let defaultQuery = QTPlaylistQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct QTPlaylistQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [QTPlaylistEntity] {
        let all = QTScripting.playlists
        return identifiers.compactMap { id in all.first { $0.id == id }.map { QTPlaylistEntity(id: $0.id, title: $0.title) } }
    }

    @MainActor func suggestedEntities() async throws -> [QTPlaylistEntity] {
        QTScripting.playlists.map { QTPlaylistEntity(id: $0.id, title: $0.title) }
    }
}

struct QTPlayPlaylistIntent: AppIntent {
    static let title = LocalizedStringResource("Play Playlist", table: "AppIntents")
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource("Playlist", table: "AppIntents"))
    var playlist: QTPlaylistEntity

    @Parameter(title: LocalizedStringResource("Shuffle", table: "AppIntents"), default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)", table: "AppIntents") {
            \.$shuffle
        }
    }

    @MainActor func perform() async throws -> some IntentResult {
        _ = QTScripting.playPlaylist(id: playlist.id, shuffled: shuffle)
        return .result()
    }
}

// MARK: Shortcuts app / Spotlight

struct QTAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: QTPlayPauseIntent(), phrases: ["Play or pause \(.applicationName)", "Pause \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Play or Pause", table: "AppIntents"), systemImageName: "playpause.fill")
        AppShortcut(intent: QTNextTrackIntent(), phrases: ["Next song in \(.applicationName)", "Skip this song in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Next Song", table: "AppIntents"), systemImageName: "forward.fill")
        AppShortcut(intent: QTPreviousTrackIntent(), phrases: ["Previous song in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Previous Song", table: "AppIntents"), systemImageName: "backward.fill")
        AppShortcut(intent: QTCurrentTrackIntent(), phrases: ["What’s playing in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Get Current Song", table: "AppIntents"), systemImageName: "music.note")
        AppShortcut(intent: QTLikeCurrentTrackIntent(), phrases: ["Like this song in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Like Current Song", table: "AppIntents"), systemImageName: "heart")
        AppShortcut(intent: QTPlayPlaylistIntent(), phrases: ["Play \(\.$playlist) in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("Play Playlist", table: "AppIntents"), systemImageName: "music.note.list")
    }
}
