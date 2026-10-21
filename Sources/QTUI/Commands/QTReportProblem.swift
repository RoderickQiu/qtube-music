import AppKit
import OSLog
import QTAuth
import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "desktop". Help › Report a Problem…: a window where the user describes what went wrong, reads the
// diagnostics that would go with it (Show Diagnostics shows the exact text), and either copies the report or opens
// a prefilled GitHub issue in the browser. The app never sends anything itself. The report's text, redaction and
// link live in QTProblemReport.swift; this file gathers the diagnostics from the running app and shows the window.
//
// Launch arguments (DEBUG, screenshots): `-qt.show reportProblem` opens the window once the app is up;
// `-qt.report.text <text>` fills the description, `-qt.report.expanded YES` opens Show Diagnostics,
// `-qt.report.sampleLog YES` adds sample log lines (with a path, a key and a URL query to show the redaction).

@MainActor
public enum QTReportProblem {
    public enum LaunchKey {
        public static let text = "qt.report.text"
        public static let expanded = "qt.report.expanded"
        public static let sampleLog = "qt.report.sampleLog"
    }

    /// Opens the window (or brings it forward) from outside a scene — a toast's action.
    public static func open() {
        QTDesktopCoordinator.shared.openWindow(id: QTReportProblemView.sceneID)
    }

    /// Copy Report: the whole report as Markdown.
    static func copy(_ report: QTProblemReport, model: QTAppModel) {
        putOnPasteboard(report.markdown)
        model.showToast(QTLoc.tr("Report copied", table: .desktop))
    }

    /// Open GitHub Issue…: the browser gets the prefilled link. A report too long for a link is also copied and saved
    /// as a .txt shown in Finder, and the link's body says so.
    static func openIssue(_ report: QTProblemReport, model: QTAppModel) {
        let link = QTIssueLink(report: report)
        if link.needsAttachment {
            putOnPasteboard(report.markdown)
            if let file = try? saveAttachment(report.markdown) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            model.showToast(QTLoc.tr("Full report copied — paste it into the issue", table: .desktop))
        }
        NSWorkspace.shared.open(link.url)
    }

    private static func putOnPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: The attachment

    /// `~/Library/Caches/<bundle id>/Reports`: out of the way, and the system may clear it.
    static var reportsFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appending(path: Bundle.main.bundleIdentifier ?? "com.roderickqiu.qtube").appending(path: "Reports")
    }

    /// `QTube Music Report 2026-10-21 at 14.05.32.txt` (no colons: Finder shows them as slashes).
    static func attachmentName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "QTube Music Report \(formatter.string(from: date)).txt"
    }

    /// Writes the report and clears reports older than a week.
    static func saveAttachment(_ text: String, in folder: URL = reportsFolder, at date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in old {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, date.timeIntervalSince(modified) > 7 * 24 * 3600 { try? fm.removeItem(at: file) }
        }
        let url = folder.appending(path: attachmentName(at: date))
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: Launch (DEBUG)

    /// `-qt.show reportProblem`: the window over the main one, centred on the test display; the ready file waits
    /// for it (and for its diagnostics, `QTReportProblemView`).
    static func applyLaunch(_ launch: QTLaunchOptions) {
        #if DEBUG
        guard launch.extraWindows.contains(.reportProblem) else { return }
        let hold = QTReadiness.shared.hold("report a problem")
        Task { @MainActor in
            for _ in 0..<50 {
                if QTDesktopCoordinator.shared.openWindow(id: QTReportProblemView.sceneID) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(300))
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(QTReportProblemView.sceneID) == true }) {
                QTWindowPlacement.center(window, screenName: launch.effectiveScreenName)
            }
            QTReadiness.shared.release(hold)
        }
        #endif
    }
}

// MARK: - Gathering the diagnostics

@MainActor
enum QTProblemDiagnosticsCollector {
    nonisolated static let logMinutes = 30
    nonisolated static let logLimit = 300

    /// The diagnostics with this session's log, redacted. The log is read off the main thread.
    static func collect(model: QTAppModel) async -> QTRenderedDiagnostics {
        let snapshot = snapshot(model: model)
        let redactor = redactor()
        let subsystems = subsystems
        var sample = false
        #if DEBUG
        sample = model.launch.bool(QTReportProblem.LaunchKey.sampleLog) == true
        #endif
        return await Task.detached(priority: .userInitiated) { [sample] in
            var diagnostics = snapshot
            var lines = recentLog(minutes: snapshot.logMinutes, subsystems: subsystems)
            #if DEBUG
            if sample { lines = (lines + sampleLog(now: Date())).sorted { $0.date < $1.date } }
            #endif
            diagnostics.logLines = Array(lines.suffix(logLimit))
            return diagnostics.rendered(redactor: redactor)
        }.value
    }

