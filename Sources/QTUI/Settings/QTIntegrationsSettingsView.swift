import AppKit
import QTCore
import QTIntegrations
import SwiftUI

// Owner: builder "desktop". Settings › Integrations (spec §10): Last.fm scrobbling and Discord Rich Presence,
// both off until the user sets them up. Last.fm uses the user's own API account (the app has no registered key
// yet): key + shared secret, then Last.fm's web authorization in the browser.

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

struct QTLastFMSettingsSection: View {
    let store: QTIntegrationsStore
    @State private var secretDraft = ""
    @State private var pendingToken: String?
    @State private var isWorking = false
    @State private var failure: String?

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
                TextField(QTLoc.tr("API Key", table: .desktop), text: binding(store, \.lastFM.apiKey),
                          prompt: Text(QTLoc.tr("Required", table: .desktop)))
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("qt.settings.lastfm.apiKey")
                SecureField(QTLoc.tr("Shared Secret", table: .desktop), text: $secretDraft,
                            prompt: Text(QTLoc.tr(prefs.hasSecret ? "Saved" : "Required", table: .desktop)))
                    .onSubmit(saveSecret)
                    .accessibilityIdentifier("qt.settings.lastfm.secret")
                LabeledContent {
                    HStack(spacing: QTTheme.Spacing.s) {
                        if isWorking { ProgressView().controlSize(.small) }
                        if pendingToken != nil {
                            Button(QTLoc.tr("Finish Connecting", table: .desktop), action: finishConnecting)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(QTLoc.tr("Connect…", table: .desktop), action: connect)
                                .disabled(!canConnect)
                        }
                    }
                } label: {
                    Text(QTLoc.tr("Account", table: .desktop))
                    if let failure { Text(verbatim: failure) }
                }
                .accessibilityIdentifier("qt.settings.lastfm.connect")
            }
        } header: {
            Text(verbatim: "Last.fm")
        } footer: {
            if prefs.username == nil {
                Link(QTLoc.tr("Get an API key", table: .desktop), destination: URL(string: "https://www.last.fm/api/account/create")!)
                    .font(.callout)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var canConnect: Bool {
        !isWorking && !store.settings.lastFM.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
            && (store.settings.lastFM.hasSecret || !secretDraft.isEmpty)
    }

    private func saveSecret() {
        guard !secretDraft.isEmpty else { return }
        store.setLastFMSecret(secretDraft)
        secretDraft = ""
    }

    /// Step 1: a request token, then Last.fm's approval page in the browser (user-initiated).
    private func connect() {
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

    var body: some View {
        let prefs = store.settings.discord
        Section {
            TextField(QTLoc.tr("Application ID", table: .desktop), text: binding(store, \.discord.clientID),
                      prompt: Text(QTLoc.tr("Required", table: .desktop)))
                .autocorrectionDisabled()
                .monospacedDigit()
                .accessibilityIdentifier("qt.settings.discord.clientID")
            Toggle(QTLoc.tr("Show what I’m listening to", table: .desktop), isOn: binding(store, \.discord.isEnabled))
                .disabled(!prefs.hasValidClientID)
                .accessibilityIdentifier("qt.settings.discord.enabled")
            Toggle(QTLoc.tr("Show album art", table: .desktop), isOn: binding(store, \.discord.showsArtwork))
                .disabled(!prefs.isEnabled)
        } header: {
            Text(verbatim: "Discord")
        } footer: {
            Link(QTLoc.tr("Create a Discord application", table: .desktop),
                 destination: URL(string: "https://discord.com/developers/applications")!)
                .font(.callout)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
