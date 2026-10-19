import Foundation
import Observation
import QTCore
import SwiftUI
import Translation

// Owner: builder "lyrics-ui". Which translation lane the lyrics show and what the options popover says about it
// (draft §7b): the provider's own translation when it matches the target, otherwise on-device machine translation
// through Apple's Translation framework (macOS 15+), which needs a consented model download. Songs already in the
// target language get no translation line.

/// What the options popover reports about the translation line.
public enum QTLyricsTranslationStatus: Equatable, Sendable {
    case noLyrics
    case off
    /// The song is already in the target language (BCP-47 code).
    case sameLanguage(String)
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
    /// Set when on-device translation is (or could be) involved.
    var machineKey: QTLyricsTranslationCenter.Key?
}

/// On-device lyric translation (Translation framework). One per process; views host the sessions.
@MainActor
@Observable
final class QTLyricsTranslationCenter {
    static let shared = QTLyricsTranslationCenter()

    struct Key: Hashable, Sendable {
        var fingerprint: Int
        var source: String
        var target: String
    }

    enum Phase: Equatable {
        case checking
        case needsDownload
        case ready
        case translating
        case done
        case unavailable
    }

    struct Entry {
        var phase: Phase
        var lines: [String?]?
        var configuration: TranslationSession.Configuration?
        var consented = false
        var inFlight = false
    }

    private(set) var entries: [Key: Entry] = [:]
    /// Launch option `qt.lyrics.translationState` (popover screenshots); nil in normal use.
    var forcedStatus: String?

    init(launch: QTLaunchOptions = .current) {
        forcedStatus = launch.string("qt.lyrics.translationState")
    }

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
            return .init(status: forced ?? .sameLanguage(target), lanes: .init())
        }
        if doc.hasTranslation, let tl = doc.translationLanguage {
            let name = doc.translationSource?.name ?? doc.source.name
            if tl == target {
                return .init(status: forced ?? .provider(name), lanes: .init(translations: provider, translationLanguage: tl))
            }
            if tl.hasPrefix("zh"), target.hasPrefix("zh"), let transform = Self.chineseTransform(from: tl, to: target) {
                let converted = provider.map { $0?.applyingTransform(transform, reverse: false) ?? $0 }
                return .init(status: forced ?? .provider(name), lanes: .init(translations: converted, translationLanguage: target))
            }
        }
        let key = Key(fingerprint: Self.fingerprint(doc), source: songLanguage, target: target)
        let entry = entries[key]
        let status: QTLyricsTranslationStatus
        switch entry?.phase {
        case nil, .checking?, .ready?, .translating?: status = .translating
        case .needsDownload?: status = .needsDownload(target)
        case .done?: status = .onDevice
        case .unavailable?: status = .unavailable
        }
        let lanes = QTLyricsLanes(translations: entry?.phase == .done ? entry?.lines : nil, translationLanguage: target)
        return .init(status: forced ?? status, lanes: lanes, machineKey: key)
    }

    func configuration(for key: QTLyricsTranslationCenter.Key?) -> TranslationSession.Configuration? {
        key.flatMap { entries[$0]?.configuration }
    }

    // MARK: Driving (from `.task` / `.translationTask` / the popover)

    /// Checks whether the language pair is installed; translates right away if so.
    func prepare(_ key: Key) async {
        guard entries[key] == nil else { return }
        entries[key] = Entry(phase: .checking)
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: key.source),
                                                          to: Locale.Language(identifier: key.target))
        switch status {
        case .installed:
            entries[key]?.phase = .ready
            entries[key]?.configuration = .init(source: Locale.Language(identifier: key.source), target: Locale.Language(identifier: key.target))
        case .supported:
            entries[key]?.phase = .needsDownload
        case .unsupported:
            entries[key]?.phase = .unavailable
        @unknown default:
            entries[key]?.phase = .unavailable
        }
    }

    /// The user clicked "Download {language} for offline translation": the system asks for consent and downloads.
    func requestDownload(_ key: Key) {
        guard var e = entries[key] else { return }
        e.consented = true
        e.phase = .ready
        if e.configuration == nil {
            e.configuration = .init(source: Locale.Language(identifier: key.source), target: Locale.Language(identifier: key.target))
        } else {
            e.configuration?.invalidate()
        }
        entries[key] = e
    }

    /// Runs inside `.translationTask`: downloads with consent if needed, then translates every line.
    func run(_ session: TranslationSession, key: Key, document doc: QTLyricsDocument) async {
        guard let e = entries[key], !e.inFlight, e.phase == .ready else { return }
        entries[key]?.inFlight = true
        entries[key]?.phase = .translating
        do {
            let texts = doc.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let translated = try await Self.translate(QTTranslationSessionBox(session: session), texts: texts, prepare: e.consented)
            var lines = [String?](repeating: nil, count: doc.lines.count)
            for (i, t) in translated where lines.indices.contains(i) { lines[i] = t }
            entries[key]?.lines = lines
            entries[key]?.phase = .done
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
    private nonisolated static func translate(_ box: QTTranslationSessionBox, texts: [String], prepare: Bool) async throws -> [(Int, String)] {
        if prepare { try await box.session.prepareTranslation() }
        let requests = texts.enumerated().compactMap { i, t in
            t.isEmpty ? nil : TranslationSession.Request(sourceText: t, clientIdentifier: String(i))
        }
        let responses = try await box.session.translations(from: requests)
        return responses.compactMap { r in r.clientIdentifier.flatMap(Int.init).map { ($0, r.targetText) } }
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

    static func chineseTransform(from: String, to: String) -> StringTransform? {
        switch (from, to) {
        case ("zh-Hans", "zh-Hant"): StringTransform("Hans-Hant")
        case ("zh-Hant", "zh-Hans"): StringTransform("Hant-Hans")
        default: nil
        }
    }

    static func fingerprint(_ doc: QTLyricsDocument) -> Int {
        var h = Hasher()
        for l in doc.lines { h.combine(l.text) }
        return h.finalize()
    }
}

/// `TranslationSession` isn't Sendable; the Translation framework hands one to a single `.translationTask` action,
/// which uses it sequentially from one task.
struct QTTranslationSessionBox: @unchecked Sendable {
    let session: TranslationSession
}

/// Hosts on-device translation sessions for the lyrics a view shows (the Translation framework hands out
/// sessions only through SwiftUI on macOS 15).
struct QTLyricsTranslationHost: ViewModifier {
    let document: QTLyricsDocument?
    let key: QTLyricsTranslationCenter.Key?
    private var center: QTLyricsTranslationCenter { .shared }

    func body(content: Content) -> some View {
        content
            .task(id: key) {
                guard let key else { return }
                await center.prepare(key)
            }
            .translationTask(center.configuration(for: key)) { session in
                guard let key, let document else { return }
                await center.run(session, key: key, document: document)
            }
    }
}
