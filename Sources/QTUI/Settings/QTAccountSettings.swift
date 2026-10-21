import AppKit
import QTAuth
import QTCore
import QTInnerTube
import SwiftUI

// Owner: builder "desktop". Settings › Account: who is signed in to YouTube Music, sign in / sign out, and the
// playback engine. Reads `QTAuthController.state` (`QTAuthState`) from `model.authController`, which
// `QTLiveCatalogStore` (data-live) sets at launch and restores from the Keychain. Signing out asks first, the way System Settings does.

/// What the Account tab shows: the controller's state, or (DEBUG screenshots) a preview state.
struct QTAccountSnapshot: Equatable {
    var state: QTAuthState
    var account: QTAccountInfo?
    /// The Google account and its brand accounts (a picker when there's more than one).
    var identities: [QTAccountIdentity] = []
    /// The identity in use (`brandId`, nil = the Google account itself).
    var activeBrandId: String?

    var name: String? {
        if let n = account?.name, !n.isEmpty { return n }
        if case .signedIn(let n, _) = state, !n.isEmpty { return n }
        return nil
    }

    var isPremium: Bool {
        if case .signedIn(_, let premium) = state { return premium || account?.isPremium == true }
        return account?.isPremium == true
    }

    #if DEBUG
    /// `-qt.desktop.accountPreview signedIn|premium|signingIn|expired|signedOut` (screenshots; no Keychain access).
    static func preview(_ argument: String?) -> QTAccountSnapshot? {
        let sample = QTAccountInfo(name: "Alex Rivera", handle: "@alexrivera")
        // A Google account with one brand account (channel), for the identity picker.
        let identities = [QTAccountIdentity(name: sample.name, handle: sample.handle, isSelected: true),
                          QTAccountIdentity(name: "Alex Rivera Music", handle: "@alexriveramusic",
                                            brandId: "100000000000000000001")]
        switch argument {
        case "signedIn": return QTAccountSnapshot(state: .signedIn(accountName: sample.name, isPremium: false), account: sample)
        case "premium":
            return QTAccountSnapshot(state: .signedIn(accountName: sample.name, isPremium: true), account: sample,
                                     identities: identities)
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

    static let previewKey = "qt.desktop.accountPreview"

    private var snapshot: QTAccountSnapshot {
        #if DEBUG
        if let p = QTAccountSnapshot.preview(model.launch.string(Self.previewKey)) { return p }
        #endif
        guard let auth = model.authController else { return QTAccountSnapshot(state: .signedOut, account: nil) }
        return QTAccountSnapshot(state: auth.state, account: auth.account, identities: QTLiveCatalogStore.shared.identities,
                                 activeBrandId: auth.brandAccountId)
    }

    private var isPreview: Bool {
        #if DEBUG
        return QTAccountSnapshot.preview(model.launch.string(Self.previewKey)) != nil
        #else
        return false
        #endif
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
                if snap.identities.count > 1, case .signedIn = snap.state {
                    QTIdentityPicker(identities: snap.identities, activeBrandId: snap.activeBrandId, isPreview: isPreview)
                }
            }
            Section {
                Toggle(QTLoc.tr("Sync likes and playlists to YouTube Music", table: .desktop), isOn: Binding(
                    get: { model.settings.settings.syncsToYouTubeMusic },
                    set: { on in model.settings.update { $0.syncsToYouTubeMusic = on } }))
                    .accessibilityIdentifier("qt.settings.account.sync")
            } footer: {
                Text(QTLoc.tr(model.settings.settings.syncsToYouTubeMusic
                              ? "Likes, playlists, subscriptions and saved albums change in your YouTube Music account."
                              : "Likes and playlist changes stay on this Mac.", table: .desktop))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .formStyle(.grouped)
        .confirmationDialog(QTLoc.tr("Sign out of YouTube Music?", table: .desktop), isPresented: $confirmSignOut) {
            Button(QTLoc.tr("Sign Out", table: .desktop), role: .destructive) {
                // Through the live store (it also clears the library pages and continues in guest mode).
                Task { await QTLiveCatalogStore.shared.signOut() }
            }
        } message: {
            Text(QTLoc.tr("Your YouTube Music library stays in your account.", table: .desktop))
        }
        .task(id: snapshot.state) {
            // The brand accounts (a read of the account list) — only when this tab is open and signed in.
            if case .signedIn = snapshot.state, !isPreview { await QTLiveCatalogStore.shared.loadIdentities() }
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

/// The identity picker: the Google account and its brand accounts (channels). Choosing one moves the library, likes,
/// playlist changes and plays to it (`QTLiveCatalogStore.switchIdentity`); a spinner shows while the player page
/// switches, and nothing changes if it can't be confirmed.
struct QTIdentityPicker: View {
    let identities: [QTAccountIdentity]
    let activeBrandId: String?
    var isPreview = false
    @State private var previewSelection: String?

    var body: some View {
        let store = QTLiveCatalogStore.shared
        let selection = Binding<String>(
            get: { previewSelection ?? store.switchingIdentity?.id ?? activeBrandId ?? "primary" },
            set: { id in
                if isPreview { previewSelection = id; return }
                guard let target = identities.first(where: { $0.id == id }) else { return }
                Task { await store.switchIdentity(to: target) }
            })
        HStack(spacing: QTTheme.Spacing.xs) {
            Picker(QTLoc.tr("Account", table: .desktop), selection: selection) {
                ForEach(identities) { identity in
                    Text(verbatim: Self.title(identity, among: identities)).tag(identity.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(store.switchingIdentity != nil)
            if store.switchingIdentity != nil {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityIdentifier("qt.settings.account.identities")
    }

    /// The name; with the handle when two identities share a name.
    static func title(_ identity: QTAccountIdentity, among all: [QTAccountIdentity]) -> String {
        guard let handle = identity.handle, all.filter({ $0.name == identity.name }).count > 1 else { return identity.name }
        return "\(identity.name) (\(handle))"
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
