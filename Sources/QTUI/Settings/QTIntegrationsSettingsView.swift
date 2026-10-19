import AppKit
import QTCore
import QTIntegrations
import SwiftUI

// Owner: builder "desktop". Settings › Integrations (spec §10): Last.fm scrobbling and Discord Rich Presence,
// both off until the user sets them up. The pane is switches + Connect…; the app has no Last.fm API account or
// Discord application of its own yet (shipping them is the user's call), so the user's own key / application ID go in
// a collapsed "Use your own …" disclosure that opens by itself when Connect… or the switch needs it. Then Last.fm's
// web authorization in the browser. When the app ships its own credentials, drop the disclosures.

struct QTIntegrationsSettingsPane: View {
    private var store: QTIntegrationsStore { QTIntegrationsCoordinator.shared.store }

    var body: some View {
        Form {
            QTLastFMSettingsSection(store: store)
            QTDiscordSettingsSection(store: store)
        }
        .formStyle(.grouped)
    }
}

@MainActor
private func binding<T>(_ store: QTIntegrationsStore, _ keyPath: WritableKeyPath<QTIntegrationsSettings, T>) -> Binding<T> {
    Binding(get: { store.settings[keyPath: keyPath] }, set: { v in store.update { $0[keyPath: keyPath] = v } })
}

// MARK: - Last.fm

/// Settings › Integrations opens with every "Use your own …" disclosure expanded (DEBUG screenshots).
@MainActor
private var qtIntegrationsLaunchExpanded: Bool {
    #if DEBUG
    QTAppModel.shared.launch.bool("qt.desktop.integrationsExpanded") ?? false
    #else
    false
    #endif
}

struct QTLastFMSettingsSection: View {
    let store: QTIntegrationsStore
    @State private var secretDraft = ""
    @State private var pendingToken: String?
    @State private var isWorking = false
    @State private var failure: String?
    /// "Use your own API key": the app has no Last.fm API account of its own yet, so the user's goes here — tucked
    /// away, collapsed, until Connect… needs it.
    @State private var showsOwnKey = qtIntegrationsLaunchExpanded
    @FocusState private var focusesKey: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let prefs = store.settings.lastFM
        Section {
            if let name = prefs.username {
                Toggle(QTLoc.tr("Scrobble to Last.fm", table: .desktop), isOn: binding(store, \.lastFM.isEnabled))
                    .accessibilityIdentifier("qt.settings.lastfm.enabled")
                Toggle(QTLoc.tr("Update “Now Playing”", table: .desktop), isOn: binding(store, \.lastFM.sendsNowPlaying))
                    .disabled(!prefs.isEnabled)
                LabeledContent(QTLoc.tr("Account", table: .desktop)) {
                    HStack(spacing: QTTheme.Spacing.s) {
                        Text(verbatim: name).foregroundStyle(.secondary)
                        Button(QTLoc.tr("Disconnect", table: .desktop)) { store.disconnectLastFM() }
                            .accessibilityIdentifier("qt.settings.lastfm.disconnect")
                    }
                }
            } else {
                LabeledContent {
                    HStack(spacing: QTTheme.Spacing.s) {
                        if isWorking { ProgressView().controlSize(.small) }
                        if pendingToken != nil {
                            Button(QTLoc.tr("Finish Connecting", table: .desktop), action: finishConnecting)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(QTLoc.tr("Connect…", table: .desktop), action: connect)
                                .disabled(isWorking)
                        }
                    }
                } label: {
                    Text(QTLoc.tr("Scrobble to Last.fm", table: .desktop))
                    if let failure { Text(verbatim: failure) }
                }
                .accessibilityIdentifier("qt.settings.lastfm.connect")
                DisclosureGroup(QTLoc.tr("Use your own API key", table: .desktop), isExpanded: $showsOwnKey) {
                    QTIntegrationFieldRow(QTLoc.tr("API Key", table: .desktop)) {
                        TextField(QTLoc.tr("API Key", table: .desktop), text: binding(store, \.lastFM.apiKey))
                            .textContentType(.none)
                            .autocorrectionDisabled()
                            .focused($focusesKey)
                            .accessibilityIdentifier("qt.settings.lastfm.apiKey")
                    }
                    QTIntegrationFieldRow(QTLoc.tr("Shared Secret", table: .desktop)) {
                        SecureField(QTLoc.tr("Shared Secret", table: .desktop), text: $secretDraft,
                                    prompt: prefs.hasSecret ? Text(QTLoc.tr("Saved", table: .desktop)) : nil)
                            .onSubmit(saveSecret)
                            .accessibilityIdentifier("qt.settings.lastfm.secret")
                    }
                    QTIntegrationLinkRow(QTLoc.tr("Get an API key", table: .desktop),
                                         destination: URL(string: "https://www.last.fm/api/account/create")!)
                }
                .accessibilityIdentifier("qt.settings.lastfm.ownKey")
            }
        } header: {
            Text(verbatim: "Last.fm")
        }
    }

    private var hasCredentials: Bool {
        !store.settings.lastFM.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && (store.settings.lastFM.hasSecret || !secretDraft.isEmpty)
    }

    private func saveSecret() {
        guard !secretDraft.isEmpty else { return }
        store.setLastFMSecret(secretDraft)
        secretDraft = ""
    }

    /// Step 1: a request token, then Last.fm's approval page in the browser (user-initiated).
    private func connect() {
        guard hasCredentials else {
            // No API account yet: open "Use your own API key" and put the cursor in it.
            withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) { showsOwnKey = true }
            focusesKey = true
            return
        }
        saveSecret()
        guard let creds = store.lastFMCredentials() else { return }
        isWorking = true
        failure = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let token = try await QTLastFMClient(credentials: creds).requestToken()
                pendingToken = token
                NSWorkspace.shared.open(QTLastFMRequest.authorizeURL(apiKey: creds.apiKey, token: token))
            } catch {
                failure = Self.message(for: error)
            }
        }
    }

    /// Step 2, after the user allowed access on last.fm.
    private func finishConnecting() {
        guard let token = pendingToken, let creds = store.lastFMCredentials() else { return }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let session = try await QTLastFMClient(credentials: creds).session(token: token)
                pendingToken = nil
                failure = nil
                store.connectLastFM(session: session)
            } catch let error as QTLastFMError {
                if case .api(15, _) = error { pendingToken = nil } // token expired: start over
                failure = Self.message(for: error)
            } catch {
                failure = Self.message(for: error)
            }
        }
    }

    static func message(for error: any Error) -> String {
        switch error as? QTLastFMError {
        case .api(14, _)?: QTLoc.tr("Allow access on last.fm first", table: .desktop)
        case .api(10, _)?, .api(26, _)?, .api(13, _)?: QTLoc.tr("Check the API key and secret", table: .desktop)
        case .network?: QTLoc.tr("Last.fm can’t be reached", table: .desktop)
        default: QTLoc.tr("Couldn’t connect to Last.fm", table: .desktop)
        }
    }
}

