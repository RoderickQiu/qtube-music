import Foundation

// Owner: builder "desktop". Help › Report a Problem… — the parts that need no app state: the diagnostics snapshot
// and how it reads, the redaction every machine-written line goes through, the report (Markdown) and the prefilled
// GitHub issue link. QTReportProblemView gathers the snapshot and shows it; nothing here touches the network, and
// the app never sends a report by itself (the browser does, after the user has read it).
//
// The diagnostics are written in English whatever the interface language: they are for the maintainer, and a
// report reads the same from every Mac. The user's own description is passed through as typed.

/// One line of the app's own log (`OSLogStore`, this process, our subsystem).
public struct QTDiagnosticLogLine: Sendable, Hashable {
    public enum Level: String, Sendable, Hashable {
        case notice, error, fault
    }

    public var date: Date
    public var category: String
    public var level: Level
    public var message: String

    public init(date: Date, category: String, level: Level = .notice, message: String) {
        self.date = date
        self.category = category
        self.level = level
        self.message = message
    }

    /// `HH:mm:ss.SSS [category] message`; errors and faults say so before the message.
    public func formatted(timeZone: TimeZone = .current) -> String {
        let tag = level == .notice ? "" : "\(level.rawValue): "
        return "\(QTProblemReport.clock(date, timeZone: timeZone)) [\(category)] \(tag)\(message)"
    }
}

/// What the report says about the app, the Mac, the account (kind only), settings and playback. Plain values;
/// `QTReportProblemView` fills it from the running app (`QTProblemDiagnosticsCollector`).
public struct QTProblemDiagnostics: Sendable, Hashable {
    /// The account as far as a report needs it: never a name, handle, email or id.
    public enum Account: Sendable, Hashable {
        /// The demo library (DEBUG builds).
        case demo
        /// Reading the saved session at launch.
        case restoring
        case guest
        case signingIn
        case signedIn(premium: Bool?)
        case sessionExpired

        public var summary: String {
            switch self {
            case .demo: "demo library"
            case .restoring: "restoring session"
            case .guest: "guest (signed out)"
            case .signingIn: "signing in"
            case .signedIn(let premium?): premium ? "signed in, Premium" : "signed in, free"
            case .signedIn(nil): "signed in, tier unknown"
            case .sessionExpired: "session expired"
            }
        }
    }

    // App
    public var appVersion = "?"
    public var buildNumber = "?"
    public var commit: String?
    public var configuration = "release"
    public var bundleID = "?"
    // Mac
    public var macOSVersion = "?"
    public var macModel = "?"
    public var architecture = "?"
    public var language = "?"
    public var region = "?"
    public var appearance = "?"
    // Account
    public var account: Account = .guest
    public var isBrandAccount = false
    // Playback
    public var engine = "?"
    public var engineReason = ""
    public var status = "idle"
    public var wantsPlayback = false
    public var mode = "song"
    public var isNetworkAvailable = true
    public var nowPlaying: String?
    public var lastNotice: String?
    public var lastToast: String?
    // Settings
    public var syncsToYouTubeMusic = true
    public var unofficialLyrics = "off"
    public var translation = "?"
    public var nativeEngineOptIn = false
    public var globalShortcuts = 0
    public var lastFMConnected = false
    public var listenBrainzConnected = false
    public var discordOn = false
    // Log
    public var logLines: [QTDiagnosticLogLine] = []
    public var logMinutes = 30

    public init() {}

    /// `0.1.0 (42, 1a2b3c4d5e)`.
    public var versionLine: String {
        let build = [buildNumber, commit].compactMap { $0 }.joined(separator: ", ")
        return "\(appVersion) (\(build))"
    }

