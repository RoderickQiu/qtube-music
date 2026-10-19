import Foundation
import OSLog
import QTCore

/// A version of the lyrics for the "Wrong lyrics? / Other versions (n)" menu. (Named apart from the UI's
/// `QTLyricsVersion` row model in QTUI so the two never shadow each other.)
public struct QTResolvedLyricsVersion: Sendable, Hashable, Codable, Identifiable {
    public var candidate: QTLyricsCandidate
    /// Match score 0…1 (after fetching, when fetched).
    public var score: Double
    /// Known after fetching; otherwise the provider's hint.
    public var syncKind: QTLyricsSyncKind?
    public var hasTranslation: Bool
    /// Language of the version's own translation lane (known after fetching).
    public var translationLanguage: String?

    public init(candidate: QTLyricsCandidate, score: Double, syncKind: QTLyricsSyncKind?, hasTranslation: Bool,
                translationLanguage: String? = nil) {
        self.candidate = candidate
        self.score = score
        self.syncKind = syncKind
        self.hasTranslation = hasTranslation
        self.translationLanguage = translationLanguage
    }
    public var id: String { candidate.id }
    public var source: QTLyricsSource { candidate.source }
    /// 0.60–0.80: shown with a "possible mismatch" badge.
    public var isPossibleMismatch: Bool { score < QTLyricsMatchThreshold.accept }
}

/// The outcome of a lookup.
public struct QTLyricsResolution: Sendable, Hashable {
    /// What the UI shows: offset applied, translation lane only when it is in the target language.
    public var document: QTLyricsDocument?
    /// The same document before the translation policy (every provider lane kept, offset applied), so a change of
    /// target language can be re-presented instantly while a fresh lookup runs.
    public var fullDocument: QTLyricsDocument?
    public var versions: [QTResolvedLyricsVersion]
    public var chosenID: String?
    public var isPinned: Bool
    /// "Source: LyricFind" for YouTube Music lyrics.
    public var attribution: String?
    public var fromCache: Bool
    /// Enabled sources that couldn't be reached (offline, timed out, rate-limited, 5xx). A lookup with no lyrics and
    /// unreachable sources is not remembered as "no lyrics".
    public var unreachableSources: [QTLyricsSource]

    public init(document: QTLyricsDocument?, fullDocument: QTLyricsDocument? = nil, versions: [QTResolvedLyricsVersion],
                chosenID: String?, isPinned: Bool, attribution: String?, fromCache: Bool,
                unreachableSources: [QTLyricsSource] = []) {
        self.document = document
        self.fullDocument = fullDocument ?? document
        self.versions = versions
        self.chosenID = chosenID
        self.isPinned = isPinned
        self.attribution = attribution
        self.fromCache = fromCache
        self.unreachableSources = unreachableSources
    }

    public var isPossibleMismatch: Bool { (document?.confidence ?? 1) < QTLyricsMatchThreshold.accept }
    /// Every enabled source answered (found or not).
    public var isComplete: Bool { unreachableSources.isEmpty }
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
    /// A pick made while some sources were unreachable is retried sooner (a better version may exist).
    public var partialCacheLifetime: TimeInterval
    /// Candidates fetched per provider per lookup.
    public var fetchesPerProvider: Int
    /// Versions offered per source in "Other versions (n)".
    public var versionsPerSource: Int

    public init(unofficialSources: QTUnofficialLyricsSources = .init(), translationLanguage: String? = nil,
                romanize: Bool = true, cacheLifetime: TimeInterval = 30 * 86_400,
                negativeCacheLifetime: TimeInterval = 3 * 86_400, partialCacheLifetime: TimeInterval = 3_600,
                fetchesPerProvider: Int = 2, versionsPerSource: Int = 3) {
        self.unofficialSources = unofficialSources
        self.translationLanguage = translationLanguage
        self.romanize = romanize
        self.cacheLifetime = cacheLifetime
        self.negativeCacheLifetime = negativeCacheLifetime
        self.partialCacheLifetime = partialCacheLifetime
        self.fetchesPerProvider = fetchesPerProvider
        self.versionsPerSource = versionsPerSource
    }

    /// From the app settings (translation target resolved against the interface language).
    public init(settings: QTSettings, interface: QTResolvedInterfaceLanguage) {
        self.init(unofficialSources: settings.unofficialLyricsSources,
                  translationLanguage: settings.lyricsTranslation.resolvedLanguage(interface: interface))
    }