    /// Our log subsystem, and the bundle id for variants (`com.roderickqiu.qtube.dev-<name>`) that log under it.
    static var subsystems: [String] {
        Array(Set(["com.roderickqiu.qtube", Bundle.main.bundleIdentifier].compactMap { $0 })).sorted()
    }

    /// Names to hide: the signed-in account and its brand accounts (names and handles), the Mac user's names.
    static func redactor() -> QTDiagnosticsRedactor {
        let store = QTLiveCatalogStore.shared
        var names = [NSFullUserName(), NSUserName()]
        if let account = store.auth.account { names += [account.name, account.handle].compactMap { $0 } }
        if case .signedIn(let name, _) = store.auth.state { names.append(name) }
        for identity in store.identities { names += [identity.name, identity.handle].compactMap { $0 } }
        return QTDiagnosticsRedactor(names: names)
    }

    static func snapshot(model: QTAppModel) -> QTProblemDiagnostics {
        var d = QTProblemDiagnostics()
        let info = Bundle.main.infoDictionary ?? [:]
        d.appVersion = info["CFBundleShortVersionString"] as? String ?? "dev"
        d.buildNumber = info["CFBundleVersion"] as? String ?? "?"
        d.commit = info["QTGitCommit"] as? String
        #if DEBUG
        d.configuration = "debug"
        #else
        d.configuration = "release"
        #endif
        d.bundleID = Bundle.main.bundleIdentifier ?? "?"

        d.macOSVersion = macOSVersion(ProcessInfo.processInfo.operatingSystemVersionString)
        d.macModel = sysctlString("hw.model") ?? "?"
        d.architecture = architecture
        let settings = model.settings.settings
        let system = Locale.preferredLanguages.prefix(2).joined(separator: ", ")
        d.language = "\(QTLoc.language.rawValue) (setting \(settings.interfaceLanguage.rawValue); system \(system))"
        d.region = Locale.current.region?.identifier ?? "?"
        d.appearance = appearance(theme: settings.theme)

        let store = QTLiveCatalogStore.shared
        d.account = account(mode: store.mode, state: store.auth.state, accountIsPremium: store.auth.account?.isPremium)
        d.isBrandAccount = store.auth.brandAccountId != nil

        let player = model.player
        let engine = player.engine
        let native = engine as? QTNativePlaybackEngine
        let setup = QTPlaybackServices.shared.setup
        let kind: QTPlaybackEngineKind = native != nil ? .native : (engine is QTSimulatedPlaybackEngine ? .simulated : .web)
        (d.engine, d.engineReason) = engineDescription(
            kind: kind, source: setup?.source ?? .live, isAnonymous: setup?.isAnonymous ?? false,
            nativeOptIn: settings.playbackEffects.nativeEngine, nativeEligible: QTNativeEngineCoordinator.shared.isEligible,
            signedIn: store.auth.isSignedIn, fallbackReason: native?.fallbackReason, nativeActive: native?.isNativeActive ?? false)
        d.status = statusLine(player.state)
        d.wantsPlayback = player.playback.wantsPlayback
        d.mode = player.mode == .video ? "video" : "song"
        d.isNetworkAvailable = engine.isNetworkAvailable
        if let track = player.nowPlaying { d.nowPlaying = "“\(track.title)” (\(track.videoId))" }
        d.lastNotice = QTPlaybackServices.shared.lastNotice.map { plain(String(describing: $0)) }
        if let toast = model.lastToast {
            d.lastToast = "“\(toast.message)” at \(QTProblemReport.clock(toast.date, timeZone: .current).prefix(8))"
        }

        d.syncsToYouTubeMusic = settings.syncsToYouTubeMusic
        let unofficial = settings.unofficialLyricsSources
        let sources = [(unofficial.netease, "NetEase"), (unofficial.kugou, "Kugou"), (unofficial.qq, "QQ")].filter(\.0).map(\.1)
        d.unofficialLyrics = sources.isEmpty ? "off" : sources.joined(separator: ", ")
        let target = settings.lyricsTranslation
        d.translation = target == .interfaceLanguage
            ? "auto → \(model.resolvedTranslationLanguage ?? "off")"
            : target.rawValue
        d.nativeEngineOptIn = settings.playbackEffects.nativeEngine
        d.globalShortcuts = settings.globalHotKeys.all.count
        let integrations = QTIntegrationsCoordinator.shared.store.settings
        d.lastFMConnected = integrations.lastFM.isConnected
        d.listenBrainzConnected = integrations.listenBrainz.isConnected
        d.discordOn = integrations.discord.isEnabled
        d.logMinutes = logMinutes
        return d
    }

    // MARK: Pieces (tested)

