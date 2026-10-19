import Foundation
import Observation
import OSLog
import QTCore
import QTLyrics
import SwiftUI
import Translation

// Owner: builder "lyrics-ui" / lyrics-translate (M6). Which translation lane the lyrics show and what the options
// popover says about it (draft §7b, HANDOFF §4), in this order:
//   1. the lyrics provider's own translation when it is in the target language;
//   2. Apple Intelligence (Foundation Models, macOS 26+) when "Translate lyrics with Apple Intelligence" is on and
//      the model is available for the target — it reads the whole song, so imagery and slang survive;
//   3. Apple's Translation framework (macOS 15+), "On-device translation", whose language models download only
//      after the user clicks "Download {language} for offline translation".
// Songs already in the target language get no translation line; Chinese lyrics in the other script are shown converted
// into the target's (QTLyricsScriptConversion). A failed Apple Intelligence run (refusal, wrong
// line count, untranslated echo, timeout) falls back to the Translation framework for the whole song; nothing partial
// or misaligned is ever shown. Results are cached in SQLite per lyrics + language + engine.

/// What the options popover reports about the translation line.
public enum QTLyricsTranslationStatus: Equatable, Sendable {
    case noLyrics
    case off
    /// The song is already in the target language (BCP-47 code).
    case sameLanguage(String)
    /// Chinese lyrics shown converted into the target's script (繁體 ⇄ 简体), BCP-47 code of the target.
    case convertedScript(String)
    /// The lyrics provider supplies it (display name, e.g. "NetEase").
    case provider(String)
    case translating
    /// The on-device model for this language isn't installed; offer "Download {language} for offline translation".
    case needsDownload(String)
    case unavailable
    case onDevice
    case appleIntelligence

    /// Parses the `qt.lyrics.translationState` launch option (screenshots of every popover state).
    init?(argument: String, target: String) {
        switch argument {
        case "same": self = .sameLanguage(target)
        case "converted": self = .convertedScript(target)
        case "translating", "pending": self = .translating
        case "download": self = .needsDownload(target)
        case "unavailable": self = .unavailable
        case "onDevice", "device": self = .onDevice
        case "appleIntelligence", "ai": self = .appleIntelligence
        default: return nil
        }
    }
}

/// The resolved translation state for a document + target language.
struct QTLyricsTranslationResolution: Equatable {
    var status: QTLyricsTranslationStatus
    var lanes: QTLyricsLanes
    /// Set when machine translation is (or could be) involved.
    var machineKey: QTLyricsTranslationCenter.Key?
}

extension QTLyricsTranslationResolution {
    /// A translation line shows, or is on its way: in Automatic the pronunciation lane steps back for it.
    var expectsTranslation: Bool {
        if lanes.translations?.contains(where: { $0?.isEmpty == false }) == true { return true }
        return status == .translating
    }
}

/// Machine translation of lyrics (Apple Intelligence, Translation framework). One per process; views host the
/// Translation framework's sessions where the OS needs SwiftUI for them.
@MainActor
@Observable
final class QTLyricsTranslationCenter {
    static let shared = QTLyricsTranslationCenter()

    struct Key: Hashable, Sendable {
        /// Stable hash of the lyric lines (also the SQLite cache key).
        var fingerprint: String
        var source: String
        var target: String
        /// "Translate lyrics with Apple Intelligence" was on when the job was keyed.
        var allowsAppleIntelligence: Bool = true

        var cacheKey: String { "lyrics:\(fingerprint)" }
    }

    enum Phase: Equatable {
        case checking
        case needsDownload
        /// Waiting for a SwiftUI-hosted Translation framework session.
        case ready
        case translating
        case done
        case unavailable
    }

    struct Entry {
        var phase: Phase
        var lines: [String?]?
        /// The engine that produced `lines`.
        var engine: QTLyricsTranslationEngineKind?
        var configuration: TranslationSession.Configuration?
        var consented = false
        var inFlight = false
        /// What the job translates (kept for re-checks and the hosted session).
        var sourceLines: [String] = []
        var title = ""
        var artist = ""
    }

    private(set) var entries: [Key: Entry] = [:]
    /// Launch option `qt.lyrics.translationState` (popover screenshots); nil in normal use.
    var forcedStatus: String?
    /// Settings (for the Apple Intelligence toggle); nil = toggle treated as on.
    @ObservationIgnored var settings: QTSettingsStore?
    @ObservationIgnored private(set) var coordinator: QTLyricsTranslationCoordinator
    @ObservationIgnored private var jobs: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics-translate")

