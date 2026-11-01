import QTCore
import SwiftUI

// Owner: builder "desktop". Settings › General › Updates. Sparkle lives in the app target (QTUpdater.swift); it
// attaches itself as the backend at launch. Builds without an appcast (dev builds) have no backend, so the section
// stays hidden.

/// What the app target's updater does for Settings.
@MainActor
public protocol QTUpdateBackend: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func checkForUpdates()
}

/// Observable mirror of the updater's settings for SwiftUI.
@MainActor
@Observable
public final class QTUpdateSettings {
    public static let shared = QTUpdateSettings()

    public private(set) var isAvailable = false
    public private(set) var canCheckForUpdates = false
    public private(set) var lastCheck: Date?
    public private(set) var automaticallyChecks = false
    public private(set) var automaticallyInstalls = false
    @ObservationIgnored private weak var backend: (any QTUpdateBackend)?

    public init() {}

    public func attach(_ backend: any QTUpdateBackend) {
        self.backend = backend
        isAvailable = true
        refresh()
    }

    /// The updater reports a change (check finished, `canCheckForUpdates` flipped).
    public func update(canCheckForUpdates: Bool, lastCheck: Date?) {
        self.canCheckForUpdates = canCheckForUpdates
        self.lastCheck = lastCheck
        refresh()
    }

    public func setAutomaticallyChecks(_ on: Bool) {
        backend?.automaticallyChecksForUpdates = on
        refresh()
    }

    public func setAutomaticallyInstalls(_ on: Bool) {
        backend?.automaticallyDownloadsUpdates = on
        refresh()
    }

    public func checkNow() { backend?.checkForUpdates() }

    private func refresh() {
        guard let backend else { return }
        automaticallyChecks = backend.automaticallyChecksForUpdates
        automaticallyInstalls = backend.automaticallyDownloadsUpdates
    }

    /// "1.4.0 (212)" from the bundle.
    public static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }
}

/// Settings › General › Updates.
struct QTUpdateSettingsSection: View {
    @State private var updates = QTUpdateSettings.shared

    var body: some View {
        if updates.isAvailable {
            Section(QTLoc.tr("Updates", table: .desktop)) {
                Toggle(QTLoc.tr("Check for updates automatically", table: .desktop),
                       isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }))
                    .accessibilityIdentifier("qt.settings.updates.autoCheck")
                Toggle(QTLoc.tr("Download and install updates automatically", table: .desktop),
                       isOn: Binding(get: { updates.automaticallyChecks && updates.automaticallyInstalls },
                                     set: { updates.setAutomaticallyInstalls($0) }))
                    .disabled(!updates.automaticallyChecks)
                    .accessibilityIdentifier("qt.settings.updates.autoInstall")
                LabeledContent {
                    Button(QTLoc.tr("Check Now", table: .desktop)) { updates.checkNow() }
                        .disabled(!updates.canCheckForUpdates)
                        .accessibilityIdentifier("qt.settings.updates.checkNow")
                } label: {
                    Text(verbatim: QTLoc.tr("Version %@", table: .desktop, QTUpdateSettings.versionString))
                    Text(verbatim: lastCheckText)
                }
            }
        }
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return QTLoc.tr("Not checked yet", table: .desktop) }
        let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide, locale: QTLoc.locale)
        return QTLoc.tr("Last checked %@", table: .desktop, date.formatted(style))
    }
}
