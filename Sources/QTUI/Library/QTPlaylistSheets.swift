import QTCore
import SwiftUI

// Playlist management sheets over the main window: New Playlist (sidebar, File › New Playlist ⌘N, "New Playlist…"
// in Add to Playlist, Save Queue as Playlist), Edit Playlist (name, description, privacy) and the Delete question.
// They write through `QTAccountWriter` (the account when syncing, else this Mac) and say which.

/// What the playlist sheet is for.
public struct QTPlaylistSheetRequest: Identifiable {
    public enum Mode {
        /// A new playlist, optionally with songs (the queue, a selection).
        case new(tracks: [QTTrack], suggestedTitle: String)
        case edit(QTPlaylist)
    }

    public let id = UUID()
    public var mode: Mode

    public init(_ mode: Mode) { self.mode = mode }
}

/// Starting points for playlist management (menus, buttons, keys).
@MainActor
enum QTPlaylistActions {
    /// Opens New Playlist (guests are offered sign-in instead).
    static func newPlaylist(with tracks: [QTTrack] = [], suggestedTitle: String = "", model: QTAppModel = .shared) {
        guard QTAccountGate.allows(.addToPlaylist, model: model) else { return }
        model.playlistSheet = QTPlaylistSheetRequest(.new(tracks: tracks.filter(\.availability.isPlayable),
                                                          suggestedTitle: suggestedTitle))
    }

    static func edit(_ playlist: QTPlaylist, model: QTAppModel = .shared) {
        model.playlistSheet = QTPlaylistSheetRequest(.edit(playlist))
    }

    static func delete(_ playlist: QTPlaylist, model: QTAppModel = .shared) {
        model.playlistToDelete = playlist
    }

    /// Add to Library / Remove from Library for an album (its `OLAK…` id) or someone else's playlist.
    static func toggleSaved(id: String, title: String, model: QTAppModel = .shared, writer: QTAccountWriter = .shared) {
        guard QTAccountGate.allows(.addToPlaylist, model: model) else { return }
        let save = writer.isSaved(id) != true
        writer.setSaved(save, playlistID: id, title: title)
        if !writer.savesToAccount {
            model.showToast(QTLoc.tr(save ? "Added to your library on this Mac" : "Removed from your library on this Mac",
                                     table: .main))
        }
    }
}

extension View {
    /// Hosts the playlist sheet and the delete question (main window).
    func qtPlaylistSheets() -> some View { modifier(QTPlaylistSheetsModifier()) }
}

private struct QTPlaylistSheetsModifier: ViewModifier {
    @Environment(QTAppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        let doomed = model.playlistToDelete
        content
            .sheet(item: $model.playlistSheet) { request in
                QTPlaylistDetailsSheet(request: request)
                    .environment(model)
            }
            .alert(QTLoc.tr("Delete “%@”?", table: .main, doomed?.title.resolved ?? ""),
                   isPresented: Binding(get: { model.playlistToDelete != nil },
                                        set: { if !$0 { model.playlistToDelete = nil } }),
                   presenting: doomed) { playlist in
                Button(QTLoc.tr("Delete", table: .main), role: .destructive) {
                    QTAccountWriter.shared.delete(playlist)
                }
                Button(QTLoc.tr("Cancel", table: .desktop), role: .cancel) {}
            } message: { playlist in
                Text(Self.deleteMessage(playlist))
            }
            .task {
                #if DEBUG
                // `-qt.show newPlaylist` / `editPlaylist` (with `-qt.section playlist:<id>`): screenshots.
                let show = model.launch.string("qt.show") ?? ""
                if show.contains("newPlaylist") {
                    // The launch queue first (Save Queue as Playlist's case).
                    for _ in 0..<40 where model.player.nowPlaying == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    let queue = model.player.queue
                    let tracks = ([queue.nowPlaying].compactMap { $0 } + queue.upNext).map(\.track)
                    model.playlistSheet = QTPlaylistSheetRequest(.new(tracks: tracks, suggestedTitle: ""))
                } else if show.contains("editPlaylist"), case .playlist(let id)? = model.launch.section,
                          let p = QTLiveCatalogStore.shared.playlist(id) {
                    model.playlistSheet = QTPlaylistSheetRequest(.edit(p))
                } else if show.contains("deletePlaylist"), case .playlist(let id)? = model.launch.section,
                          let p = QTLiveCatalogStore.shared.playlist(id) {
                    model.playlistToDelete = p
                }
                #endif
            }
    }

