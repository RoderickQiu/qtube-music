import AppKit
import QTAuth
import QTCore
import SwiftUI
import UniformTypeIdentifiers

// Owner: builder "desktop". Settings › Account › Import Session: a collapsed disclosure at the bottom of the pane
// (signed out only) for accounts that can't finish Google's sign-in inside an app — passkey-only and Advanced
// Protection. It takes a session from a Firefox profile (plain SQLite, no Keychain prompt; found under Firefox's
// folder, or picked in the open panel when there's none or macOS keeps the app out) or a Netscape cookies.txt file,
// through `QTAuthController.importSession`, which keeps only the allow-listed auth cookies and checks the login with
// YouTube before keeping it. Chrome and Safari aren't offered (Keychain-encrypted, device-bound cookies / Full Disk
// Access).

/// Where an import reads from.
enum QTSessionImportSource: Equatable {
    case firefox(QTFirefoxProfile)
    case file(URL)
}

struct QTSessionImportSection: View {
    let auth: QTAuthController?
    /// Set after a cookies.txt import; the Account pane offers to move it to the Trash.
    @Binding var importedFile: URL?
    @State private var isExpanded = Self.launchExpanded
    @State private var isImporting = false
    @State private var failure: String? = Self.launchFailure
    /// Several Firefox profiles: which one.
    @State private var profileChoices: [QTFirefoxProfile] = []
    @State private var picker: Picker?

    /// What the open panel picks: a cookies.txt file, or a Firefox profile folder (no profile found where Firefox
    /// keeps them, macOS didn't let the app look, or the user chose to pick one).
    enum Picker { case cookiesFile, firefoxFolder }

    var body: some View {
        Section {
            DisclosureGroup(QTLoc.tr("Import Session", table: .desktop), isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: QTTheme.Spacing.s) {
                    Text(QTLoc.tr("For accounts that can’t sign in here, such as passkey-only or Advanced Protection accounts.", table: .desktop))
                    Text(QTLoc.tr("Firefox: sign in to music.youtube.com in a profile you won’t use for YouTube afterwards, quit Firefox, then import.", table: .desktop))
                        .foregroundStyle(.secondary)
                    Text(QTLoc.tr("cookies.txt: sign in in a private window, export cookies.txt with a cookies extension, close the window, then import the file.", table: .desktop))
                        .foregroundStyle(.secondary)
                    HStack(spacing: QTTheme.Spacing.s) {
                        Button(QTLoc.tr("Import from Firefox…", table: .desktop), action: importFromFirefox)
                            .accessibilityIdentifier("qt.settings.account.importFirefox")
                        Button(QTLoc.tr("Import cookies.txt…", table: .desktop)) { picker = .cookiesFile }
                            .accessibilityIdentifier("qt.settings.account.importFile")
                        if isImporting { ProgressView().controlSize(.small) }
                    }
                    // Not while the sign-in window is open (or another import is being checked).
                    .disabled(isImporting || auth == nil || auth?.state == .signingIn)
                    .padding(.top, 2)
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityIdentifier("qt.settings.account.importError")
                    }
                    Text(QTLoc.tr("Only Google’s sign-in cookies are kept, in your Keychain. Signing out in QTube Music also signs that browser session out.", table: .desktop))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("qt.settings.account.import")
        }
        .confirmationDialog(QTLoc.tr("Import from which Firefox profile?", table: .desktop),
                            isPresented: Binding(get: { !profileChoices.isEmpty }, set: { if !$0 { profileChoices = [] } })) {
            ForEach(profileChoices) { profile in
                Button(profile.isDefault ? QTLoc.tr("%@ (Default)", table: .desktop, profile.name) : profile.name) {
                    run(.firefox(profile))
                }
            }
            Button(QTLoc.tr("Choose Folder…", table: .desktop)) { picker = .firefoxFolder }
            Button(QTLoc.tr("Cancel", table: .desktop), role: .cancel) {}
        }
        .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                      allowedContentTypes: picker == .firefoxFolder ? [.folder] : [.plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            if picker == .firefoxFolder {
                run(.firefox(QTFirefoxProfile(name: url.lastPathComponent, directory: url)))
            } else {
                run(.file(url))
            }
        }
        .fileDialogDefaultDirectory(picker == .firefoxFolder
            ? QTFirefoxCookies.applicationSupport.appending(path: "Profiles", directoryHint: .isDirectory) : nil)
    }

