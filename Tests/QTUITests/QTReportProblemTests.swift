import Foundation
import os
import QTAuth
import QTPlayback
import Testing
@testable import QTUI

/// Help › Report a Problem…: redaction, the report's content and order, the GitHub link (length cap, encoding,
/// the clipboard + file fallback), and account wording that never names anyone. No network.
@MainActor
@Suite struct QTReportProblemTests {
    // MARK: Redaction

    private let redactor = QTDiagnosticsRedactor(names: ["Tianrun Qiu", "@rodqiu", "Al"])

    @Test func cookiesAndAuthorizationHeadersAreRemoved() {
        let text = """
        Cookie: SAPISID=abcDEF123/xyz_456; __Secure-3PSID=g.a000secret
        set-cookie: LOGIN_INFO=AFmmF2swRQIhAPx
        jar SAPISID=AbCd1234/efGH5678-ij and __Secure-1PSIDTS=sidts-CjEBQT4rX and SID=g.a000xyz; HSID=Aq1w2e3r
        Authorization: SAPISIDHASH 1700000000_0123456789abcdef0123456789abcdef01234567
        header SAPISID1PHASH 1700000000_deadbeef sent
        """
        let out = redactor.redact(text)
        for secret in ["abcDEF123", "g.a000secret", "AFmmF2swRQIhAPx", "AbCd1234", "sidts-CjEBQT4rX", "g.a000xyz",
                       "Aq1w2e3r", "1700000000_", "deadbeef"] {
            #expect(!out.contains(secret), "\(secret) survived:\n\(out)")
        }
        #expect(out.contains("Cookie: <redacted>"))
        #expect(out.contains("Authorization: <redacted>"))
        #expect(out.contains("SAPISID=<redacted>"))
        #expect(out.contains("__Secure-1PSIDTS=<redacted>"))
        #expect(out.contains("SAPISIDHASH <redacted> sent"))
    }

    @Test func tokensKeysAndSignaturesAreRemoved() {
        let text = #"key=sample-key-0123 token=abc123 sig=AOq0QJ8wRgIhAJ api_key: zzz999 "access_token":"ya29.a0Af" password=hunter2 refresh_token=1//0gXYZ"#
        let out = redactor.redact(text)
        for secret in ["sample-key-0123", "abc123", "AOq0QJ8wRgIhAJ", "zzz999", "ya29.a0Af", "hunter2", "1//0gXYZ"] {
            #expect(!out.contains(secret), "\(secret) survived: \(out)")
        }
        #expect(out.contains("key=<redacted>"))
        #expect(out.contains("sig=<redacted>"))
        #expect(out.contains(#""access_token":"<redacted>"#))
    }

