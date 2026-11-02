import Foundation
import QTCore
import Testing
@testable import QTAuth

private final class QTFakeLegacySession: QTLegacySessionSource, @unchecked Sendable {
    var data: Data?
    var readError: Error?
    var reads = 0
    var deletes = 0
    init(data: Data?, readError: Error? = nil) {
        self.data = data
        self.readError = readError
    }
    func exists() -> Bool { data != nil }
    func read() throws -> Data? {
        reads += 1
        if let readError { throw readError }
        return data
    }
    func delete() throws {
        deletes += 1
        data = nil
    }
}

/// The session's private file, and the one move out of the Keychain.
@Suite struct QTFileSecureStoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "qt-private-\(UUID().uuidString)").appending(path: "Private")
    }

    private func store(_ dir: URL, legacy: (any QTLegacySessionSource)?) -> QTFileSecureStore {
        QTFileSecureStore(file: QTPrivateFile(url: dir.appending(path: "Session.json")),
                          migratedMarker: QTPrivateFile(url: dir.appending(path: "Session.migrated")), legacy: legacy)
    }

    @Test func fileIsOwnerOnlyAndRoundTrips() throws {
        let dir = folder()
        let s = store(dir, legacy: nil)
        #expect(try s.read() == nil)
        try s.write(Data("one".utf8))
        try s.write(Data("two".utf8))
        #expect(try s.read() == Data("two".utf8))
        let fm = FileManager.default
        let fileMode = try fm.attributesOfItem(atPath: dir.appending(path: "Session.json").path)[.posixPermissions] as? Int
        let dirMode = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasSuffix(".tmp") })
        try s.delete()
        try s.delete() // nothing there: fine
        #expect(try s.read() == nil)
    }

    @Test func keychainSessionMovesOnceAndTheItemGoes() throws {
        let dir = folder()
        let legacy = QTFakeLegacySession(data: Data("old".utf8))
        #expect(try store(dir, legacy: legacy).read() == Data("old".utf8))
        #expect(legacy.deletes == 1)
        // The next launch reads the file, and doesn't touch the Keychain.
        #expect(try store(dir, legacy: legacy).read() == Data("old".utf8))
        #expect(legacy.reads == 1)
    }

    @Test func noKeychainItemMeansNoPrompt() throws {
        let legacy = QTFakeLegacySession(data: nil)
        #expect(try store(folder(), legacy: legacy).read() == nil)
        #expect(legacy.reads == 0)
    }

    @Test func deniedPromptIsSignedOutAndNeverAsksAgain() throws {
        let dir = folder()
        let legacy = QTFakeLegacySession(data: Data("old".utf8), readError: QTAuthError.keychain(status: -128))
        #expect(try store(dir, legacy: legacy).read() == nil)
        #expect(try store(dir, legacy: legacy).read() == nil)
        #expect(legacy.reads == 1)
        #expect(legacy.deletes == 0)
    }

    @Test func signOutNeverBringsTheOldSessionBack() throws {
        let dir = folder()
        let legacy = QTFakeLegacySession(data: Data("old".utf8))
        let s = store(dir, legacy: legacy)
        try s.delete()
        #expect(try s.read() == nil)
        #expect(legacy.reads == 0)
    }
}
