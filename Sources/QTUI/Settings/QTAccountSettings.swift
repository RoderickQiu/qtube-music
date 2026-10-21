import AppKit
import QTAuth
import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "desktop". Settings › Account: who is signed in to YouTube Music, sign in / sign out, and the
// playback engine. Reads `QTAuthController.state` (`QTAuthState`) from `model.authController`, which
// `QTLiveCatalogStore` (data-live) sets at launch and restores from the Keychain. Signing out asks first, the way System Settings does.
// Signed out, a collapsed "Import Session" disclosure at the bottom takes a session from Firefox or a cookies.txt file
// (`QTSessionImportSection`): the way in for accounts that can't finish Google's sign-in in an app.

/// What the Account tab shows: the controller's state, or (DEBUG screenshots) a preview state.
struct QTAccountSnapshot: Equatable {
    var state: QTAuthState
    var account: QTAccountInfo?

    var name: String? {
        if let n = account?.name, !n.isEmpty { return n }
        if case .signedIn(let n, _) = state, !n.isEmpty { return n }
        return nil
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var isPremium: Bool {
        if case .signedIn(_, let premium) = state { return premium || account?.isPremium == true }
        return account?.isPremium == true
    }

    #if DEBUG
    /// `-qt.desktop.accountPreview signedIn|premium|signingIn|expired|signedOut` (screenshots; no Keychain access).
    static func preview(_ argument: String?) -> QTAccountSnapshot? {
        let sample = QTAccountInfo(name: "Alex Rivera", handle: "@alexrivera")
        switch argument {
        case "signedIn": return QTAccountSnapshot(state: .signedIn(accountName: sample.name, isPremium: false), account: sample)
        case "premium": return QTAccountSnapshot(state: .signedIn(accountName: sample.name, isPremium: true), account: sample)
        case "signingIn": return QTAccountSnapshot(state: .signingIn, account: nil)
        case "expired": return QTAccountSnapshot(state: .sessionExpired, account: sample)
        case "signedOut": return QTAccountSnapshot(state: .signedOut, account: nil)
        default: return nil
        }
    }
    #endif
}

struct QTAccountSettings: View {
    @Environment(QTAppModel.self) private var model
    @State private var confirmSignOut = false
    /// A cookies.txt that was just imported: offered for the Trash (it signs anyone in as the user).
    @State private var importedFile: URL?

    static let previewKey = "qt.desktop.accountPreview"
    /// Google's list of devices signed in to the account.
    static let deviceActivityURL = URL(string: "https://myaccount.google.com/device-activity")!

    private var snapshot: QTAccountSnapshot {
        #if DEBUG
        if let p = QTAccountSnapshot.preview(model.launch.string(Self.previewKey)) { return p }
        #endif
        guard let auth = model.authController else { return QTAccountSnapshot(state: .signedOut, account: nil) }
        return QTAccountSnapshot(state: auth.state, account: auth.account)
    }

