import QTCore
import SwiftUI

// Settings › Playback › Blocked artists: the "Don't Play This Artist" list (QTArtistBlocking), kept on this Mac. One
// row with the names and Edit…; the sheet is a native bordered list — select, then − or ⌫ to remove.

struct QTBlockedArtistsSection: View {
    @Environment(QTAppModel.self) private var model
    @State private var isEditing = false

    var body: some View {
        let entries = model.settings.settings.blockedArtists
        Section {
            LabeledContent {
                HStack(spacing: QTTheme.Spacing.s) {
                    Text(verbatim: entries.isEmpty ? QTLoc.tr("None", table: .desktop) : Self.names(entries))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button(QTLoc.tr("Edit…", table: .desktop)) { isEditing = true }
                        .accessibilityIdentifier("qt.settings.blockedArtists.edit")
                }
            } label: {
                Text(QTLoc.tr("Blocked artists", table: .desktop))
            }
            .help(QTLoc.tr("Autoplay, radio and shuffle skip these artists, and Home, Explore and search leave them out. Songs you pick still play.", table: .desktop))
            .accessibilityIdentifier("qt.settings.blockedArtists")
        }
        .sheet(isPresented: $isEditing) {
            QTBlockedArtistsEditor()
                .environment(model)
        }
        .onAppear {
            #if DEBUG
            if model.launch.bool(QTArtistBlocking.editorLaunchKey) == true { isEditing = true }
            #endif
        }
    }

    /// Most recent first, as the list sorts them.
    static func names(_ entries: [QTBlockedArtist]) -> String {
        sorted(entries).map(\.name).formatted(.list(type: .and, width: .narrow).locale(QTLoc.locale))
    }

    static func sorted(_ entries: [QTBlockedArtist]) -> [QTBlockedArtist] {
        entries.sorted { $0.dateAdded > $1.dateAdded }
    }
}

/// The list itself: name, and when it was blocked.
struct QTBlockedArtistsEditor: View {
    @Environment(QTAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()

    var body: some View {
        let entries = QTBlockedArtistsSection.sorted(model.settings.settings.blockedArtists)
        VStack(alignment: .leading, spacing: 12) {
            Text(QTLoc.tr("Blocked Artists", table: .desktop))
                .font(.headline)
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        HStack {
                            Text(verbatim: entry.name)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.dateAdded.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(QTLoc.locale)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(entry.id)
                        .contextMenu {
                            Button(QTLoc.tr("Remove", table: .desktop)) { remove(selection.contains(entry.id) ? selection : [entry.id]) }
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .onDeleteCommand { remove(selection) }
                .overlay {
                    if entries.isEmpty {
                        Text(QTLoc.tr("No Blocked Artists", table: .desktop))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("qt.settings.blockedArtists.list")
                // The list's own − button, under it (System Settings' list idiom).
                HStack(spacing: 0) {
                    Button {
                        remove(selection)
                    } label: {
                        Label(QTLoc.tr("Remove", table: .desktop), systemImage: "minus")
                            .labelStyle(.iconOnly)
                            .frame(width: 22, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection.isEmpty)
                    .help(QTLoc.tr("Remove", table: .desktop))
                    .accessibilityIdentifier("qt.settings.blockedArtists.remove")
                    Spacer()
                }
                .padding(4)
                .background(.background.secondary)
            }
            .frame(height: 240)
            HStack {
                Spacer()
                Button(QTLoc.tr("Done", table: .desktop)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        QTArtistBlocking.remove(ids, model: model)
        selection.subtract(ids)
    }
}
