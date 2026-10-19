import Foundation
import Testing
@testable import QTAuth
@testable import QTInnerTube

/// The session never reaches a persistent (plain-text) WebKit store; rotations flow both ways between the player's
/// jar and the Keychain. Fake cookies only.
@MainActor
@Suite struct SessionWebStoreTests {
    private func signedInKeychain() async throws -> QTMemorySecureStore {
        let memory = QTMemorySecureStore()
        try await QTSessionStore(store: memory).save(QTAuthSession(cookies: AuthTests.fakeLogin()))
        return memory
    }

    @Test func theAppsJarsAreMemoryOnly() {
        #expect(!QTWebKitCookieStore.session.isPersistent)
        #expect(!QTWebKitCookieStore.session.dataStore.isPersistent)
        // A fresh throwaway per sign-in attempt, never the session jar or WebKit's default store.
        let signIn = QTAuthController.makeSignInCookieStore()
        #expect(!signIn.isPersistent)
        #expect(signIn.dataStore !== QTWebKitCookieStore.session.dataStore)
        let controller = QTAuthController(sessionStore: QTSessionStore(store: QTMemorySecureStore()))
        #expect(controller.webDataStore === QTWebKitCookieStore.session.dataStore)
    }

    @Test func restoreSeedsTheNonPersistentJar() async throws {
        let memory = try await signedInKeychain()
        let jar = QTMemoryWebCookieStore()
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: jar)
        await controller.restore()
        #expect(controller.isSignedIn)
        #expect(jar.cookies.contains { $0.name == "SAPISID" })
        #expect(!jar.cookies.contains { $0.name == "VISITOR_INFO1_LIVE" })
    }

    @Test func restoreNeverWritesIntoAPersistentJar() async throws {
        let memory = try await signedInKeychain()
        let onDisk = QTMemoryWebCookieStore(isPersistent: true)
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: onDisk)
        await controller.restore()
        #expect(controller.isSignedIn)  // the API client still has the session…
        #expect(onDisk.cookies.isEmpty)  // …but nothing landed in the on-disk jar
        #if DEBUG
        try await controller.importSession(cookies: AuthTests.fakeLogin())
        #expect(onDisk.cookies.isEmpty)
        #endif
    }

    @Test func pageRotationsFoldIntoTheKeychain() async throws {
        let memory = try await signedInKeychain()
        let jar = QTMemoryWebCookieStore()
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: jar)
        controller.foldDelay = .milliseconds(10)
        await controller.restore()
        jar.simulatePageRotation([QTCookie(name: "__Secure-1PSIDTS", value: "PAGE-ROTATED", domain: ".youtube.com")])
        for _ in 0..<100 {
            if try await QTSessionStore(store: memory).restore()?.cookies.contains(where: { $0.value == "PAGE-ROTATED" }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await QTSessionStore(store: memory).restore()?.cookies.contains { $0.value == "PAGE-ROTATED" } == true)

        // Another login in the page (different SAPISID) is never folded into this session.
        jar.simulatePageRotation([
            QTCookie(name: "SAPISID", value: "OTHER-ACCOUNT", domain: ".youtube.com"),
            QTCookie(name: "__Secure-1PSIDTS", value: "OTHER-TS", domain: ".youtube.com"),
        ])
        await controller.foldWebCookies()
        let saved = try #require(try await QTSessionStore(store: memory).restore())
        #expect(saved.sapisid == "FAKE-SAPISID")
        #expect(!saved.cookies.contains { $0.value == "OTHER-TS" })
    }

    @Test func apiRotationsReachThePlayersJar() async throws {
        let memory = try await signedInKeychain()
        let store = QTSessionStore(store: memory)
        let jar = QTMemoryWebCookieStore()
        let controller = QTAuthController(sessionStore: store, cookieStore: jar)
        await controller.restore()
        let rotated = try #require(HTTPCookie(properties: [
            .name: "__Secure-3PSIDTS", .value: "API-ROTATED", .domain: ".youtube.com", .path: "/", .secure: "TRUE",
        ]))
        await store.didReceive(cookies: [rotated])
        for _ in 0..<100 where !jar.cookies.contains(where: { $0.value == "API-ROTATED" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(jar.cookies.contains { $0.value == "API-ROTATED" })
    }

    @Test func signOutEmptiesTheJar() async throws {
        let memory = try await signedInKeychain()
        let jar = QTMemoryWebCookieStore()
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: jar)
        await controller.restore()
        await controller.signOut()
        #expect(jar.cookies.filter(\.isGoogleOrYouTube).isEmpty)
        #expect(try memory.read() == nil)
    }

    @Test func legacyPersistentDataIsDeletedForQTubeOnly() throws {
        let fm = FileManager.default
        let library = fm.temporaryDirectory.appending(path: "qt-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: library) }
        for bundle in ["com.roderickqiu.qtube.dev-x", "com.example.other"] {
            let paths = QTLegacyWebStorage.paths(bundleID: bundle, library: library)
            try fm.createDirectory(at: paths[0].deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fake".utf8).write(to: paths[0])
            for dir in paths.dropFirst() { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        }
        // Another app's data is never touched.
        #expect(QTLegacyWebStorage.purge(bundleID: "com.example.other", library: library).isEmpty)
        #expect(fm.fileExists(atPath: QTLegacyWebStorage.paths(bundleID: "com.example.other", library: library)[0].path))

        let removed = QTLegacyWebStorage.purge(bundleID: "com.roderickqiu.qtube.dev-x", library: library)
        #expect(removed.count == 4)
        for url in QTLegacyWebStorage.paths(bundleID: "com.roderickqiu.qtube.dev-x", library: library) {
            #expect(!fm.fileExists(atPath: url.path))
        }
        // The app's other caches stay.
        #expect(fm.fileExists(atPath: library.appending(path: "Caches/com.roderickqiu.qtube.dev-x").path))
        #expect(QTLegacyWebStorage.purge(bundleID: "com.roderickqiu.qtube.dev-x", library: library).isEmpty)
    }
}