    /// The account's kind, never who it is.
    static func account(mode: QTCatalogMode, state: QTAuthState, accountIsPremium: Bool?) -> QTProblemDiagnostics.Account {
        switch mode {
        case .mock: return .demo
        case .restoring: return .restoring
        default: break
        }
        switch state {
        case .signedOut: return .guest
        case .signingIn: return .signingIn
        case .sessionExpired: return .sessionExpired
        case .signedIn(_, let isPremium): return .signedIn(premium: isPremium || accountIsPremium == true)
        }
    }

    /// Which engine plays and why that one.
    static func engineDescription(kind: QTPlaybackEngineKind, source: QTPlaybackDataSource, isAnonymous: Bool,
                                  nativeOptIn: Bool, nativeEligible: Bool, signedIn: Bool, fallbackReason: String?,
                                  nativeActive: Bool) -> (String, String) {
        switch kind {
        case .simulated:
            return ("simulated", source == .mock ? "demo library" : "-qt.engine simulated")
        case .native:
            if let fallbackReason { return ("native", "fell back to YouTube's player for this session: \(fallbackReason)") }
            return ("native", nativeActive ? "Premium, opted in" : "Premium, opted in; this item plays in YouTube's player")
        case .web:
            let reason: String
            if source == .mock { reason = "demo library through YouTube's player" }
            else if isAnonymous { reason = "YouTube's player, anonymous" }
            else if !nativeOptIn { reason = "YouTube's player; native engine off" }
            else if !nativeEligible { reason = signedIn ? "YouTube's player; native engine needs Premium" : "YouTube's player; native engine needs a signed-in Premium account" }
            else { reason = "YouTube's player; switching to the native engine" }
            return ("web", reason)
        }
    }

    /// `playing`, `loading, buffering`, `failed(network)`, `playing, ad`.
    static func statusLine(_ state: QTPlaybackState) -> String {
        var parts = [plain(String(describing: state.status))]
        if state.isBuffering { parts.append("buffering") }
        if state.ad != nil { parts.append("ad") }
        return parts.joined(separator: ", ")
    }

    /// Drops module and type qualifiers from a value's description: `failed(QTPlayback.QTPlaybackError.network)` →
    /// `failed(network)`.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\\b[A-Z][A-Za-z0-9_]*\\.", with: "", options: .regularExpression)
    }

    /// `Version 26.1 (Build 25B78)` → `26.1 (25B78)`.
    static func macOSVersion(_ raw: String) -> String {
        raw.replacingOccurrences(of: "Version ", with: "").replacingOccurrences(of: "Build ", with: "")
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 (Rosetta)" : "x86_64"
        #endif
    }

    /// `dark (setting auto)`, plus the accessibility display options that change how the app draws.
    static func appearance(theme: QTThemePreference) -> String {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ws = NSWorkspace.shared
        let options = [(ws.accessibilityDisplayShouldReduceTransparency, "Reduce Transparency"),
                       (ws.accessibilityDisplayShouldIncreaseContrast, "Increase Contrast"),
                       (ws.accessibilityDisplayShouldReduceMotion, "Reduce Motion")].filter(\.0).map(\.1)
        return "\(dark ? "dark" : "light") (setting \(theme.rawValue))" + (options.isEmpty ? "" : "; " + options.joined(separator: ", "))
    }

    nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    nonisolated static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    // MARK: The log

    /// This process's notices, errors and faults from our subsystems over the last `minutes`, oldest first.
    nonisolated static func recentLog(minutes: Int, subsystems: [String]) -> [QTDiagnosticLogLine] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = Date().addingTimeInterval(-Double(minutes) * 60)
        let predicate = NSPredicate(format: "subsystem IN %@", subsystems)
        guard let entries = try? store.getEntries(at: store.position(date: since), matching: predicate) else { return [] }
        var lines: [QTDiagnosticLogLine] = []
        for case let entry as OSLogEntryLog in entries where entry.date >= since {
            let level: QTDiagnosticLogLine.Level
            switch entry.level {
            case .notice: level = .notice
            case .error: level = .error
            case .fault: level = .fault
            default: continue
            }
            lines.append(QTDiagnosticLogLine(date: entry.date, category: entry.category, level: level, message: entry.composedMessage))
        }
        return lines
    }

    #if DEBUG
    /// `-qt.report.sampleLog YES`: a believable few minutes for screenshots, with things the redaction removes.
    nonisolated static func sampleLog(now: Date) -> [QTDiagnosticLogLine] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        let home = NSHomeDirectory()
        return [
            QTDiagnosticLogLine(date: at(14.2), category: "playback", message: "network unavailable"),
            QTDiagnosticLogLine(date: at(13.9), category: "playback", message: "network available"),
            QTDiagnosticLogLine(date: at(9.6), category: "native", level: .error,
                                message: "native engine falls back to YouTube's player for this session: player request failed (403) https://music.youtube.com/youtubei/v1/player?key=sample-key-0123456789&prettyPrint=false"),
            QTDiagnosticLogLine(date: at(6.1), category: "playback", level: .error, message: "couldn't play Xk3dRq9LmPw: network, skipped (1 in a row)"),
            QTDiagnosticLogLine(date: at(3.4), category: "lyrics", level: .error,
                                message: "lyrics cache migration failed: \(home)/Library/Application Support/com.roderickqiu.qtube/Lyrics.sqlite is locked"),
            QTDiagnosticLogLine(date: at(1.2), category: "playback", message: "notice: interrupted"),
        ]
    }
    #endif
}