    /// Says exactly what Delete does: the account's playlist is deleted for good; with Sync off it only leaves this
    /// Mac; one made here is simply gone.
    static func deleteMessage(_ playlist: QTPlaylist, writer: QTAccountWriter = .shared) -> String {
        if playlist.id.hasPrefix("local:") { return QTLoc.tr("You can’t undo this.", table: .main) }
        if writer.savesToAccount {
            return QTLoc.tr("It’s deleted from your YouTube Music account too. You can’t undo this.", table: .main)
        }
        return QTLoc.tr("It’s removed from this Mac only. Your YouTube Music account keeps it.", table: .main)
    }
}

/// New Playlist / Edit Playlist: name, description and (when it goes to the account) who can see it.
struct QTPlaylistDetailsSheet: View {
    let request: QTPlaylistSheetRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var privacy: QTPlaylistPrivacy = .private
    @FocusState private var isNameFocused: Bool

    private var writer: QTAccountWriter { .shared }

    private var isNew: Bool {
        if case .new = request.mode { return true }
        return false
    }

    private var tracks: [QTTrack] {
        if case .new(let tracks, _) = request.mode { return tracks }
        return []
    }

    /// Whether this playlist lives in the account (privacy matters there), or only on this Mac.
    private var goesToAccount: Bool {
        switch request.mode {
        case .new: writer.savesToAccount
        case .edit(let p): writer.savesToAccount && !p.id.hasPrefix("local:")
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(QTLoc.tr(isNew ? "New Playlist" : "Edit Playlist", table: .main))
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                TextField(QTLoc.tr("Name", table: .main), text: $title)
                    .focused($isNameFocused)
                    .accessibilityIdentifier("qt.playlist.sheet.name")
                TextField(QTLoc.tr("Description", table: .main), text: $description, axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("qt.playlist.sheet.description")
                if goesToAccount {
                    Picker(QTLoc.tr("Privacy", table: .main), selection: $privacy) {
                        ForEach(QTPlaylistPrivacy.allCases, id: \.self) { p in
                            Text(Self.label(p)).tag(p)
                        }
                    }
                    .accessibilityIdentifier("qt.playlist.sheet.privacy")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack(spacing: QTTheme.Spacing.s) {
                Text(footnote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: QTTheme.Spacing.s)
                Button(QTLoc.tr("Cancel", table: .desktop)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(QTLoc.tr(isNew ? "Create" : "Save", table: .main)) { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
                    .accessibilityIdentifier("qt.playlist.sheet.commit")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: fill)
        .accessibilityIdentifier("qt.playlist.sheet")
    }

    /// "12 songs", and where it's kept when that isn't the account.
    private var footnote: String {
        var parts: [String] = []
        if isNew, !tracks.isEmpty { parts.append(QTLoc.tr("%lld songs", table: .main, tracks.count)) }
        if !goesToAccount { parts.append(QTLoc.tr("Kept on this Mac", table: .main)) }
        return parts.joined(separator: " · ")
    }

    static func label(_ p: QTPlaylistPrivacy) -> String {
        switch p {
        case .private: QTLoc.tr("Private", table: .main)
        case .unlisted: QTLoc.tr("Unlisted", table: .main)
        case .public: QTLoc.tr("Public", table: .main)
        }
    }

    private func fill() {
        switch request.mode {
        case .new(_, let suggested):
            // Like Music: a name to type over (selected), never an empty, invisible field.
            title = suggested.isEmpty ? QTLoc.tr("Untitled Playlist", table: .main) : suggested
        case .edit(let p):
            title = p.title.resolved
            description = p.description ?? ""
            privacy = p.privacy ?? .private
        }
        isNameFocused = true
    }

    private func commit() {
        guard !trimmedTitle.isEmpty else { return }
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.mode {
        case .new(let tracks, _):
            writer.create(title: trimmedTitle, description: text, privacy: privacy, tracks: tracks)
        case .edit(let p):
            writer.editDetails(p, title: trimmedTitle, description: text, privacy: privacy)
        }
        dismiss()
    }
}
