import Foundation
import QTCore
import Testing
@testable import QTIntegrations

private final class QTFakeLegacySecrets: QTLegacyIntegrationSecrets, @unchecked Sendable {
    var values: [QTIntegrationSecret: String]
    var denied: Set<QTIntegrationSecret> = []
    var reads = 0
    init(_ values: [QTIntegrationSecret: String]) { self.values = values }
    func exists(_ secret: QTIntegrationSecret) -> Bool { values[secret] != nil }
    func get(_ secret: QTIntegrationSecret) -> String? {
        reads += 1
        return denied.contains(secret) ? nil : values[secret]
    }
    func set(_ value: String, for secret: QTIntegrationSecret) { values[secret] = value }
    func remove(_ secret: QTIntegrationSecret) { values[secret] = nil }
}

@Suite struct QTFileSecretStoreTests {
    private func store(_ dir: URL, legacy: (any QTLegacyIntegrationSecrets)?) -> QTFileSecretStore {
        QTFileSecretStore(file: QTPrivateFile(url: dir.appending(path: "Integrations.json")),
                          migratedMarker: QTPrivateFile(url: dir.appending(path: "Integrations.migrated")), legacy: legacy)
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "qt-private-\(UUID().uuidString)").appending(path: "Private")
    }

    @Test func keysRoundTripInOneFile() {
        let dir = folder()
        let s = store(dir, legacy: nil)
        #expect(s.get(.listenBrainzToken) == nil)
        s.set("token", for: .listenBrainzToken)
        s.set("session", for: .lastFMSessionKey)
        #expect(store(dir, legacy: nil).get(.listenBrainzToken) == "token")
        s.remove(.listenBrainzToken)
        #expect(s.get(.listenBrainzToken) == nil)
        #expect(s.get(.lastFMSessionKey) == "session")
    }

    @Test func keychainKeysMoveOnceAndTheItemsGo() {
        let dir = folder()
        let legacy = QTFakeLegacySecrets([.lastFMSessionKey: "session", .listenBrainzToken: "token"])
        #expect(store(dir, legacy: legacy).get(.lastFMSessionKey) == "session")
        #expect(legacy.values.isEmpty)
        #expect(legacy.reads == 2) // only the keys that exist: one prompt each
        #expect(store(dir, legacy: legacy).get(.listenBrainzToken) == "token")
        #expect(legacy.reads == 2)
    }

    @Test func aDeniedKeyStaysBehindAndIsNotAskedForAgain() {
        let dir = folder()
        let legacy = QTFakeLegacySecrets([.lastFMSessionKey: "session", .listenBrainzToken: "token"])
        legacy.denied = [.listenBrainzToken]
        let s = store(dir, legacy: legacy)
        #expect(s.get(.lastFMSessionKey) == "session")
        #expect(s.get(.listenBrainzToken) == nil)
        #expect(legacy.values == [.listenBrainzToken: "token"])
        #expect(legacy.reads == 2)
    }

    @Test func noItemsMeansNoPrompts() {
        let legacy = QTFakeLegacySecrets([:])
        #expect(store(folder(), legacy: legacy).get(.lastFMSecret) == nil)
        #expect(legacy.reads == 0)
    }
}