    /// The report's sections, in order: App, Mac, Account, Playback, Settings.
    public var sections: [(title: String, fields: [(String, String)])] {
        func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        var playback: [(String, String)] = [
            ("Engine", engineReason.isEmpty ? engine : "\(engine) — \(engineReason)"),
            ("Status", status),
            ("Wants playback", yesNo(wantsPlayback)),
            ("Mode", mode),
            ("Network", isNetworkAvailable ? "available" : "unavailable"),
        ]
        if let nowPlaying { playback.append(("Now playing", nowPlaying)) }
        playback.append(("Last notice", lastNotice ?? "none"))
        playback.append(("Last toast", lastToast ?? "none"))
        return [
            ("App", [
                ("Version", versionLine),
                ("Build", configuration),
                ("Bundle", bundleID),
            ]),
            ("Mac", [
                ("macOS", macOSVersion),
                ("Model", "\(macModel) · \(architecture)"),
                ("Language", language),
                ("Region", region),
                ("Appearance", appearance),
            ]),
            ("Account", [
                ("Account", account.summary),
                ("Brand account", yesNo(isBrandAccount)),
            ]),
            ("Playback", playback),
            ("Settings", [
                ("Sync likes and playlists", onOff(syncsToYouTubeMusic)),
                ("Unofficial lyrics", unofficialLyrics),
                ("Lyrics translation", translation),
                ("Native engine (opt-in)", onOff(nativeEngineOptIn)),
                ("Global shortcuts", "\(globalShortcuts)"),
                ("Last.fm", lastFMConnected ? "connected" : "not connected"),
                ("ListenBrainz", listenBrainzConnected ? "connected" : "not connected"),
                ("Discord", onOff(discordOn)),
            ]),
        ]
    }

    /// One line for the issue link when the full report doesn't fit:
    /// `QTube Music 0.1.0 (42, 1a2b3c) · release · macOS 26.1 (25B78) · Mac16,1 arm64 · web engine · signed in, Premium`.
    public var summary: String {
        ["QTube Music \(versionLine)", configuration, "macOS \(macOSVersion)", "\(macModel) \(architecture)",
         "\(engine) engine", account.summary].joined(separator: " · ")
    }
}

/// The diagnostics as they are shared: redacted once, then reused while the user types.
public struct QTRenderedDiagnostics: Sendable, Hashable {
    /// The Markdown block Show Diagnostics displays and the report carries.
    public var markdown: String
    /// One line for an issue link that can't carry the whole block.
    public var summary: String

    public init(markdown: String, summary: String) {
        self.markdown = markdown
        self.summary = summary
    }
}

extension QTProblemDiagnostics {
    /// Renders and redacts: the sections in order, then the log in a code block.
    public func rendered(redactor: QTDiagnosticsRedactor, timeZone: TimeZone = .current) -> QTRenderedDiagnostics {
        var lines = ["### Diagnostics", ""]
        for section in sections {
            lines.append("**\(section.title)**")
            lines += section.fields.map { "- \($0.0): \($0.1)" }
            lines.append("")
        }
        let log = logLines.map { $0.formatted(timeZone: timeZone) }
        lines.append("**Log** (this run, last \(logMinutes) min, notices and errors: \(log.count) line\(log.count == 1 ? "" : "s"))")
        lines.append("")
        lines.append("```")
        lines += log.isEmpty ? ["(nothing logged)"] : log
        lines.append("```")
        return QTRenderedDiagnostics(markdown: redactor.redact(lines.joined(separator: "\n")), summary: redactor.redact(summary))
    }
}

/// The report: the user's description, then the diagnostics. Markdown, so a pasted report reads well on GitHub;
/// its diagnostics part is exactly what Show Diagnostics displays.
public struct QTProblemReport: Sendable, Hashable {
    /// What the user typed, passed through as is (they wrote it and see it).
    public var description: String
    /// nil when Include diagnostics is off.
    public var diagnostics: QTRenderedDiagnostics?

    public init(description: String, diagnostics: QTRenderedDiagnostics?) {
        self.description = description
        self.diagnostics = diagnostics
    }

    public static let defaultTitle = "Problem report"

    /// The description's first line (trimmed, at most 80 characters), else "Problem report".
    public var title: String {
        let first = description.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let first else { return Self.defaultTitle }
        return first.count > 80 ? String(first.prefix(79)) + "…" : first
    }

    var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole report: what happened, then the diagnostics.
    public var markdown: String {
        var parts = ["### What happened", "", trimmedDescription.isEmpty ? "_No description._" : trimmedDescription]
        if let diagnostics { parts += ["", diagnostics.markdown] }
        return parts.joined(separator: "\n") + "\n"
    }

    /// The issue body when the full report is too long for a link: the description, the one-line summary and where
    /// the rest is.
    public var compactMarkdown: String { compactMarkdown(description: trimmedDescription) }

    func compactMarkdown(description: String) -> String {
        var parts = ["### What happened", "", description.isEmpty ? "_No description._" : description]
        if let diagnostics { parts += ["", "### Diagnostics", "", diagnostics.summary] }
        parts += ["", QTIssueLink.clipboardNote]
        return parts.joined(separator: "\n") + "\n"
    }

    /// `14:03:07.250` in `timeZone`.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let ms = min(999, (c.nanosecond ?? 0) / 1_000_000)
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }
}

