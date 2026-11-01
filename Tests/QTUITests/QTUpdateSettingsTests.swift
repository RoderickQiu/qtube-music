import Foundation
import Testing
@testable import QTUI

@MainActor
private final class QTFakeUpdateBackend: QTUpdateBackend {
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var checks = 0
    func checkForUpdates() { checks += 1 }
}

/// Settings › General › Updates mirrors Sparkle's own settings (QTUpdater in the app target).
@MainActor
@Suite struct QTUpdateSettingsTests {
    @Test func hiddenUntilAnUpdaterAttaches() {
        let settings = QTUpdateSettings()
        #expect(!settings.isAvailable)
        settings.checkNow() // no backend: nothing happens, nothing crashes
        settings.attach(QTFakeUpdateBackend())
        #expect(settings.isAvailable)
    }

    @Test func togglesWriteThroughToTheUpdater() {
        let backend = QTFakeUpdateBackend()
        let settings = QTUpdateSettings()
        settings.attach(backend)
        #expect(settings.automaticallyChecks && !settings.automaticallyInstalls)
        settings.setAutomaticallyInstalls(true)
        #expect(backend.automaticallyDownloadsUpdates && settings.automaticallyInstalls)
        settings.setAutomaticallyChecks(false)
        #expect(!backend.automaticallyChecksForUpdates && !settings.automaticallyChecks)
    }

    @Test func checkNowAndUpdaterReports() {
        let backend = QTFakeUpdateBackend()
        let settings = QTUpdateSettings()
        settings.attach(backend)
        settings.checkNow()
        #expect(backend.checks == 1)
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        settings.update(canCheckForUpdates: true, lastCheck: when)
        #expect(settings.canCheckForUpdates && settings.lastCheck == when)
    }
}