    init(launch: QTLaunchOptions = .current, coordinator: QTLyricsTranslationCoordinator = .standard(cache: nil)) {
        forcedStatus = launch.string("qt.lyrics.translationState")
        self.coordinator = coordinator
    }

    /// The app's wiring: translations cached next to the lyrics (same SQLite file), the settings' toggle respected.
    func attach(settings: QTSettingsStore, cache: QTLyricsCache?) {
        self.settings = settings
        coordinator = .standard(cache: cache)
    }

    var allowsAppleIntelligence: Bool { settings?.settings.translateWithAppleIntelligence ?? true }

    // MARK: Resolution (pure read — safe from view bodies)

    /// - Parameters:
    ///   - target: BCP-47 target, nil when translation is off.
    ///   - honorsTarget: false when the caller has no app model (always show the provider's lane).
    func resolve(_ doc: QTLyricsDocument?, target: String?, honorsTarget: Bool = true) -> QTLyricsTranslationResolution {
        guard let doc else { return .init(status: .noLyrics, lanes: .init()) }
        let provider = doc.lines.map { $0.translation }
        guard honorsTarget else {
            return .init(status: .provider(doc.translationSource?.name ?? doc.source.name),
                         lanes: .init(translations: doc.hasTranslation ? provider : nil, translationLanguage: doc.translationLanguage))
        }
        let forced = forcedStatus.flatMap { QTLyricsTranslationStatus(argument: $0, target: target ?? "en") }
        guard let target else { return .init(status: forced ?? .off, lanes: .init()) }
        let songLanguage = Self.songLanguage(doc)
        if QTLyricsTranslationTarget.isSameLanguage(songLanguage, target) {
            let status: QTLyricsTranslationStatus = doc.scriptConvertedFrom != nil ? .convertedScript(target) : .sameLanguage(target)
            return .init(status: forced ?? status, lanes: .init())
        }
        if doc.hasTranslation, let tl = doc.translationLanguage {
            let name = doc.translationSource?.name ?? doc.source.name
            if tl == target {
                return .init(status: forced ?? .provider(name), lanes: .init(translations: provider, translationLanguage: tl))
            }
            if let script = QTChineseScript(target: target), QTChineseScript(target: tl) != nil {
                let converted = QTLyricsTranslationPolicy.convertedTranslations(doc.lines, to: script).map(\.translation)
                return .init(status: forced ?? .provider(name), lanes: .init(translations: converted, translationLanguage: target))
            }
        }
        let key = Key(fingerprint: Self.fingerprint(doc), source: songLanguage, target: target,
                      allowsAppleIntelligence: allowsAppleIntelligence)
        let entry = entries[key]
        let status: QTLyricsTranslationStatus
        switch entry?.phase {
        case nil, .checking?, .ready?, .translating?: status = .translating
        case .needsDownload?: status = .needsDownload(target)
        case .done?: status = entry?.engine == .appleIntelligence ? .appleIntelligence : .onDevice
        case .unavailable?: status = .unavailable
        }
        let lanes = QTLyricsLanes(translations: entry?.phase == .done ? entry?.lines : nil, translationLanguage: target)
        return .init(status: forced ?? status, lanes: lanes, machineKey: key)
    }

    func configuration(for key: QTLyricsTranslationCenter.Key?) -> TranslationSession.Configuration? {
        key.flatMap { entries[$0]?.configuration }
    }

    /// The engine that produced the translation for `key`, once it is done.
    func engine(for key: Key?) -> QTLyricsTranslationEngineKind? {
        guard let key, let e = entries[key], e.phase == .done else { return nil }
        return e.engine
    }

    // MARK: Driving (from `.task` / `.translationTask` / the popover)

    /// Starts the job for `key` once: cache → Apple Intelligence → Translation framework (direct on macOS 26+,
    /// otherwise through a hosted session; a missing language model waits for the user's consent). The job belongs to
    /// the center, so it finishes even if the view that asked goes away.
    func prepare(_ key: Key, document doc: QTLyricsDocument, title: String = "", artist: String = "") {
        guard entries[key] == nil else { return }
        var entry = Entry(phase: .checking)
        entry.sourceLines = doc.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        entry.title = title
        entry.artist = artist
        entries[key] = entry
        start(key)
    }