// MARK: - Discord

struct QTDiscordSettingsSection: View {
    let store: QTIntegrationsStore
    /// "Use your own application ID" (the app has no Discord application of its own yet). Opens by itself when the
    /// switch is turned on without one.
    @State private var showsOwnID: Bool
    @FocusState private var focusesID: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: QTIntegrationsStore) {
        self.store = store
        let prefs = store.settings.discord
        _showsOwnID = State(initialValue: qtIntegrationsLaunchExpanded || (prefs.isEnabled && !prefs.hasValidClientID))
    }

    var body: some View {
        let prefs = store.settings.discord
        Section {
            Toggle(QTLoc.tr("Show what I’m listening to", table: .desktop), isOn: Binding(
                get: { prefs.isEnabled },
                set: { on in
                    store.update { $0.discord.isEnabled = on }
                    guard on, !store.settings.discord.hasValidClientID else { return }
                    withAnimation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion)) { showsOwnID = true }
                    focusesID = true
                }))
                .accessibilityIdentifier("qt.settings.discord.enabled")
            Toggle(QTLoc.tr("Show album art", table: .desktop), isOn: binding(store, \.discord.showsArtwork))
                .disabled(!prefs.isEnabled)
            DisclosureGroup(QTLoc.tr("Use your own application ID", table: .desktop), isExpanded: $showsOwnID) {
                QTIntegrationFieldRow(QTLoc.tr("Application ID", table: .desktop)) {
                    TextField(QTLoc.tr("Application ID", table: .desktop), text: binding(store, \.discord.clientID))
                        .autocorrectionDisabled()
                        .monospacedDigit()
                        .focused($focusesID)
                        .accessibilityIdentifier("qt.settings.discord.clientID")
                }
                QTIntegrationLinkRow(QTLoc.tr("Create a Discord application", table: .desktop),
                                     destination: URL(string: "https://discord.com/developers/applications")!)
            }
            .accessibilityIdentifier("qt.settings.discord.ownID")
        } header: {
            Text(verbatim: "Discord")
        }
    }
}

/// A labelled text field inside a "Use your own …" disclosure: a visible bordered field (an empty plain field in a
/// grouped form is invisible), no placeholder copy.
private struct QTIntegrationFieldRow<Field: View>: View {
    let title: String
    @ViewBuilder let field: Field

    init(_ title: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    var body: some View {
        LabeledContent(title) {
            field
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(.vertical, QTTheme.Spacing.xxs)
    }
}

/// Where to get the credential, leading-aligned under its fields.
private struct QTIntegrationLinkRow: View {
    let title: String
    let destination: URL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(title, destination: destination)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Notifications (General tab)

struct QTNotificationsSettingsSection: View {
    @State private var denied = false
    private var store: QTIntegrationsStore { QTIntegrationsCoordinator.shared.store }

    var body: some View {
        Section {
            Toggle(QTLoc.tr("Notify when the song changes", table: .desktop), isOn: Binding(
                get: { store.settings.notifiesTrackChanges },
                set: { on in
                    guard on else { store.update { $0.notifiesTrackChanges = false }; return }
                    QTTrackChangeNotifier.requestPermission { granted in
                        denied = !granted
                        store.update { $0.notifiesTrackChanges = granted }
                    }
                }))
                .accessibilityIdentifier("qt.settings.notifications")
        } footer: {
            if denied {
                Button(QTLoc.tr("Open Notification Settings", table: .desktop)) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