    /// One Firefox profile: import it. Several: ask which. None found (or macOS didn't let the app look): the open
    /// panel, at Firefox's profiles folder.
    private func importFromFirefox() {
        let profiles = QTFirefoxCookies.profiles()
        switch profiles.count {
        case 0: picker = .firefoxFolder
        case 1: run(.firefox(profiles[0]))
        default: profileChoices = profiles
        }
    }

    /// User-initiated only (a menu choice or a picked file).
    private func run(_ source: QTSessionImportSource) {
        guard let auth, !isImporting else { return }
        isImporting = true
        failure = nil
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let cookies = try await Task.detached(priority: .userInitiated) { try Self.read(source) }.value
                try await auth.importSession(cookies: cookies)
                if case .file(let url) = source { importedFile = url }
            } catch is CancellationError {
                // Cancel (Settings › Account): nothing kept, nothing to report.
            } catch {
                failure = Self.message(for: error, source: source)
            }
        }
    }

    private nonisolated static func read(_ source: QTSessionImportSource) throws -> [QTCookie] {
        switch source {
        case .firefox(let profile):
            // A folder picked in the open panel carries the user's permission; a found profile doesn't need one.
            let scoped = profile.directory.startAccessingSecurityScopedResource()
            defer { if scoped { profile.directory.stopAccessingSecurityScopedResource() } }
            return try QTFirefoxCookies.cookies(in: profile)
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try QTCookieImport.readNetscape(at: url)
        }
    }

    static func message(for error: any Error, source: QTSessionImportSource) -> String {
        let isFirefox = if case .firefox = source { true } else { false }
        switch error {
        case QTAuthError.incompleteSession:
            return isFirefox ? QTLoc.tr("No YouTube Music sign-in found in this Firefox profile.", table: .desktop)
                : QTLoc.tr("No YouTube Music sign-in found in this file.", table: .desktop)
        case QTAuthError.sessionRejected:
            return QTLoc.tr("YouTube Music says this session has ended. Sign in again in the browser, then import again.", table: .desktop)
        case QTCookieImport.Failure.tooLarge:
            return QTLoc.tr("This file is too large to be a cookies file.", table: .desktop)
        case QTCookieImport.Failure.unexpectedFormat:
            return QTLoc.tr("This Firefox stores cookies in a way QTube Music can’t read. Use a cookies.txt file instead.", table: .desktop)
        case QTCookieImport.Failure.notPermitted:
            return QTLoc.tr("macOS didn’t let QTube Music read Firefox’s data. Try again and choose the profile folder yourself.", table: .desktop)
        case QTCookieImport.Failure.noDatabase:
            return QTLoc.tr("This folder isn’t a Firefox profile. Choose the folder that holds cookies.sqlite.", table: .desktop)
        case QTCookieImport.Failure.unreadable:
            return isFirefox ? QTLoc.tr("Couldn’t read Firefox’s cookies. Quit Firefox and try again.", table: .desktop)
                : QTLoc.tr("Couldn’t read this file.", table: .desktop)
        default:
            return QTLoc.tr("Couldn’t save the session in your Keychain.", table: .desktop)
        }
    }

    // MARK: Screenshots

    /// DEBUG `-qt.desktop.importExpanded YES`: the disclosure starts open.
    @MainActor private static var launchExpanded: Bool {
        #if DEBUG
        QTAppModel.shared.launch.bool("qt.desktop.importExpanded") ?? false
        #else
        false
        #endif
    }

    /// DEBUG `-qt.desktop.importError incomplete|rejected|unreadable|notPermitted`: the pane shows that failure (no import runs).
    @MainActor private static var launchFailure: String? {
        #if DEBUG
        let profile = QTSessionImportSource.firefox(QTFirefoxProfile(name: "default", directory: URL(fileURLWithPath: "/")))
        switch QTAppModel.shared.launch.string("qt.desktop.importError") {
        case "incomplete": return message(for: QTAuthError.incompleteSession, source: profile)
        case "rejected": return message(for: QTAuthError.sessionRejected, source: profile)
        case "unreadable": return message(for: QTCookieImport.Failure.unreadable, source: profile)
        case "notPermitted": return message(for: QTCookieImport.Failure.notPermitted, source: profile)
        default: return nil
        }
        #else
        nil
        #endif
    }
}