    /// Async form for tests: starts the job and waits for it.
    func prepareAndWait(_ key: Key, document doc: QTLyricsDocument, title: String = "", artist: String = "") async {
        prepare(key, document: doc, title: title, artist: artist)
        await jobs[key]?.value
    }

    /// Looks again at jobs that ended without a translation (a model was installed or Apple Intelligence became ready
    /// in the meantime). Called when the lyrics options open.
    func recheck(_ key: Key?) {
        guard let key, let e = entries[key], jobs[key] == nil, !e.consented,
              e.phase == .needsDownload || e.phase == .unavailable else { return }
        entries[key]?.phase = .checking
        start(key)
    }

    private func start(_ key: Key) {
        jobs[key] = Task { @MainActor [weak self] in
            await self?.process(key)
            self?.jobs[key] = nil
        }
    }

    private func process(_ key: Key) async {
        guard let e = entries[key] else { return }
        let lines = e.sourceLines
        let c = coordinator
        let context = QTLyricsTranslationContext(title: e.title, artist: e.artist, sourceLanguage: key.source,
                                                 targetLanguage: key.target)
        let order: [QTLyricsTranslationEngineKind] = key.allowsAppleIntelligence ? [.appleIntelligence, .translationFramework] : [.translationFramework]
        // Cached translations work offline and before Apple Intelligence is ready.
        for kind in order {
            if let cached = await c.cachedTranslation(key: key.cacheKey, target: key.target, engine: kind, lineCount: lines.count,
                                                     source: lines) {
                finish(key, cached, engine: kind)
                return
            }
        }
        if key.allowsAppleIntelligence {
            let availability = await c.availability(of: .appleIntelligence, from: key.source, to: key.target)
            if availability == .available {
                entries[key]?.phase = .translating
                do {
                    let out = try await c.run(.appleIntelligence, lines: lines, key: key.cacheKey, context: context)
                    finish(key, out, engine: .appleIntelligence)
                    return
                } catch {
                    log.info("Apple Intelligence translation \(key.source, privacy: .public)→\(key.target, privacy: .public) fell back: \(String(describing: error), privacy: .public)")
                }
            } else {
                log.debug("Apple Intelligence not used: \(String(describing: availability), privacy: .public)")
            }
        }
        var availability = await c.availability(of: .translationFramework, from: key.source, to: key.target)
        var frameworkLines = lines
        var frameworkContext = context
        // Traditional Chinese lyrics with only the Simplified model installed: the same words in Simplified script
        // translate as well, without asking for a second download (direct sessions only — a hosted session is
        // configured for the song's own language).
        if availability == .needsDownload, QTLanguageCode.normalize(key.source) == "zh-Hant",
           await c.translatesDirectly(.translationFramework),
           await c.availability(of: .translationFramework, from: "zh-Hans", to: key.target) == .available {
            let toSimplified = StringTransform("Hant-Hans")
            frameworkLines = lines.map { $0.applyingTransform(toSimplified, reverse: false) ?? $0 }
            frameworkContext.sourceLanguage = "zh-Hans"
            availability = .available
        }
        switch availability {
        case .available:
            if await c.translatesDirectly(.translationFramework) {
                entries[key]?.phase = .translating
                do {
                    let out = try await c.run(.translationFramework, lines: frameworkLines, key: key.cacheKey, context: frameworkContext)
                    finish(key, out, engine: .translationFramework)
                    return
                } catch {
                    log.info("Translation framework (direct) failed: \(String(describing: error), privacy: .public)")
                }
            }
            // Hosted session (macOS 15–25, or the direct path failed).
            entries[key]?.phase = .ready
            entries[key]?.configuration = Self.configuration(key)
        case .needsDownload:
            entries[key]?.phase = .needsDownload
        case .unavailable:
            entries[key]?.phase = .unavailable
        }
    }

    private func finish(_ key: Key, _ lines: [String], engine: QTLyricsTranslationEngineKind) {
        entries[key]?.lines = lines.map { $0.isEmpty ? nil : $0 }
        entries[key]?.engine = engine
        entries[key]?.phase = .done
        log.info("lyrics translated \(key.source, privacy: .public)→\(key.target, privacy: .public) by \(engine.rawValue, privacy: .public)")
    }

