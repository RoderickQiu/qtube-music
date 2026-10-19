import Foundation
import Testing
@testable import QTAuth
@testable import QTInnerTube

/// QTAuth with fake cookies only — never the user's real session.
@Suite struct AuthTests {
    static func fakeLogin(sapisidName: String = "SAPISID") -> [QTCookie] {
        [
            QTCookie(name: sapisidName, value: "FAKE-SAPISID", domain: ".youtube.com"),
            QTCookie(name: "SID", value: "FAKE-SID", domain: ".youtube.com"),
            QTCookie(name: "HSID", value: "FAKE-HSID", domain: ".youtube.com", isSecure: false, isHTTPOnly: true),
            QTCookie(name: "__Secure-1PSIDTS", value: "FAKE-TS", domain: ".youtube.com", isHTTPOnly: true),
            QTCookie(name: "SAPISID", value: "FAKE-SAPISID", domain: ".google.com"),
            QTCookie(name: "LOGIN_INFO", value: "FAKE-LOGIN", domain: ".youtube.com"),
            // Not kept: tracking / unrelated cookies and other sites.
            QTCookie(name: "VISITOR_INFO1_LIVE", value: "visitor", domain: ".youtube.com"),
            QTCookie(name: "SID", value: "other-site", domain: ".example.com"),
            QTCookie(name: "SSID", value: "expired", domain: ".youtube.com", expires: Date(timeIntervalSince1970: 0)),
        ]
    }