// MARK: - The GitHub issue link

/// A prefilled "New issue" link. GitHub (and some browsers) refuse very long URLs, so a link stays under
/// `maxLength`; when the full report doesn't fit, the link carries the description and the summary, and the full
/// report goes to the clipboard and a file (`needsAttachment`).
public struct QTIssueLink: Sendable, Hashable {
    public static let newIssue = "https://github.com/RoderickQiu/qtube-music/issues/new"
    public static let maxLength = 7500
    public static let clipboardNote = "Full diagnostics are on your clipboard — paste them below (or drag the attached .txt file in)."

    public var url: URL
    /// The link holds the compact body: copy the full report and save it as a file before opening it.
    public var needsAttachment: Bool

    public init(report: QTProblemReport, maxLength: Int = QTIssueLink.maxLength) {
        let title = report.title
        let full = Self.url(title: title, body: report.markdown)
        needsAttachment = full.absoluteString.count > maxLength
        guard needsAttachment else {
            url = full
            return
        }
        let description = report.trimmedDescription
        let compact = Self.url(title: title, body: report.compactMarkdown(description: description))
        if compact.absoluteString.count <= maxLength {
            url = compact
            return
        }
        // A description longer than a link can carry: the longest start of it that fits (the attachment has it all).
        var best = Self.url(title: title, body: report.compactMarkdown(description: "…"))
        var lo = 0, hi = description.count
        while lo <= hi {
            let keep = (lo + hi) / 2
            let candidate = Self.url(title: title, body: report.compactMarkdown(description: description.prefix(keep) + "…"))
            if candidate.absoluteString.count <= maxLength {
                best = candidate
                lo = keep + 1
            } else {
                hi = keep - 1
            }
        }
        url = best
    }

    /// `…/issues/new?title=…&labels=bug&body=…`, every value percent-encoded (only RFC 3986's unreserved
    /// characters stay as they are, so `+`, `&`, `#` and newlines survive the trip).
    public static func url(title: String, body: String) -> URL {
        let query = [("title", title), ("labels", "bug"), ("body", body)]
            .map { "\($0.0)=\(encode($0.1))" }
            .joined(separator: "&")
        return URL(string: "\(newIssue)?\(query)")!
    }

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

// MARK: - Redaction

/// Removes what a report must never carry: cookies, tokens and keys, Authorization headers, long opaque blobs,
/// email addresses, the signed-in account's names and handles, channel and account ids, the Mac's user name in
/// paths, and URL query strings (except `v=` and `list=`, which name a video or playlist). Video ids and track
/// titles stay: they are what makes a report actionable, and Show Diagnostics lets the user read everything first.
public struct QTDiagnosticsRedactor: Sendable, Hashable {
    /// Account display names and handles to hide (the signed-in account and its brand accounts).
    public var names: [String]

    public init(names: [String] = []) {
        // Short names would hide ordinary words; handles count with and without their @.
        var all: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            all.append(trimmed)
            if trimmed.hasPrefix("@"), trimmed.count >= 4 { all.append(String(trimmed.dropFirst())) }
        }
        self.names = Array(Set(all)).sorted { $0.count > $1.count }
    }

    public static let placeholder = "<redacted>"