    @Test func longOpaqueBlobsGoButIDsPathsAndWordsStay() {
        let hex = "0123456789abcdef0123456789abcdef0123"           // 36 hex
        let base64 = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0NTY3ODkw" // 44, no slash
        let slashed = "AbCdEf0123456789/GhIjKl9876543210xyzQ=="
        let kept = [
            "dQw4w9WgXcQ",                                         // a video id
            "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf",                  // a playlist id (34)
            "OLAK5uy_kmLXSOxvUFJh6vNmb9HDQ2Kz4fFsXcEWQ",          // an album playlist id
            "QTNativePlaybackEngineCoordinatorLongName",          // a type name (letters only)
            "Tests/QTInnerTubeTests/Fixtures/browse_2024",        // a path made of words
        ]
        let out = redactor.redact(([hex, base64, slashed] + kept).joined(separator: " "))
        #expect(!out.contains(hex) && !out.contains(base64) && !out.contains("AbCdEf0123456789"))
        for value in kept { #expect(out.contains(value), "\(value) was removed: \(out)") }
    }

    @Test func emailsNamesHandlesAndIDsAreRemoved() {
        let text = """
        signed in as Tianrun Qiu (@rodqiu), mail someone.name+tag@example.co.uk; TIANRUN QIU again; rodqiu too
        Tianrun Qiuxyz stays (another word); Al stays (too short to hide)
        channel UCabcdefghijklmnopqrstuv brand 112233445566778899001 at 1700000000123 ms
        """
        let out = redactor.redact(text)
        #expect(!out.contains("Tianrun Qiu ") && !out.contains("TIANRUN") && !out.contains("@rodqiu") && !out.contains("rodqiu too"))
        #expect(out.contains("signed in as <account name> (<account name>)"))
        #expect(out.contains("mail <email>;"))
        #expect(out.contains("Tianrun Qiuxyz stays"))
        #expect(out.contains("Al stays"))
        #expect(out.contains("channel <channel id> brand <id>"))
        #expect(out.contains("1700000000123 ms"), "a millisecond timestamp isn't an id")
    }

    @Test func homePathsLoseTheUserName() {
        let out = redactor.redact("failed: /Users/alice/Library/Caches/com.roderickqiu.qtube/x.db and /Users/Shared/QTube and \"/Users/bob\"")
        #expect(out == "failed: ~/Library/Caches/com.roderickqiu.qtube/x.db and /Users/Shared/QTube and \"~\"")
    }

    @Test func urlQueriesKeepOnlyVideoAndList() {
        let out = redactor.redact("""
        open https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxyz&si=abc123&t=42#frag now
        post https://music.youtube.com/youtubei/v1/player?key=AIzaFAKE&prettyPrint=false.
        ws wss://example.com/socket?auth=1 and http://example.com/plain, done
        """)
        #expect(out.contains("open https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=PLxyz now"))
        #expect(out.contains("post https://music.youtube.com/youtubei/v1/player."))
        #expect(out.contains("ws wss://example.com/socket and http://example.com/plain, done"))
        #expect(!out.contains("AIzaFAKE") && !out.contains("si=") && !out.contains("#frag"))
    }

    @Test func redactionIsIdempotentAndLeavesCleanDiagnosticsAlone() {
        let raw = sample().rendered(redactor: QTDiagnosticsRedactor(), timeZone: utc).markdown
        // The sample has nothing to hide: every field reads as written.
        for line in ["- Version: 0.1.0 (42, 1a2b3c4d5e)", "- Bundle: com.roderickqiu.qtube", "- Model: Mac16,1 · arm64",
                     "- Language: en (setting auto; system en-HK, zh-Hans-HK)",
                     "- Engine: web — YouTube's player; native engine off",
                     "- Now playing: “Ngày Xưa” (dQw4w9WgXcQ)", "- Global shortcuts: 2", "- Unofficial lyrics: NetEase, QQ"] {
            #expect(raw.contains(line), "missing \(line)")
        }
        let once = redactor.redact(raw + "\nCookie: SID=x\n/Users/alice/a token=1")
        #expect(redactor.redact(once) == once)
    }

    // MARK: Report content and order

    @Test func reportPutsTheDescriptionFirstThenSectionsThenTheLog() throws {
        let rendered = sample().rendered(redactor: redactor, timeZone: utc)
        let report = QTProblemReport(description: "  Lyrics froze after Song⇄Video\nThen nothing.  ", diagnostics: rendered)
        let md = report.markdown
        #expect(md.hasPrefix("### What happened\n\nLyrics froze after Song⇄Video\nThen nothing.\n\n### Diagnostics\n"))
        let order = ["### What happened", "### Diagnostics", "**App**", "**Mac**", "**Account**", "**Playback**", "**Settings**", "**Log**"]
        let positions = try order.map { try #require(md.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
        // Log lines: `HH:mm:ss.SSS [category] message`, errors marked, oldest first, redacted.
        #expect(md.contains("09:15:02.250 [playback] network unavailable\n09:20:07.750 [lyrics] error: cache failed at ~/Library/x.db"))
        #expect(md.contains("**Log** (this run, last 30 min, notices and errors: 2 lines)"))
        #expect(md.contains("- Account: signed in, Premium\n- Brand account: yes"))
        #expect(report.title == "Lyrics froze after Song⇄Video")
    }

    @Test func reportWithoutDiagnosticsOrDescription() {
        let report = QTProblemReport(description: " \n ", diagnostics: nil)
        #expect(report.markdown == "### What happened\n\n_No description._\n")
        #expect(report.title == QTProblemReport.defaultTitle)
        let long = QTProblemReport(description: "\n\n" + String(repeating: "word ", count: 40), diagnostics: nil)
        #expect(long.title.count == 80 && long.title.hasSuffix("…"))
        var empty = sample()
        empty.logLines = []
        #expect(empty.rendered(redactor: redactor).markdown.contains("```\n(nothing logged)\n```"))
    }

    // MARK: The GitHub link

    @Test func shortReportsGoWholeIntoTheLink() throws {
        let rendered = sample().rendered(redactor: redactor, timeZone: utc)
        let text = "Crash + freeze & more #2 = bad?\n中文 🎵 100% sure"
        let report = QTProblemReport(description: text, diagnostics: rendered)
        let link = QTIssueLink(report: report)
        #expect(!link.needsAttachment)
        #expect(link.url.absoluteString.hasPrefix("https://github.com/RoderickQiu/qtube-music/issues/new?title="))
        #expect(link.url.absoluteString.count <= QTIssueLink.maxLength)
        let items = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == ["title", "labels", "body"])
        #expect(items[0].value == "Crash + freeze & more #2 = bad?")
        #expect(items[1].value == "bug")
        #expect(items[2].value == report.markdown)
    }

    @Test func encodingKeepsOnlyUnreservedCharacters() {
        #expect(QTIssueLink.encode("a+b&c=d#e f\n~x.y_z-1") == "a%2Bb%26c%3Dd%23e%20f%0A~x.y_z-1")
        #expect(QTIssueLink.encode("歌") == "%E6%AD%8C")
    }

    @Test func longReportsFallBackToSummaryClipboardAndFile() throws {
        var d = sample()
        d.logLines = (0..<300).map { i in
            QTDiagnosticLogLine(date: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)), category: "playback",
                                message: "line \(i): the page didn't take play; reloading the item and trying again")
        }
        let rendered = d.rendered(redactor: redactor, timeZone: utc)
        let report = QTProblemReport(description: "Songs skip on their own", diagnostics: rendered)
        let link = QTIssueLink(report: report)
        #expect(link.needsAttachment)
        #expect(link.url.absoluteString.count <= QTIssueLink.maxLength)
        let body = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value)
        #expect(body.contains("Songs skip on their own"))
        #expect(body.contains(rendered.summary))
        #expect(body.contains(QTIssueLink.clipboardNote))
        #expect(!body.contains("line 299"), "the log stays out of the link")
        #expect(rendered.summary == "QTube Music 0.1.0 (42, 1a2b3c4d5e) · debug · macOS 26.1 (25B78) · Mac16,1 arm64 · web engine · signed in, Premium")
    }

    @Test func aDescriptionTooLongForAnyLinkIsCut() throws {
        let text = String(repeating: "歌词卡住了。", count: 2000)
        for diagnostics in [sample().rendered(redactor: redactor), nil] {
            let link = QTIssueLink(report: QTProblemReport(description: text, diagnostics: diagnostics))
            #expect(link.needsAttachment)
            #expect(link.url.absoluteString.count <= QTIssueLink.maxLength)
            #expect(link.url.absoluteString.count > QTIssueLink.maxLength - 200, "as much as fits")
            let body = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value)
            #expect(body.hasPrefix("### What happened\n\n歌词卡住了。"))
            #expect(body.contains("…\n") && body.contains(QTIssueLink.clipboardNote))
        }
    }

    @Test func attachmentIsNamedByDateAndOldOnesAreCleared() throws {
        let date = Date(timeIntervalSince1970: 1_792_591_532) // 2026-10-21 14:05:32 UTC
        #expect(QTReportProblem.attachmentName(at: date, timeZone: utc) == "QTube Music Report 2026-10-21 at 14.05.32.txt")
        let folder = FileManager.default.temporaryDirectory.appending(path: "qt-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = folder.appending(path: "old.txt")
        try Data("x".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: stale.path)
        let url = try QTReportProblem.saveAttachment("report", in: folder, at: date)
        #expect(try String(contentsOf: url, encoding: .utf8) == "report")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    /// This process's own log: notices and errors from our subsystem, not info lines, not other subsystems.
    @Test func readsNoticesAndErrorsFromThisProcess() async throws {
        let marker = UUID().uuidString.prefix(8)
        let ours = Logger(subsystem: "com.roderickqiu.qtube", category: "report-test")
        ours.info("info \(marker, privacy: .public)")
        ours.notice("notice \(marker, privacy: .public)")
        ours.error("error \(marker, privacy: .public)")
        Logger(subsystem: "com.example.other", category: "report-test").error("other \(marker, privacy: .public)")
        var lines: [QTDiagnosticLogLine] = []
        for _ in 0..<20 {
            lines = QTProblemDiagnosticsCollector.recentLog(minutes: 5, subsystems: ["com.roderickqiu.qtube"])
                .filter { $0.message.hasSuffix(marker) }
            if lines.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(lines.map(\.message) == ["notice \(marker)", "error \(marker)"])
        #expect(lines.map(\.level) == [.notice, .error])
        #expect(lines.first?.category == "report-test")
    }

    // MARK: Account and engine wording

    @Test func accountKindNeverNamesTheAccount() {
        typealias C = QTProblemDiagnosticsCollector
        let named = QTAuthState.signedIn(accountName: "Tianrun Qiu", isPremium: true)
        #expect(C.account(mode: .mock, state: named, accountIsPremium: true) == .demo)
        #expect(C.account(mode: .restoring, state: .signedOut, accountIsPremium: nil) == .restoring)
        #expect(C.account(mode: .guest, state: .signedOut, accountIsPremium: nil) == .guest)
        #expect(C.account(mode: .live, state: .signingIn, accountIsPremium: nil) == .signingIn)
        #expect(C.account(mode: .guest, state: .sessionExpired, accountIsPremium: nil) == .sessionExpired)
        #expect(C.account(mode: .live, state: named, accountIsPremium: nil) == .signedIn(premium: true))
        #expect(C.account(mode: .live, state: .signedIn(accountName: "x", isPremium: false), accountIsPremium: true) == .signedIn(premium: true))
        #expect(C.account(mode: .live, state: .signedIn(accountName: "x", isPremium: false), accountIsPremium: nil) == .signedIn(premium: false))
        let wording: [QTProblemDiagnostics.Account: String] = [
            .demo: "demo library", .restoring: "restoring session", .guest: "guest (signed out)", .signingIn: "signing in",
            .signedIn(premium: true): "signed in, Premium", .signedIn(premium: false): "signed in, free",
            .signedIn(premium: nil): "signed in, tier unknown", .sessionExpired: "session expired",
        ]
        for (account, text) in wording { #expect(account.summary == text) }
        // The diagnostics have no field for a name: a signed-in report shows the kind only.
        var d = sample()
        d.account = C.account(mode: .live, state: named, accountIsPremium: nil)
        let md = d.rendered(redactor: QTDiagnosticsRedactor()).markdown
        #expect(md.contains("- Account: signed in, Premium") && !md.contains("Tianrun"))
    }

    @Test func engineReasons() {
        typealias C = QTProblemDiagnosticsCollector
        func describe(_ kind: QTPlaybackEngineKind, source: QTPlaybackDataSource = .live, anonymous: Bool = false,
                      optIn: Bool = false, eligible: Bool = false, signedIn: Bool = true, fallback: String? = nil,
                      active: Bool = true) -> String {
            let (engine, reason) = C.engineDescription(kind: kind, source: source, isAnonymous: anonymous, nativeOptIn: optIn,
                                                       nativeEligible: eligible, signedIn: signedIn, fallbackReason: fallback,
                                                       nativeActive: active)
            return "\(engine): \(reason)"
        }
        #expect(describe(.simulated, source: .mock) == "simulated: demo library")
        #expect(describe(.web) == "web: YouTube's player; native engine off")
        #expect(describe(.web, optIn: true) == "web: YouTube's player; native engine needs Premium")
        #expect(describe(.web, optIn: true, signedIn: false) == "web: YouTube's player; native engine needs a signed-in Premium account")
        #expect(describe(.web, anonymous: true) == "web: YouTube's player, anonymous")
        #expect(describe(.native, optIn: true, eligible: true) == "native: Premium, opted in")
        #expect(describe(.native, optIn: true, eligible: true, fallback: "solver failed") == "native: fell back to YouTube's player for this session: solver failed")
    }

    @Test func statusAndVersionLinesReadPlainly() {
        typealias C = QTProblemDiagnosticsCollector
        #expect(C.statusLine(QTPlaybackState(status: .failed(.botCheck))) == "failed(botCheck)")
        #expect(C.statusLine(QTPlaybackState(status: .loading, isBuffering: true)) == "loading, buffering")
        #expect(C.plain("failed(QTPlayback.QTPlaybackError.network(\"timed out\"))") == "failed(network(\"timed out\"))")
        #expect(C.macOSVersion("Version 26.1 (Build 25B78)") == "26.1 (25B78)")
        #expect(C.sysctlString("hw.model")?.hasPrefix("Mac") == true)
    }

    // MARK: Fixtures

    private var utc: TimeZone { TimeZone(identifier: "UTC")! }

    private func sample() -> QTProblemDiagnostics {
        var d = QTProblemDiagnostics()
        d.appVersion = "0.1.0"
        d.buildNumber = "42"
        d.commit = "1a2b3c4d5e"
        d.configuration = "debug"
        d.bundleID = "com.roderickqiu.qtube"
        d.macOSVersion = "26.1 (25B78)"
        d.macModel = "Mac16,1"
        d.architecture = "arm64"
        d.language = "en (setting auto; system en-HK, zh-Hans-HK)"
        d.region = "HK"
        d.appearance = "dark (setting auto)"
        d.account = .signedIn(premium: true)
        d.isBrandAccount = true
        d.engine = "web"
        d.engineReason = "YouTube's player; native engine off"
        d.status = "playing"
        d.wantsPlayback = true
        d.nowPlaying = "“Ngày Xưa” (dQw4w9WgXcQ)"
        d.lastNotice = "interrupted"
        d.lastToast = "“Playback was interrupted” at 09:19:58"
        d.unofficialLyrics = "NetEase, QQ"
        d.translation = "auto → zh-Hans"
        d.globalShortcuts = 2
        d.lastFMConnected = true
        d.logLines = [
            QTDiagnosticLogLine(date: Date(timeIntervalSince1970: 1_792_574_102.25), category: "playback", message: "network unavailable"),
            QTDiagnosticLogLine(date: Date(timeIntervalSince1970: 1_792_574_407.75), category: "lyrics", level: .error,
                                message: "cache failed at /Users/alice/Library/x.db"),
        ]
        return d
    }
}