    var body: some View {
        let snap = snapshot
        Form {
            Section {
                HStack(spacing: QTTheme.Spacing.s) {
                    QTAccountAvatar(name: snap.name, photo: snap.account?.photo ?? [],
                                    isSignedIn: snap.name != nil && snap.state != .signedOut)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(snap)).font(.headline)
                        subtitle(snap)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: QTTheme.Spacing.s)
                    actions(snap)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("qt.settings.account.identity")
            } footer: {
                if snap.state != .signedOut, snap.state != .signingIn {
                    HStack(spacing: 4) {
                        Text(QTLoc.tr("Signing out also ends this session at Google.", table: .desktop))
                            .foregroundStyle(.secondary)
                        Link(QTLoc.tr("Your Devices…", table: .desktop), destination: Self.deviceActivityURL)
                            .accessibilityIdentifier("qt.settings.account.devices")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section {
                #if DEBUG
                Picker(QTLoc.tr("Playback engine", table: .desktop), selection: Binding(get: { model.account }, set: { model.account = $0 })) {
                    Text(QTLoc.tr("Premium engine")).tag(QTAccountKind.premium)
                    Text(QTLoc.tr("Free (ads)")).tag(QTAccountKind.free)
                }
                #else
                LabeledContent(QTLoc.tr("Playback engine", table: .desktop)) {
                    Text(model.account == .premium ? QTLoc.tr("Premium engine") : QTLoc.tr("Free (ads)"))
                }
                #endif
            }
            // Also while signing in: an import shows `.signingIn` while YouTube checks it, and its error must stay.
            if !snap.isSignedIn {
                QTSessionImportSection(auth: model.authController, importedFile: $importedFile)
            }
        }
        .formStyle(.grouped)
        // Here, not in the import section: a successful import signs in, and the section goes.
        .alert(QTLoc.tr("Move the cookies file to the Trash?", table: .desktop),
               isPresented: Binding(get: { importedFile != nil }, set: { if !$0 { importedFile = nil } })) {
            Button(QTLoc.tr("Move to Trash", table: .desktop), role: .destructive) {
                if let url = importedFile { NSWorkspace.shared.recycle([url]) }
                importedFile = nil
            }
            Button(QTLoc.tr("Keep", table: .desktop), role: .cancel) { importedFile = nil }
        } message: {
            Text(QTLoc.tr("Anyone with this file can use your Google account. QTube Music keeps its own copy in your Keychain.", table: .desktop))
        }
        .confirmationDialog(QTLoc.tr("Sign out of YouTube Music?", table: .desktop), isPresented: $confirmSignOut) {
            Button(QTLoc.tr("Sign Out", table: .desktop), role: .destructive) {
                // Through the live store (it also clears the library pages and continues in guest mode).
                Task { await QTLiveCatalogStore.shared.signOut() }
            }
        } message: {
            Text(QTLoc.tr("Your library and likes stay in your YouTube Music account.", table: .desktop))
        }
    }

    private func title(_ snap: QTAccountSnapshot) -> String {
        switch snap.state {
        case .signedOut: QTLoc.tr("Not signed in", table: .desktop)
        case .signingIn: QTLoc.tr("Signing In…", table: .desktop)
        case .signedIn, .sessionExpired: snap.name ?? QTLoc.tr("YouTube Music", table: .desktop)
        }
    }

    @ViewBuilder
    private func subtitle(_ snap: QTAccountSnapshot) -> some View {
        switch snap.state {
        case .signedOut, .signingIn:
            Text(verbatim: "YouTube Music")
        case .signedIn:
            if snap.isPremium {
                Text(QTLoc.tr("YouTube Music Premium", table: .desktop))
            } else if let handle = snap.account?.handle, !handle.isEmpty {
                Text(verbatim: handle)
            } else {
                Text(verbatim: "YouTube Music")
            }
        case .sessionExpired:
            Label(QTLoc.tr("Session expired", table: .desktop), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.multicolor)
        }
    }

    @ViewBuilder
    private func actions(_ snap: QTAccountSnapshot) -> some View {
        switch snap.state {
        case .signedOut:
            Button(QTLoc.tr("Sign In…", table: .desktop)) { signIn() }
                .accessibilityIdentifier("qt.settings.account.signIn")
        case .signingIn:
            HStack(spacing: QTTheme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Button(QTLoc.tr("Cancel", table: .desktop)) { model.authController?.cancelSignIn() }
            }
        case .signedIn:
            Button(QTLoc.tr("Sign Out…", table: .desktop)) { confirmSignOut = true }
                .accessibilityIdentifier("qt.settings.account.signOut")
        case .sessionExpired:
            HStack(spacing: QTTheme.Spacing.xs) {
                Button(QTLoc.tr("Sign Out…", table: .desktop)) { confirmSignOut = true }
                Button(QTLoc.tr("Sign In Again…", table: .desktop)) { signIn() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// User-initiated only (a click). The live store owns the app's `QTAuthController` (`model.authController`)
    /// and its InnerTube client; a successful sign-in switches the window to the user's library.
    private func signIn() {
        QTLiveCatalogStore.shared.signIn()
    }
}

/// Account photo, or a monogram on the accent colour (like Contacts), or the generic person symbol.
struct QTAccountAvatar: View {
    let name: String?
    let photo: [QTArtworkImage]
    let isSignedIn: Bool
    var size: CGFloat = 40

    var body: some View {
        Group {
            if isSignedIn, !photo.isEmpty {
                QTArtworkView(photo, cornerRadius: size / 2)
            } else if isSignedIn, let initials = Self.initials(name) {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .overlay {
                        Text(verbatim: initials)
                            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    static func initials(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), let first = name.first else { return nil }
        // Han names: the first character reads naturally; Latin names: first letters of the first two words.
        if first.unicodeScalars.first.map({ $0.properties.isIdeographic }) == true { return String(first) }
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? nil : String(parts).uppercased()
    }
}