// MARK: - The window

/// Help › Report a Problem…: what happened, Include diagnostics (Show Diagnostics = the exact text), Cancel,
/// Copy Report, Open GitHub Issue… (⌘↩). Esc cancels.
public struct QTReportProblemView: View {
    public static let sceneID = "qt.window.reportProblem"

    @Environment(QTAppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var text = ""
    @State private var includesDiagnostics = true
    @State private var showsDiagnostics = false
    @State private var diagnostics: QTRenderedDiagnostics?
    @FocusState private var isEditorFocused: Bool

    public init() {}

    private var report: QTProblemReport {
        QTProblemReport(description: text, diagnostics: includesDiagnostics ? diagnostics : nil)
    }

    /// Diagnostics wanted but still being gathered (a moment: the log is read once).
    private var isGathering: Bool { includesDiagnostics && diagnostics == nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(QTLoc.tr("What happened?", table: .desktop))
                    .font(.headline)
                editor
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(QTLoc.tr("Include diagnostics", table: .desktop), isOn: $includesDiagnostics)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("qt.reportProblem.includeDiagnostics")
                Text(QTLoc.tr("Versions, playback state, settings and this session’s app log — never names, email addresses or sign-in data.", table: .desktop))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            DisclosureGroup(QTLoc.tr("Show Diagnostics", table: .desktop), isExpanded: $showsDiagnostics) {
                diagnosticsText
                    .padding(.top, 6)
            }
            .disabled(!includesDiagnostics)
            .accessibilityIdentifier("qt.reportProblem.showDiagnostics")
            VStack(alignment: .leading, spacing: 4) {
                // Said before the click: the link can't carry it all, so the clipboard and a file will.
                if !isGathering, QTIssueLink(report: report).needsAttachment {
                    Text(QTLoc.tr("The full report is too long for a link, so it will also be copied and saved as a file to attach.", table: .desktop))
                }
                Text(QTLoc.tr("Nothing is sent until you submit it on GitHub.", table: .desktop))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(QTLoc.tr("Cancel", table: .desktop)) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(QTLoc.tr("Copy Report", table: .desktop)) {
                    QTReportProblem.copy(report, model: model)
                }
                .disabled(isGathering)
                .accessibilityIdentifier("qt.reportProblem.copy")
                Button(QTLoc.tr("Open GitHub Issue…", table: .desktop)) {
                    QTReportProblem.openIssue(report, model: model)
                    close()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isGathering)
                .help("⌘↩")
                .accessibilityIdentifier("qt.reportProblem.openIssue")
            }
        }
        .padding(20)
        .frame(width: 600)
        // Copy Report's toast shows here too (the main window may be behind or closed).
        .overlay(alignment: .top) { QTToastOverlay() }
        .accessibilityIdentifier("qt.reportProblem")
        .task {
            #if DEBUG
            if let seeded = model.launch.string(QTReportProblem.LaunchKey.text) { text = seeded }
            showsDiagnostics = model.launch.bool(QTReportProblem.LaunchKey.expanded) == true
            #endif
            isEditorFocused = true
            let hold = QTReadiness.shared.hold("report diagnostics")
            diagnostics = await QTProblemDiagnosticsCollector.collect(model: model)
            QTReadiness.shared.release(hold)
        }
    }

    /// A text view with a placeholder, framed like a text field.
    private var editor: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .focused($isEditorFocused)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(QTLoc.tr("What did you do, what did you expect, and what happened instead?", table: .desktop))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .frame(height: 150)
            .accessibilityLabel(QTLoc.tr("What happened?", table: .desktop))
            .accessibilityIdentifier("qt.reportProblem.description")
    }

    /// The diagnostics exactly as shared: read-only, selectable, monospaced.
    private var diagnosticsText: some View {
        ScrollView {
            Group {
                if let diagnostics {
                    Text(verbatim: diagnostics.markdown)
                        .textSelection(.enabled)
                } else {
                    Text(QTLoc.tr("Gathering diagnostics…", table: .desktop))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(height: 220)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityIdentifier("qt.reportProblem.diagnostics")
    }

    private func close() {
        dismissWindow(id: Self.sceneID)
    }
}