    private static func configuration(_ key: Key) -> TranslationSession.Configuration {
        .init(source: Locale.Language(identifier: key.source), target: Locale.Language(identifier: key.target))
    }

    /// The user clicked "Download {language} for offline translation": the system asks for consent and downloads.
    func requestDownload(_ key: Key) {
        guard var e = entries[key] else { return }
        e.consented = true
        e.phase = .ready
        if e.configuration == nil {
            e.configuration = Self.configuration(key)
        } else {
            e.configuration?.invalidate()
        }
        entries[key] = e
    }

    /// Runs inside `.translationTask`: downloads with consent if needed, then translates every line.
    func run(_ session: TranslationSession, key: Key) async {
        guard let e = entries[key], !e.inFlight, e.phase == .ready else { return }
        entries[key]?.inFlight = true
        entries[key]?.phase = .translating
        do {
            let items = QTTranslationFrameworkBatch.items(for: e.sourceLines)
            let pairs = try await Self.translate(QTTranslationSessionBox(session: session), items: items, prepare: e.consented)
            let raw = try QTTranslationFrameworkBatch.lines(from: pairs, count: e.sourceLines.count, expected: items.count)
            let out = QTLyricsTranslationPolish.lines(raw, source: e.sourceLines)
            finish(key, out, engine: .translationFramework)
            await coordinator.storeTranslation(out, key: key.cacheKey, target: key.target, engine: .translationFramework)
        } catch is CancellationError {
            // The hosting view went away; another host may pick it up.
            entries[key]?.phase = .ready
            entries[key]?.configuration?.invalidate()
        } catch {
            entries[key]?.phase = e.consented ? .unavailable : .needsDownload
        }
        entries[key]?.inFlight = false
    }

    /// Talks to the session off the main actor. The box is used by this one task only, sequentially.
    private nonisolated static func translate(_ box: QTTranslationSessionBox, items: [(index: Int, text: String)],
                                              prepare: Bool) async throws -> [(id: String?, text: String)] {
        if prepare { try await box.session.prepareTranslation() }
        let responses = try await box.session.translations(from: QTTranslationFrameworkBatch.requests(items))
        return responses.map { (id: $0.clientIdentifier, text: $0.targetText) }
    }

    // MARK: Helpers

    /// Lyric language: the document's tag, else detected from the first lines' script.
    static func songLanguage(_ doc: QTLyricsDocument) -> String {
        if let l = doc.language, !l.isEmpty { return l }
        let sample = doc.lines.prefix(12).map(\.text).joined(separator: " ")
        switch QTLyricScript.detect(sample) {
        case .vietnamese: return "vi"
        case .han: return "zh-Hans"
        case .japanese: return "ja"
        case .hangul: return "ko"
        case .thai: return "th"
        case .cyrillic: return "ru"
        case .latin, .other: return "en"
        }
    }

    /// FNV-1a over the line texts: stable across launches (Swift's `Hasher` is seeded per process), so it can key
    /// the on-disk cache.
    static func fingerprint(_ doc: QTLyricsDocument) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in doc.lines {
            for b in line.text.utf8 {
                h ^= UInt64(b)
                h &*= 0x0000_0100_0000_01b3
            }
            h ^= 0x0a
            h &*= 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

/// `TranslationSession` isn't Sendable; the Translation framework hands one to a single `.translationTask` action,
/// which uses it sequentially from one task.
struct QTTranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession
}

/// Starts machine translation for the lyrics a view shows and hosts the Translation framework's session where the
/// OS hands sessions out only through SwiftUI (macOS 15–25, and the consented download on every version).
struct QTLyricsTranslationHost: ViewModifier {
    let document: QTLyricsDocument?
    let key: QTLyricsTranslationCenter.Key?
    @Environment(QTPlayerModel.self) private var player: QTPlayerModel?
    private var center: QTLyricsTranslationCenter { .shared }

    func body(content: Content) -> some View {
        content
            .task(id: key) {
                guard let key, let document else { return }
                let track = player?.nowPlaying
                center.prepare(key, document: document, title: track?.title ?? "", artist: track?.artistLine ?? "")
            }
            .translationTask(center.configuration(for: key)) { session in
                guard let key else { return }
                await center.run(session, key: key)
            }
    }
}

private extension QTTrack {
    /// Artist names for the model's context ("Artist A, Artist B").
    var artistLine: String { artists.map(\.name).joined(separator: ", ") }
}