    public func isEnabled(_ source: QTLyricsSource) -> Bool {
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

    /// - Parameters:
    ///   - configuration: sources + translation target for this lookup (default: the resolver's). Passing it per call
    ///     keeps a lookup consistent when settings change while another one is in flight (actor reentrancy).
    public func resolve(_ query: QTLyricsQuery, configuration: QTLyricsResolverConfiguration? = nil,
                        forceRefresh: Bool = false) async -> QTLyricsResolution {
        let config = configuration ?? self.configuration
        let pinned = await cache?.pinnedVersionID(for: query.videoId)
        // The pin is part of the key, so a pinned version that can't be fetched isn't retried on every call.
        let key = sourcesKey(config) + (pinned.map { "|pin:" + $0 } ?? "")
        if !forceRefresh, let entry = await cache?.entry(for: query.videoId), entry.sourcesKey == key,
           now().timeIntervalSince(entry.updated) < lifetime(of: entry, config) {
            return await present(entry, pinned: pinned != nil && pinned == entry.chosenID, fromCache: true, config)
        }
        var (entry, unreachable) = await lookup(query, pinned: pinned, config)
        entry.sourcesKey = key
        entry.isPartial = unreachable.isEmpty ? nil : true
        // Offline (or every source failing) is not "no lyrics": fall back to whatever was cached before (any source
        // configuration) and don't remember the miss.
        if entry.document == nil, !unreachable.isEmpty {
            if let previous = await cache?.entry(for: query.videoId), previous.document != nil {
                var r = await present(previous, pinned: pinned != nil && pinned == previous.chosenID, fromCache: true, config)
                r.unreachableSources = unreachable
                return r
            }
        } else {
            await cache?.store(entry)
        }
        var r = await present(entry, pinned: pinned != nil && pinned == entry.chosenID, fromCache: false, config)
        r.unreachableSources = unreachable
        return r
    }

    private func lifetime(of entry: QTLyricsCacheEntry, _ config: QTLyricsResolverConfiguration) -> TimeInterval {
        if entry.document == nil { return config.negativeCacheLifetime }
        return entry.isPartial == true ? config.partialCacheLifetime : config.cacheLifetime
    }

    /// Other versions found during the last lookup (resolving first if needed).
    public func versions(for query: QTLyricsQuery) async -> [QTResolvedLyricsVersion] {
        await resolve(query).versions
    }

    /// Pins a version for this track ("Wrong lyrics?" menu) and returns the new resolution.
    public func pin(versionID: String, for query: QTLyricsQuery,
                    configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.setPinnedVersionID(versionID, for: query.videoId)
        return await resolve(query, configuration: configuration, forceRefresh: true)
    }

    public func unpin(for query: QTLyricsQuery, configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.setPinnedVersionID(nil, for: query.videoId)
        return await resolve(query, configuration: configuration, forceRefresh: true)
    }

    /// The pinned version id for a track, if the user picked one.
    public func pinnedVersionID(for videoId: String) async -> String? {
        await cache?.pinnedVersionID(for: videoId)
    }

    /// Per-track offset in seconds (positive = lyrics earlier), persisted.
    public func offset(for videoId: String) async -> TimeInterval {
        await cache?.offset(for: videoId) ?? 0
    }

    public func setOffset(_ offset: TimeInterval, for videoId: String) async {
        await cache?.setOffset((offset * 10).rounded() / 10, for: videoId)
    }

    // MARK: Internals

    private func sourcesKey(_ config: QTLyricsResolverConfiguration) -> String {
        let enabled = providers.map(\.source).filter(config.isEnabled).map(\.id).sorted().joined(separator: ",")
        return enabled + "|" + (config.translationLanguage ?? "off") + "|" + (config.romanize ? "r" : "-")
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

    private func lookup(_ query: QTLyricsQuery, pinned: String?,
                        _ config: QTLyricsResolverConfiguration) async -> (QTLyricsCacheEntry, [QTLyricsSource]) {
        let active = providers.filter { config.isEnabled($0.source) }
        let scorer = QTLyricsMatchScorer(aliases: await aliasBook())
        let target = config.translationLanguage
        var unreachable: [QTLyricsSource] = []

        // 1. Search every enabled source in parallel; a failing source never fails the lookup.
        var found: [(QTLyricsCandidate, QTLyricsMatchScore)] = []
        await withTaskGroup(of: ([QTLyricsCandidate], QTLyricsSource?).self) { group in
            for provider in active {
                group.addTask {
                    do { return (try await provider.search(query), nil) } catch {
                        return ([], QTLyricsError.isUnreachable(error) ? provider.source : nil)
                    }
                }
            }
            for await (list, failed) in group {
                if let failed { unreachable.append(failed) }
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
            guard n < config.fetchesPerProvider || c.0.id == pinned else { return false }
            perProvider[c.0.source.id] = n + 1
            return true
        }
        var evaluated: [Evaluated] = []
        await withTaskGroup(of: (Evaluated?, QTLyricsSource?).self) { group in
            for (candidate, score) in toFetch {
                let provider = active.first { $0.source.id == candidate.source.id }!
                group.addTask {
                    let parsed: QTParsedLyrics?
                    do { parsed = try await provider.lyrics(for: candidate) } catch {
                        return (nil, QTLyricsError.isUnreachable(error) ? provider.source : nil)
                    }
                    guard let parsed, !parsed.isEmpty else { return (nil, nil) }
                    return (Evaluated(candidate: candidate, score: scorer.rescore(score, candidate: candidate, lyrics: parsed, for: query),
                                      parsed: parsed), nil)
                }
            }
            for await (e, failed) in group {
                if let e { evaluated.append(e) }
                if let failed, !unreachable.contains(failed) { unreachable.append(failed) }
            }
        }
        unreachable.sort { Self.sourcePriority($0) < Self.sourcePriority($1) }

        // 3. Pick: pinned (if it fetched) else the best acceptable by tier, sync kind, target translation, score.
        let usable = evaluated.filter { $0.score.isAcceptable(for: $0.candidate.source) || $0.candidate.id == pinned }
        let ranked = usable.sorted { a, b in
            Self.isRankedHigher(Self.rankKey(a.score.total, a.parsed.syncKind, hasLane(a.parsed, target), a.candidate.source),
                                Self.rankKey(b.score.total, b.parsed.syncKind, hasLane(b.parsed, target), b.candidate.source))
        }
        let chosen = ranked.first { $0.candidate.id == pinned } ?? ranked.first

        var versions = ranked.map {
            QTResolvedLyricsVersion(candidate: $0.candidate, score: $0.score.total, syncKind: $0.parsed.syncKind,
                                    hasTranslation: $0.parsed.lanes.contains { $0.kind == .translation },
                                    translationLanguage: $0.parsed.lanes.first { $0.kind == .translation }?.language)
        }
        // Candidates that were fetched but failed (empty, overrun, re-scored below threshold) are not offered.
        let fetchedIDs = Set(toFetch.map(\.0.id))
        versions += ordered.filter { !fetchedIDs.contains($0.0.id) }.map {
            QTResolvedLyricsVersion(candidate: $0.0, score: $0.1.total, syncKind: $0.0.syncHint, hasTranslation: false)
        }
        // "Other versions (n)" stays a short menu: the best few per source (the chosen and pinned ones always stay).
        var perSource: [String: Int] = [:]
        versions = versions.filter { v in
            let n = perSource[v.source.id, default: 0]
            perSource[v.source.id] = n + 1
            return n < config.versionsPerSource || v.id == chosen?.candidate.id || v.id == pinned
        }

        guard let chosen else {
            log.debug("no lyrics for \(query.videoId, privacy: .public)")
            return (QTLyricsCacheEntry(videoId: query.videoId, document: nil, versions: versions, chosenID: nil,
                                       attribution: nil, sourcesKey: sourcesKey(config), updated: now()), unreachable)
        }

        var document = QTLyricsAssembler.document(from: chosen.parsed, source: chosen.candidate.source,
                                                  confidence: chosen.candidate.id == pinned ? max(chosen.score.total, QTLyricsMatchThreshold.accept) : chosen.score.total,
                                                  preferredTranslationLanguage: target, romanize: config.romanize)

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
        return (QTLyricsCacheEntry(videoId: query.videoId, document: document, versions: versions,
                                   chosenID: chosen.candidate.id, attribution: chosen.parsed.metadata.attribution,
                                   sourcesKey: sourcesKey(config), updated: now()), unreachable)
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
    private func present(_ entry: QTLyricsCacheEntry, pinned: Bool, fromCache: Bool,
                         _ config: QTLyricsResolverConfiguration) async -> QTLyricsResolution {
        var full = entry.document
        full?.offset = await cache?.offset(for: entry.videoId) ?? 0
        let doc = full.map { QTLyricsTranslationPolicy.applyProviderLane(to: $0, target: config.translationLanguage) }
        return QTLyricsResolution(document: doc, fullDocument: full, versions: entry.versions, chosenID: entry.chosenID,
                                  isPinned: pinned, attribution: entry.attribution, fromCache: fromCache)
    }
}