    @Test func cookieRoundTripsThroughHTTPCookie() throws {
        let c = QTCookie(name: "SID", value: "v", domain: ".youtube.com", path: "/",
                         expires: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 30 * 86_400).rounded()),
                         isSecure: true, isHTTPOnly: true)
        let http = try #require(c.httpCookie)
        #expect(http.name == "SID" && http.domain == ".youtube.com" && http.isSecure && http.isHTTPOnly)
        #expect(QTCookie(http).expires == c.expires)
        #expect(c.matches(host: "music.youtube.com"))
        #expect(!c.matches(host: "notyoutube.com"))
    }

    @Test func sessionKeepsOnlyAuthCookies() {
        let filtered = QTAuthSession.filtered(Self.fakeLogin())
        let names = Set(filtered.map { "\($0.name)@\($0.bareDomain)" })
        #expect(names.contains("SAPISID@youtube.com"))
        #expect(names.contains("SAPISID@google.com"))
        #expect(!names.contains("VISITOR_INFO1_LIVE@youtube.com"))
        #expect(!names.contains("SID@example.com"))
        #expect(!names.contains("SSID@youtube.com"))
    }

    @Test func credentialsFromSession() throws {
        let session = QTAuthSession(cookies: QTAuthSession.filtered(Self.fakeLogin()), authUser: 2,
                                    brandAccountId: "UCbrand")
        #expect(session.isComplete)
        let creds = try #require(session.credentials())
        #expect(creds.sapisid == "FAKE-SAPISID")
        #expect(creds.authUser == 2)
        #expect(creds.onBehalfOfUser == "UCbrand")
        // Only cookies music.youtube.com would receive.
        #expect(creds.cookieHeader.contains("SID=FAKE-SID"))
        #expect(!creds.cookieHeader.contains("example"))
        #expect(creds.cookieHeader.split(separator: ";").count == 5)

        // Newer sessions: __Secure-3PAPISID carries the SAPISID value.
        let modern = QTAuthSession(cookies: QTAuthSession.filtered([
            QTCookie(name: "__Secure-3PAPISID", value: "FAKE-3P", domain: ".youtube.com"),
            QTCookie(name: "__Secure-3PSID", value: "FAKE-3PSID", domain: ".youtube.com"),
        ]))
        #expect(modern.isComplete)
        #expect(modern.sapisid == "FAKE-3P")
        #expect(QTAuthSession(cookies: [QTCookie(name: "SID", value: "x", domain: ".youtube.com")]).isComplete == false)
    }

    @Test func sessionStoreLifecycle() async throws {
        let memory = QTMemorySecureStore()
        let store = QTSessionStore(store: memory)
        let events = await store.events()
        var iterator = events.makeAsyncIterator()

        #expect(try await store.restore() == nil)
        #expect(await store.credentials() == nil)

        try await store.save(QTAuthSession(cookies: Self.fakeLogin()))
        #expect(await iterator.next() == .signedIn)
        #expect(await store.credentials()?.sapisid == "FAKE-SAPISID")
        #expect(try memory.read() != nil)

        // A fresh store restores from the same (Keychain) data.
        let reopened = QTSessionStore(store: memory)
        let restored = try #require(try await reopened.restore())
        #expect(restored.sapisid == "FAKE-SAPISID")
        #expect(!restored.cookies.contains { $0.name == "VISITOR_INFO1_LIVE" })

        // Rotation merges and persists.
        await store.merge([QTCookie(name: "__Secure-1PSIDTS", value: "ROTATED", domain: ".youtube.com")])
        #expect(await store.current?.cookies.first { $0.name == "__Secure-1PSIDTS" }?.value == "ROTATED")
        #expect(try await QTSessionStore(store: memory).restore()?.cookies.contains { $0.value == "ROTATED" } == true)

        // Session loss: credentials stop being offered; the UI hears about it once.
        await store.sessionDidExpire()
        await store.sessionDidExpire()
        #expect(await iterator.next() == .expired)
        #expect(await store.credentials() == nil)
        #expect(await store.expired)

        try await store.clear()
        #expect(await iterator.next() == .signedOut)
        #expect(try memory.read() == nil)
    }

    @Test func incompleteSessionIsRejected() async {
        let store = QTSessionStore(store: QTMemorySecureStore())
        await #expect(throws: QTAuthError.incompleteSession) {
            try await store.save(QTAuthSession(cookies: [QTCookie(name: "PREF", value: "x", domain: ".youtube.com")]))
        }
    }

    @Test func corruptKeychainDataIsDiscarded() async throws {
        let memory = QTMemorySecureStore(data: Data("not json".utf8))
        #expect(try await QTSessionStore(store: memory).restore() == nil)
        #expect(try memory.read() == nil)
    }

    @MainActor
    @Test func controllerRestoreImportAndSignOut() async throws {
        let memory = QTMemorySecureStore()
        let web = QTMemoryWebCookieStore()
        let client = QTInnerTubeClient(transport: FakeTransport(), scrapesClientConfig: false)
        let controller = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: web, client: client)
        await controller.restore()
        #expect(controller.state == .signedOut)

        #if DEBUG
        try await controller.importSession(cookies: Self.fakeLogin(), authUser: 0)
        #expect(controller.isSignedIn)
        // Written to both the Keychain item and WebKit's jar — only the auth cookies.
        #expect(try memory.read() != nil)
        #expect(web.cookies.contains { $0.name == "SAPISID" && $0.value == "FAKE-SAPISID" })
        #expect(!web.cookies.contains { $0.name == "VISITOR_INFO1_LIVE" })
        await #expect(throws: QTAuthError.incompleteSession) {
            try await controller.importSession(cookies: [QTCookie(name: "PREF", value: "x", domain: ".youtube.com")])
        }
        #endif

        // Launch path: a new controller restores from the Keychain and re-seeds an empty WebKit jar.
        let emptyWeb = QTMemoryWebCookieStore()
        let relaunched = QTAuthController(sessionStore: QTSessionStore(store: memory), cookieStore: emptyWeb,
                                          client: client)
        await relaunched.restore()
        #expect(relaunched.isSignedIn)
        #expect(emptyWeb.cookies.contains { $0.name == "SID" })

        await relaunched.signOut()
        #expect(relaunched.state == .signedOut)
        #expect(try memory.read() == nil)
        let remaining = emptyWeb.cookies.filter(\.isGoogleOrYouTube)
        #expect(remaining.isEmpty)
    }

    @MainActor
    @Test func controllerReactsToSessionLoss() async throws {
        let memory = QTMemorySecureStore()
        let store = QTSessionStore(store: memory)
        try await store.save(QTAuthSession(cookies: Self.fakeLogin()))
        let controller = QTAuthController(sessionStore: store, cookieStore: QTMemoryWebCookieStore())
        await controller.restore()
        #expect(controller.isSignedIn)
        await store.sessionDidExpire()
        for _ in 0..<50 where controller.state != .sessionExpired {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.state == .sessionExpired)
    }

    /// Touches the login Keychain with a throwaway test item; opt-in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QT_KEYCHAIN_TEST"] == "1"))
    func keychainRoundTrip() throws {
        let keychain = QTKeychainStore(service: "com.roderickqiu.qtube.tests", account: "fake-\(UUID().uuidString)")
        defer { try? keychain.delete() }
        #expect(try keychain.read() == nil)
        try keychain.write(Data("one".utf8))
        try keychain.write(Data("two".utf8))
        #expect(try keychain.read() == Data("two".utf8))
        try keychain.delete()
        #expect(try keychain.read() == nil)
    }

    #if DEBUG
    /// The prompt-free shared dev item, with a throwaway account and fake data; opt-in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QT_KEYCHAIN_TEST"] == "1"))
    func devSharedKeychainRoundTrip() throws {
        let store = QTDevSharedKeychainStore(service: "com.roderickqiu.qtube.tests", account: "fake-\(UUID().uuidString)")
        defer { try? store.delete() }
        #expect(try store.read() == nil)
        // Incompressible payload → several chunks.
        var big = Data(count: 9000)
        for i in big.indices { big[i] = UInt8.random(in: 0...255) }
        try store.write(big)
        #expect(try store.read() == big)
        try store.write(Data("small".utf8))
        #expect(try store.read() == Data("small".utf8))
        try store.delete()
        #expect(try store.read() == nil)
    }
    #endif

    @Test func decodesDevToolsCookies() throws {
        let json = """
        {"cookies":[
          {"name":"SAPISID","value":"FAKE","domain":".youtube.com","path":"/","expires":4102444800,"secure":true,"httpOnly":false},
          {"name":"SID","value":"FAKE-SID","domain":".youtube.com","path":"/","expires":-1,"secure":false,"httpOnly":false},
          {"name":"YSC","value":"x","domain":".youtube.com","path":"/","expires":-1,"secure":true,"httpOnly":true,"sameSite":"None"}
        ]}
        """
        let cookies = try QTCookie.decodeCDP(Data(json.utf8))
        #expect(cookies.count == 3)
        #expect(cookies[0].expires == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(cookies[1].expires == nil)
        #expect(cookies[2].sameSite == "None")
        #expect(QTAuthSession(cookies: QTAuthSession.filtered(cookies)).isComplete)
        let bare = try QTCookie.decodeCDP(Data(#"[{"name":"SID","value":"v","domain":".google.com"}]"#.utf8))
        #expect(bare.first?.path == "/")
    }

    @Test func signInURLContinuesToYouTubeMusic() {
        let url = QTSignInWindowController.signInURL(hl: "zh-CN")
        #expect(url.host == "accounts.google.com")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "hl" }?.value == "zh-CN")
        #expect(items.first { $0.name == "continue" }?.value?.contains("music.youtube.com") == true)
    }
}
