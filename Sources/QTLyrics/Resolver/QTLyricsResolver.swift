import Foundation
import OSLog
import QTCore

/// A version of the lyrics for the "Wrong lyrics? / Other versions (n)" menu.
public struct QTLyricsVersion: Sendable, Hashable, Codable, Identifiable {
    public var candidate: QTLyricsCandidate
    /// Match score 0…1 (after fetching, when fetched).
    public var score: Double
    /// Known after fetching; otherwise the provider's hint.
    public var syncKind: QTLyricsSyncKind?
    public var hasTranslation: Bool
    public var id: String { candidate.id }
    public var source: QTLyricsSource { candidate.source }
    /// 0.60–0.80: shown with a "possible mismatch" badge.
    public var isPossibleMismatch: Bool { score < QTLyricsMatchThreshold.accept }
}

/// The outcome of a lookup.
public struct QTLyricsResolution: Sendable, Hashable {
    /// What the UI shows: offset applied, translation lane only when it is in the target language.
    public var document: QTLyricsDocument?
    public var versions: [QTLyricsVersion]
    public var chosenID: String?
    public var isPinned: Bool
    /// "Source: LyricFind" for YouTube Music lyrics.
    public var attribution: String?
    public var fromCache: Bool

    public var isPossibleMismatch: Bool { (document?.confidence ?? 1) < QTLyricsMatchThreshold.accept }
}

public struct QTLyricsResolverConfiguration: Sendable, Hashable {
    /// Opt-in unofficial sources (Settings › Lyrics); all off by default.
    public var unofficialSources: QTUnofficialLyricsSources
    /// Resolved lyrics translation language (BCP-47), nil = Off.
    public var translationLanguage: String?
    /// Add a romanization lane on device for non-Latin scripts when no provider supplies one.
    public var romanize: Bool
    public var cacheLifetime: TimeInterval
    /// "No lyrics" is remembered for less time.
    public var negativeCacheLifetime: TimeInterval
    /// Candidates fetched per provider per lookup.
    public var fetchesPerProvider: Int

    public init(unofficialSources: QTUnofficialLyricsSources = .init(), translationLanguage: String? = nil,
                romanize: Bool = true, cacheLifetime: TimeInterval = 30 * 86_400,
                negativeCacheLifetime: TimeInterval = 3 * 86_400, fetchesPerProvider: Int = 2) {
        self.unofficialSources = unofficialSources
        self.translationLanguage = translationLanguage
        self.romanize = romanize
        self.cacheLifetime = cacheLifetime
        self.negativeCacheLifetime = negativeCacheLifetime
        self.fetchesPerProvider = fetchesPerProvider
    }

    /// From the app settings (translation target resolved against the interface language).
    public init(settings: QTSettings, interface: QTResolvedInterfaceLanguage) {
        self.init(unofficialSources: settings.unofficialLyricsSources,
                  translationLanguage: settings.lyricsTranslation.resolvedLanguage(interface: interface))
    }

    func isEnabled(_ source: QTLyricsSource) -> Bool {
        switch source.id {
        case QTLyricsSource.netease.id: unofficialSources.netease
        case QTLyricsSource.kugou.id: unofficialSources.kugou
        case QTLyricsSource.qq.id: unofficialSources.qq
        default: !source.isUnofficial
        }
    }
}

