import Combine
import QTCore
import QTUI
import Sparkle
import SwiftUI

// Owner: builder "desktop". Sparkle 2 (approved dependency), wired but dormant until there is a Developer ID:
// - no `SUFeedURL` in Info.plist → the updater is never started and Check for Updates… stays disabled;
// - `SUEnableAutomaticChecks` NO, `SUAutomaticallyUpdate` NO (build-app.sh);
// - no `SUPublicEDKey`, so Sparkle would refuse any unsigned update anyway.
// To turn it on later: add SUFeedURL + SUPublicEDKey (EdDSA) to the plist in build-app.sh, sign with Developer ID,
// notarize (user-gated). Sparkle.framework is embedded in Contents/Frameworks and ad-hoc signed with the app.

@MainActor
final class QTUpdater: ObservableObject {
    static let shared = QTUpdater()

    /// Created lazily, and only when a feed is configured (an unstarted controller never touches the network).
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    @Published private(set) var canCheckForUpdates = false

    static var feedURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
    }

    func start() {
        guard controller == nil, Self.feedURL != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        observation = c.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
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
