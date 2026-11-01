import Combine
import QTCore
import QTUI
import Sparkle
import SwiftUI

// Owner: builder "desktop". Sparkle 2 updates (docs/architecture.md › Updates).
// - Release builds carry `SUFeedURL` (the appcast attached to the latest GitHub Release) and `SUPublicEDKey`; every
//   archive and the feed itself must be EdDSA-signed with its private half (Scripts/release.sh does it).
// - Builds without a feed (dev builds) never start the updater: Check for Updates… stays disabled and
//   Settings › General › Updates is hidden.
// - Checks are daily and on by default (SUEnableAutomaticChecks: no first-run permission prompt); installing in the
//   background is opt-in (Settings; those install when the app quits). A found update shows Sparkle's own window
//   with the release notes.

@MainActor
final class QTUpdater: ObservableObject, QTUpdateBackend {
    static let shared = QTUpdater()

    /// Created lazily, and only when a feed is configured (an unstarted controller never touches the network).
    private var controller: SPUStandardUpdaterController?
    private var observations: [AnyCancellable] = []
    @Published private(set) var canCheckForUpdates = false

    static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
    }

    func start() {
        guard controller == nil, Self.feedURL != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        let updater = c.updater
        observations = [
            updater.publisher(for: \.canCheckForUpdates).map { _ in () }.eraseToAnyPublisher(),
            updater.publisher(for: \.lastUpdateCheckDate).map { _ in () }.eraseToAnyPublisher(),
        ].map { publisher in
            publisher.receive(on: DispatchQueue.main).sink { [weak self] in self?.publish() }
        }
        QTUpdateSettings.shared.attach(self)
        publish()
    }

    private func publish() {
        guard let updater = controller?.updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        QTUpdateSettings.shared.update(canCheckForUpdates: updater.canCheckForUpdates,
                                       lastCheck: updater.lastUpdateCheckDate)
    }

    // MARK: QTUpdateBackend

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// App menu › Check for Updates… (after About).
struct QTUpdaterCommands: Commands {
    @ObservedObject var updater: QTUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(QTLoc.tr("Check for Updates…", table: .desktop)) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