    public func redact(_ text: String) -> String {
        var s = text
        s = Self.replaceURLs(in: s)
        // Paths: /Users/<name>/… → ~/… (any account on the Mac; /Users/Shared is no one's name).
        s = Self.replace(Self.userPath, in: s) { m, ns in
            ns.substring(with: m.range(at: 1)) == "Shared" ? ns.substring(with: m.range) : "~"
        }
        s = Self.replace(Self.headerLine, in: s, with: "$1: \(Self.placeholder)")
        s = Self.replace(Self.cookie, in: s, with: "$1=\(Self.placeholder)")
        s = Self.replace(Self.sapisidHash, in: s, with: "SAPISIDHASH \(Self.placeholder)")
        s = Self.replace(Self.secretPair, in: s, with: "$1$2\(Self.placeholder)")
        s = Self.replace(Self.email, in: s, with: "<email>")
        for name in names {
            let pattern = NSRegularExpression.escapedPattern(for: name)
            guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(pattern)(?![\\p{L}\\p{N}])",
                                                    options: [.caseInsensitive]) else { continue }
            s = Self.replace(re, in: s, with: "<account name>")
        }
        s = Self.replace(Self.channelID, in: s, with: "<channel id>")
        s = Self.replace(Self.longNumber, in: s, with: "<id>")
        s = Self.replace(Self.blob, in: s) { m, ns in
            let run = ns.substring(with: m.range)
            return Self.isOpaque(run) ? Self.placeholder : run
        }
        return s
    }

    // MARK: Patterns

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let url = re("(?i)\\b(?:https?|wss?)://[^\\s\"'<>`)\\]]+")
    static let userPath = re("/Users/([^/\\s\"'`:]+)")
    /// `Authorization: …`, `Cookie: …`, `Set-Cookie: …` up to the end of the line.
    static let headerLine = re("(?im)\\b(authorization|proxy-authorization|cookie|set-cookie|x-goog-visitor-id)\\s*:\\s*[^\\n]+")
    /// Google and YouTube session cookies by name.
    static let cookie = re("(?i)\\b(__Secure-[A-Za-z0-9_-]+|__Host-[A-Za-z0-9_-]+|SAPISID|APISID|HSID|SSID|SIDCC|SID|LSID|LOGIN_INFO|VISITOR_INFO1_LIVE|VISITOR_PRIVACY_METADATA|YSC|PREF|NID|OSID)\\s*=\\s*[^;\\s,&\"']+")
    static let sapisidHash = re("(?i)\\bSAPISID(?:1P|3P)?HASH\\s+[^\\s,;\"']+")
    /// `key=…`, `token: …`, `"api_key":"…"`, `sig=…`, `password=…`, `access_token=…` and the like.
    static let secretPair = re("(?i)\\b([A-Za-z0-9_.-]*(?:key|token|sig|signature|secret|password|passwd|auth|sessionid|session_id|credential)[A-Za-z0-9_-]*)(\"?\\s*[=:]\\s*\"?)(?!<)[^\\s&;,\"'}\\])]+")
    static let email = re("(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}")
    /// YouTube channel ids (`UC` + 22).
    static let channelID = re("\\bUC[A-Za-z0-9_-]{22}\\b")
    /// Google account and brand-account ids (21 digits) and other long numbers that identify someone.
    static let longNumber = re("(?<![\\d.])\\d{16,}(?![\\d.])")
    static let blob = re("[A-Za-z0-9+/_-]{33,}={0,2}")

    /// Long runs that look like keys, hashes or base64; not playlist / browse ids (`list=` stays useful) and not
    /// paths made of words.
    static func isOpaque(_ run: String) -> Bool {
        let core = run.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let playlistPrefixes = ["PL", "RD", "OLAK5uy_", "VL", "MPRE", "FE", "LM", "OL", "UU", "UC", "MLCT"]
        if playlistPrefixes.contains(where: { core.hasPrefix($0) }), !core.contains("/") { return false }
        let hasDigit = core.contains { $0.isASCII && $0.isNumber }
        let hasLetter = core.contains { $0.isASCII && $0.isLetter }
        // All letters is a word or a type name (all digits were taken as an id already).
        guard hasDigit, hasLetter else { return false }
        guard core.contains("/") else { return true }
        // A path ("Tests/QTInnerTubeTests/Fixtures/browse_2024") is words between slashes; base64 has long segments
        // that mix digits with upper- and lowercase letters.
        return core.split(separator: "/").contains { segment in
            segment.count >= 24 || (segment.count >= 10 && segment.contains(where: \.isNumber)
                                     && segment.contains(where: \.isUppercase) && segment.contains(where: \.isLowercase))
        }
    }

    /// Strips a URL's query except `v=` / `list=`, and its fragment.
    static func replaceURLs(in text: String) -> String {
        replace(url, in: text) { m, ns in
            let raw = ns.substring(with: m.range)
            // Trailing punctuation is the sentence's, not the URL's.
            var trailing = ""
            var core = Substring(raw)
            while let last = core.last, ".,;:!?".contains(last) { trailing = String(last) + trailing; core = core.dropLast() }
            let base = core.firstIndex(of: "#").map { String(core[..<$0]) } ?? String(core)
            guard let q = base.firstIndex(of: "?") else { return base + trailing }
            let kept = base[base.index(after: q)...].split(separator: "&").filter {
                let key = $0.split(separator: "=", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                return key == "v" || key == "list"
            }
            let path = String(base[..<q])
            return (kept.isEmpty ? path : path + "?" + kept.joined(separator: "&")) + trailing
        }
    }

    static func replace(_ re: NSRegularExpression, in text: String, with template: String) -> String {
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    static func replace(_ re: NSRegularExpression, in text: String,
                        _ transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(m, ns)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