/// The lyrics engine: provider chain → matcher/scorer → pick (word > line > plain, never mixing lines across
/// sources) → second-source translation lane after alignment → SQLite cache keyed by videoId, with per-track
/// offsets, pinned versions and alias learning. Conforms to `QTLyricsProviding`, the protocol the UI uses.
public actor QTLyricsResolver: QTLyricsProviding {
    private let providers: [any QTLyricsSourceProvider]
    private let cache: QTLyricsCache?
    public private(set) var configuration: QTLyricsResolverConfiguration
    private var aliases: QTLyricsAliasBook?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics")

    public init(providers: [any QTLyricsSourceProvider], cache: QTLyricsCache?,
                configuration: QTLyricsResolverConfiguration = .init(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.providers = providers
        self.cache = cache
        self.configuration = configuration
        self.now = now
    }

    /// The standard chain: YouTube Music, AMLL, LRCLIB (safe, on) + NetEase, Kugou, QQ (opt-in).
    public static func standard(configuration: QTLyricsResolverConfiguration = .init(),
                                cache: QTLyricsCache? = try? QTLyricsCache(url: QTLyricsCache.defaultURL()),
                                http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient(),
                                innerTube: (any QTInnerTubeLyricsRequesting)? = nil) -> QTLyricsResolver {
        let providers: [any QTLyricsSourceProvider] = [
            QTYouTubeMusicLyricsProvider(requester: innerTube ?? QTAnonymousInnerTubeLyricsRequester(http: http)),
            QTAMLLLyricsProvider(http: http, cache: cache),
            QTLRCLIBProvider(http: http),
            QTNetEaseLyricsProvider(http: http),
            QTKugouLyricsProvider(http: http),
            QTQQMusicLyricsProvider(http: http),
        ]
        return QTLyricsResolver(providers: providers, cache: cache, configuration: configuration)
    }

    public func update(configuration: QTLyricsResolverConfiguration) {
        self.configuration = configuration
    }

    // MARK: QTLyricsProviding

    public func lyrics(for track: QTTrack) async throws -> QTLyricsDocument? {
        await resolve(QTLyricsQuery(track: track)).document
    }

    // MARK: Lookup

    public func resolve(_ query: QTLyricsQuery, forceRefresh: Bool = false) async -> QTLyricsResolution {
        let pinned = await cache?.pinnedVersionID(for: query.videoId)
        // The pin is part of the key, so a pinned version that can't be fetched isn't retried on every call.
        let key = sourcesKey + (pinned.map { "|pin:" + $0 } ?? "")
        if !forceRefresh, let entry = await cache?.entry(for: query.videoId), entry.sourcesKey == key,
           now().timeIntervalSince(entry.updated) < (entry.document == nil ? configuration.negativeCacheLifetime : configuration.cacheLifetime) {
            return await present(entry, pinned: pinned != nil && pinned == entry.chosenID, fromCache: true)
        }
        var entry = await lookup(query, pinned: pinned)
        entry.sourcesKey = key
        await cache?.store(entry)
        return await present(entry, pinned: pinned != nil && pinned == entry.chosenID, fromCache: false)
    }

    /// Other versions found during the last lookup (resolving first if needed).
    public func versions(for query: QTLyricsQuery) async -> [QTLyricsVersion] {
        await resolve(query).versions
    }

    /// Pins a version for this track ("Wrong lyrics?" menu) and returns the new resolution.
    public func pin(versionID: String, for query: QTLyricsQuery) async -> QTLyricsResolution {
        await cache?.setPinnedVersionID(versionID, for: query.videoId)
        return await resolve(query, forceRefresh: true)
    }

    public func unpin(for query: QTLyricsQuery) async -> QTLyricsResolution {
        await cache?.setPinnedVersionID(nil, for: query.videoId)
        return await resolve(query, forceRefresh: true)
    }

    /// Per-track offset in seconds (positive = lyrics earlier), persisted.
    public func offset(for videoId: String) async -> TimeInterval {
        await cache?.offset(for: videoId) ?? 0
    }

    public func setOffset(_ offset: TimeInterval, for videoId: String) async {
        await cache?.setOffset((offset * 10).rounded() / 10, for: videoId)
    }

    // MARK: Internals

    private var sourcesKey: String {
        let enabled = providers.map(\.source).filter(configuration.isEnabled).map(\.id).sorted().joined(separator: ",")
        return enabled + "|" + (configuration.translationLanguage ?? "off") + "|" + (configuration.romanize ? "r" : "-")
    }

    private func aliasBook() async -> QTLyricsAliasBook {
        if let aliases { return aliases }
        let book = QTLyricsAliasBook(pairs: await cache?.aliasPairs() ?? [])
        aliases = book
        return book
    }

    private struct Evaluated: Sendable {
        var candidate: QTLyricsCandidate
        var score: QTLyricsMatchScore
        var parsed: QTParsedLyrics
    }

    private func lookup(_ query: QTLyricsQuery, pinned: String?) async -> QTLyricsCacheEntry {
        let active = providers.filter { configuration.isEnabled($0.source) }
        let scorer = QTLyricsMatchScorer(aliases: await aliasBook())
        let target = configuration.translationLanguage

        // 1. Search every enabled source in parallel; a failing source never fails the lookup.
        var found: [(QTLyricsCandidate, QTLyricsMatchScore)] = []
        await withTaskGroup(of: [QTLyricsCandidate].self) { group in
            for provider in active {
                group.addTask {
                    do { return try await provider.search(query) } catch { return [] }
                }
            }
            for await list in group {
                for c in list { found.append((c, scorer.score(c, for: query))) }
            }
        }

        // 2. Fetch the most promising candidates (pinned first), a few per provider.
        let acceptable = found.filter { $0.1.isAcceptable(for: $0.0.source) || $0.0.id == pinned }
        let ordered = acceptable.sorted { a, b in
            if (a.0.id == pinned) != (b.0.id == pinned) { return a.0.id == pinned }
            return Self.isRankedHigher(Self.rankKey(a.1.total, a.0.syncHint, false, a.0.source),
                                       Self.rankKey(b.1.total, b.0.syncHint, false, b.0.source))
        }
        var perProvider: [String: Int] = [:]
        let toFetch = ordered.filter { c in
            let n = perProvider[c.0.source.id, default: 0]
            guard n < configuration.fetchesPerProvider || c.0.id == pinned else { return false }
            perProvider[c.0.source.id] = n + 1
            return true
        }
        var evaluated: [Evaluated] = []
        await withTaskGroup(of: Evaluated?.self) { group in
            for (candidate, score) in toFetch {
                let provider = active.first { $0.source.id == candidate.source.id }!
                group.addTask {
                    guard let parsed = try? await provider.lyrics(for: candidate), !parsed.isEmpty else { return nil }
                    return Evaluated(candidate: candidate, score: scorer.rescore(score, candidate: candidate, lyrics: parsed, for: query),
                                     parsed: parsed)
                }
            }
            for await e in group { if let e { evaluated.append(e) } }
        }

        // 3. Pick: pinned (if it fetched) else the best acceptable by tier, sync kind, target translation, score.
        let usable = evaluated.filter { $0.score.isAcceptable(for: $0.candidate.source) || $0.candidate.id == pinned }
        let ranked = usable.sorted { a, b in
            Self.isRankedHigher(Self.rankKey(a.score.total, a.parsed.syncKind, hasLane(a.parsed, target), a.candidate.source),
                                Self.rankKey(b.score.total, b.parsed.syncKind, hasLane(b.parsed, target), b.candidate.source))
        }
        let chosen = ranked.first { $0.candidate.id == pinned } ?? ranked.first

        var versions = ranked.map {
            QTLyricsVersion(candidate: $0.candidate, score: $0.score.total, syncKind: $0.parsed.syncKind,
                            hasTranslation: $0.parsed.lanes.contains { $0.kind == .translation })
        }
        // Candidates that were fetched but failed (empty, overrun, re-scored below threshold) are not offered.
        let fetchedIDs = Set(toFetch.map(\.0.id))
        versions += acceptable.filter { !fetchedIDs.contains($0.0.id) }.map {
            QTLyricsVersion(candidate: $0.0, score: $0.1.total, syncKind: $0.0.syncHint, hasTranslation: false)
        }

        guard let chosen else {
            log.debug("no lyrics for \(query.videoId, privacy: .public)")
            return QTLyricsCacheEntry(videoId: query.videoId, document: nil, versions: versions, chosenID: nil,
                                      attribution: nil, sourcesKey: sourcesKey, updated: now())
        }

        var document = QTLyricsAssembler.document(from: chosen.parsed, source: chosen.candidate.source,
                                                  confidence: chosen.candidate.id == pinned ? max(chosen.score.total, QTLyricsMatchThreshold.accept) : chosen.score.total,
                                                  preferredTranslationLanguage: target, romanize: configuration.romanize)

        // 4. Translation lane from a second source, only after its timestamps line up with ours.
        if let target, document.syncKind != .plain, !QTLanguageCode.isSame(document.language, target),
           !QTLanguageCode.isSame(document.translationLanguage, target) {
            for other in ranked where other.candidate.id != chosen.candidate.id && other.score.total >= QTLyricsMatchThreshold.accept {
                guard let lane = other.parsed.lanes.first(where: { $0.kind == .translation && QTLanguageCode.isSame($0.language, target) }),
                      let aligned = QTLyricsAssembler.alignForeign(lane, to: document.lines) else { continue }
                for i in document.lines.indices { document.lines[i].translation = aligned[i] }
                document.translationLanguage = lane.language
                document.translationSource = other.candidate.source
                break
            }
        }

        await learnAliases(from: chosen, query: query)
        return QTLyricsCacheEntry(videoId: query.videoId, document: document, versions: versions,
                                  chosenID: chosen.candidate.id, attribution: chosen.parsed.metadata.attribution,
                                  sourcesKey: sourcesKey, updated: now())
    }

    private nonisolated func hasLane(_ p: QTParsedLyrics, _ target: String?) -> Bool {
        guard let target else { return false }
        return p.lanes.contains { $0.kind == .translation && QTLanguageCode.isSame($0.language, target) }
    }

    /// Higher is better: accepted tier, then word > line > plain, then a translation in the target language,
    /// then score, then source preference.
    static func rankKey(_ score: Double, _ sync: QTLyricsSyncKind?, _ hasTargetLane: Bool, _ source: QTLyricsSource) -> [Double] {
        let tier = score >= QTLyricsMatchThreshold.accept ? 1.0 : 0.0
        let syncRank: Double = switch sync { case .word: 2; case .line: 1; case .plain: 0; case nil: 0.5 }
        return [tier, syncRank, hasTargetLane ? 1 : 0, (score * 100).rounded() / 100, -Double(sourcePriority(source))]
    }

    static func isRankedHigher(_ a: [Double], _ b: [Double]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    static func sourcePriority(_ source: QTLyricsSource) -> Int {
        switch source.id {
        case QTLyricsSource.youtubeMusic.id: 0
        case QTLyricsSource.amll.id: 1
        case QTLyricsSource.netease.id: 2
        case QTLyricsSource.qq.id: 3
        case QTLyricsSource.kugou.id: 4
        case QTLyricsSource.lrclib.id: 5
        default: 6
        }
    }

    /// Learns spellings from an accepted match: provider-listed aliases (NetEase `tns`/`alia`/`alias`) and the
    /// query's own names when the match crossed scripts.
    private func learnAliases(from chosen: Evaluated, query: QTLyricsQuery) async {
        guard !chosen.candidate.isExactMatch, chosen.score.total >= QTLyricsMatchThreshold.accept else { return }
        var book = await aliasBook()
        var learned: [(String, String)] = []
        let c = chosen.candidate
        let title = QTTitleCleaner.clean(c.title).core
        for alias in c.titleAliases.prefix(3) {
            let a = QTTitleCleaner.clean(alias).core
            if book.add(title, a) { learned.append((title, a)) }
        }
        if let artist = c.artists.first {
            for alias in c.artistAliases.prefix(2) where book.add(artist, alias) { learned.append((artist, alias)) }
            if let q = query.artists.first.map(QTTitleCleaner.cleanArtist), chosen.score.artist < 0.9,
               chosen.score.title >= 0.95, chosen.score.duration >= 0.9, book.add(q, artist) {
                learned.append((q, artist))
            }
        }
        let qTitle = query.cleanTitle.core
        if chosen.score.title >= 0.95, QTLyricsTextFolding.comparisonKey(qTitle) != QTLyricsTextFolding.comparisonKey(title),
           book.add(qTitle, title) {
            learned.append((qTitle, title))
        }
        aliases = book
        for (a, b) in learned { await cache?.addAlias(a, b, origin: c.source.id) }
    }

    /// Applies the per-track offset and the translation policy for the current target.
    private func present(_ entry: QTLyricsCacheEntry, pinned: Bool, fromCache: Bool) async -> QTLyricsResolution {
        var doc = entry.document
        if var d = doc {
            d.offset = await cache?.offset(for: entry.videoId) ?? 0
            doc = QTLyricsTranslationPolicy.applyProviderLane(to: d, target: configuration.translationLanguage)
        }
        return QTLyricsResolution(document: doc, versions: entry.versions, chosenID: entry.chosenID, isPinned: pinned,
                                  attribution: entry.attribution, fromCache: fromCache)
    }
}
