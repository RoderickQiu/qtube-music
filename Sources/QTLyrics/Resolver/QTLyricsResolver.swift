import Foundation
import OSLog
import QTCore

/// A version of the lyrics for the "Lyrics Source" menu. (Named apart from the UI's `QTLyricsVersion` row model in
/// QTUI so the two never shadow each other.)
public struct QTResolvedLyricsVersion: Sendable, Hashable, Codable, Identifiable {
    /// `candidate.duration` is the length the version is timed for (the payload's own when the search had none).
    public var candidate: QTLyricsCandidate
    /// Match score 0…1 (after fetching, when fetched).
    public var score: Double
    /// Known after fetching; otherwise the provider's hint.
    public var syncKind: QTLyricsSyncKind?
    public var hasTranslation: Bool
    /// Language of the version's own translation lane (known after fetching).
    public var translationLanguage: String?
    /// Sanity checks the fetched text failed (nil in entries cached before they existed, and for unfetched versions).
    public var flags: [QTLyricsMatchFlag]?
    /// The user reported it ("Report Wrong Lyrics"): never chosen automatically, listed last so the report can be
    /// taken back by picking it (nil = not reported).
    public var isReported: Bool?
    /// `QTLyricsSanity.fingerprint` of the fetched words (nil when unfetched or too short): the menu shows one row for
    /// versions of one source with the same words.
    public var textFingerprint: String?

    public init(candidate: QTLyricsCandidate, score: Double, syncKind: QTLyricsSyncKind?, hasTranslation: Bool,
                translationLanguage: String? = nil, flags: [QTLyricsMatchFlag]? = nil, isReported: Bool? = nil,
                textFingerprint: String? = nil) {
        self.candidate = candidate
        self.score = score
        self.syncKind = syncKind
        self.hasTranslation = hasTranslation
        self.translationLanguage = translationLanguage
        self.flags = flags
        self.isReported = isReported
        self.textFingerprint = textFingerprint
    }
    public var id: String { candidate.id }
    public var source: QTLyricsSource { candidate.source }
    public var duration: TimeInterval? { candidate.duration }
    /// Score 0.60–0.80, or a failed sanity check that counts on its own (`QTLyricsMatchFlag.forcesBadge`): shown with
    /// a "Possible mismatch" badge.
    public var isPossibleMismatch: Bool {
        score < QTLyricsMatchThreshold.accept || flags?.contains(where: \.forcesBadge) == true
    }
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
    /// The user's stored choice for this track: a version id, or `QTLyricsCache.noLyricsPin`. It may differ from
    /// `chosenID` when the pinned version can't be fetched any more (the automatic pick shows meanwhile).
    public var pinnedID: String?
    /// A choice is stored (`pinnedID` != nil), so the menu shows it and Automatic can clear it.
    public var isPinned: Bool { pinnedID != nil }
    /// "Source: LyricFind" for YouTube Music lyrics.
    public var attribution: String?
    public var fromCache: Bool
    /// Enabled sources that couldn't be reached (offline, timed out, rate-limited, 5xx). A lookup with no lyrics and
    /// unreachable sources is not remembered as "no lyrics".
    public var unreachableSources: [QTLyricsSource]
    /// "No Lyrics for This Song": the user turned lyrics off for this track (no document; `versions` still listed so
    /// they can pick one or go back to Automatic).
    public var isLyricsOff: Bool

    public init(document: QTLyricsDocument?, fullDocument: QTLyricsDocument? = nil, versions: [QTResolvedLyricsVersion],
                chosenID: String?, pinnedID: String? = nil, attribution: String?, fromCache: Bool,
                unreachableSources: [QTLyricsSource] = [], isLyricsOff: Bool = false) {
        self.document = document
        self.fullDocument = fullDocument ?? document
        self.versions = versions
        self.chosenID = chosenID
        self.pinnedID = pinnedID
        self.attribution = attribution
        self.fromCache = fromCache
        self.unreachableSources = unreachableSources
        self.isLyricsOff = isLyricsOff
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
    /// Versions offered per source in the "Lyrics Source" menu.
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
/// sources; text already served for other songs skipped) → second-source translation lane after alignment → SQLite
/// cache keyed by videoId, with per-version offsets, pinned versions ("none" = lyrics off), reported versions and
/// alias learning. Conforms to `QTLyricsProviding`, the protocol the UI uses.
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
        let stored = await cache?.pinnedVersionID(for: query.videoId)
        // "No Lyrics for This Song" hides what is found; the lookup still runs so the menu can offer the versions.
        let lyricsOff = stored == QTLyricsCache.noLyricsPin
        // Imported lyrics aren't looked up: the sources' own pick is found (and cached) beside them.
        let pinned = lyricsOff || stored == QTImportedLyrics.versionID ? nil : stored
        // The pin is part of the key, so a pinned version that can't be fetched isn't retried on every call.
        let key = sourcesKey(config) + (pinned.map { "|pin:" + $0 } ?? "")
        if !forceRefresh, let entry = await cache?.entry(for: query.videoId), entry.sourcesKey == key,
           now().timeIntervalSince(entry.updated) < lifetime(of: entry, config) {
            return await present(entry, pin: stored, fromCache: true, config)
        }
        let rejected = await cache?.rejectedVersionIDs(for: query.videoId) ?? []
        var (entry, unreachable) = await lookup(query, pinned: pinned, rejected: rejected, config)
        entry.sourcesKey = key
        entry.isPartial = unreachable.isEmpty ? nil : true
        // Offline (or every source failing) is not "no lyrics": fall back to whatever was cached before (any source
        // configuration, unless the user has since reported it) and don't remember the miss.
        if entry.document == nil, !unreachable.isEmpty {
            if let previous = await cache?.entry(for: query.videoId), previous.document != nil,
               !rejected.contains(previous.chosenID ?? "") {
                var r = await present(previous, pin: stored, fromCache: true, config)
                r.unreachableSources = unreachable
                return r
            }
        } else {
            await cache?.store(entry)
        }
        var r = await present(entry, pin: stored, fromCache: false, config)
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

    /// Pins a version for this track ("Lyrics Source" menu) and returns the new resolution. Picking a version the
    /// user once reported takes the report back.
    public func pin(versionID: String, for query: QTLyricsQuery,
                    configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.removeRejection(versionID, for: query.videoId)
        await takeBackReportedText(of: versionID, videoId: query.videoId)
        await cache?.setPinnedVersionID(versionID, for: query.videoId)
        return await resolve(query, configuration: configuration, forceRefresh: true)
    }

    /// "Automatic": back to the resolver's own pick, whatever was stored (a pinned version that can't be fetched any
    /// more included).
    public func unpin(for query: QTLyricsQuery, configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        let stored = await cache?.pinnedVersionID(for: query.videoId)
        await cache?.setPinnedVersionID(nil, for: query.videoId)
        // Nothing was pinned, or lyrics were only hidden: the automatic pick is still cached, no new lookup.
        return await resolve(query, configuration: configuration,
                             forceRefresh: stored != nil && stored != QTLyricsCache.noLyricsPin)
    }

    /// "No Lyrics for This Song": hides lyrics for this track from now on (persisted) until a version or Automatic
    /// is picked again.
    public func turnOffLyrics(for query: QTLyricsQuery, configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.setPinnedVersionID(QTLyricsCache.noLyricsPin, for: query.videoId)
        return await resolve(query, configuration: configuration)
    }

    /// "Report Wrong Lyrics": this version is never chosen for this track again (kept on this Mac, never sent
    /// anywhere; listed last as reported, so picking it takes the report back), and the next best version is shown
    /// at once. A pin on it is dropped, and so is its text's fingerprint (it was no song's lyrics).
    public func reject(versionID: String, for query: QTLyricsQuery,
                       configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.addRejection(versionID, for: query.videoId)
        // The same words from another entry of a source (sources list a song more than once) are just as wrong.
        if let text = await reportedTextKey(of: versionID, videoId: query.videoId) {
            await cache?.addRejection(text, for: query.videoId)
        }
        if await cache?.pinnedVersionID(for: query.videoId) == versionID {
            await cache?.setPinnedVersionID(nil, for: query.videoId)
        }
        await cache?.clearFingerprints(for: query.videoId)
        return await resolve(query, configuration: configuration, forceRefresh: true)
    }

    /// Undo for a report: takes it back and restores the pin the report dropped.
    public func undoReject(versionID: String, wasPinned: Bool, for query: QTLyricsQuery,
                           configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.removeRejection(versionID, for: query.videoId)
        await takeBackReportedText(of: versionID, videoId: query.videoId)
        if wasPinned { await cache?.setPinnedVersionID(versionID, for: query.videoId) }
        return await resolve(query, configuration: configuration, forceRefresh: true)
    }

    // MARK: Imported lyrics

    /// "Import Lyrics…": shows the file's lyrics for this track from now on (pinned; a file imported before is
    /// replaced). nil when the file holds no lyrics (nothing changes then).
    public func importLyrics(_ imported: QTImportedLyrics, for query: QTLyricsQuery,
                             configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution? {
        guard imported.parsed != nil, let cache, let data = try? JSONEncoder().encode(imported) else { return nil }
        await cache.setBlob(data, named: QTImportedLyrics.blobName(query.videoId))
        await cache.setPinnedVersionID(QTImportedLyrics.versionID, for: query.videoId)
        return await resolve(query, configuration: configuration)
    }

    /// Deletes the file imported for this track; the automatic pick shows again when it was showing.
    public func removeImportedLyrics(for query: QTLyricsQuery,
                                     configuration: QTLyricsResolverConfiguration? = nil) async -> QTLyricsResolution {
        await cache?.removeBlob(named: QTImportedLyrics.blobName(query.videoId))
        if await cache?.pinnedVersionID(for: query.videoId) == QTImportedLyrics.versionID {
            await cache?.setPinnedVersionID(nil, for: query.videoId)
        }
        return await resolve(query, configuration: configuration)
    }

    /// The file imported for a track, as a document for this lookup's settings and its "Lyrics Source" version.
    private func imported(for videoId: String, _ config: QTLyricsResolverConfiguration)
        async -> (version: QTResolvedLyricsVersion, document: QTLyricsDocument)? {
        guard let data = await cache?.blob(named: QTImportedLyrics.blobName(videoId))?.data,
              let file = try? JSONDecoder().decode(QTImportedLyrics.self, from: data), let parsed = file.parsed else { return nil }
        let doc = QTLyricsAssembler.document(from: parsed, source: .imported, confidence: 1,
                                             preferredTranslationLanguage: config.translationLanguage, romanize: config.romanize)
        return (file.version(doc), doc)
    }

    /// The pinned version id for a track, if the user picked one (`QTLyricsCache.noLyricsPin` = lyrics off).
    public func pinnedVersionID(for videoId: String) async -> String? {
        await cache?.pinnedVersionID(for: videoId)
    }

    /// Offset in seconds (positive = lyrics earlier) of one version of a track's lyrics, persisted. Versions are
    /// timed independently, so each keeps its own.
    public func offset(for videoId: String, version: String) async -> TimeInterval {
        await cache?.offset(for: videoId, version: version) ?? 0
    }

    public func setOffset(_ offset: TimeInterval, for videoId: String, version: String) async {
        await cache?.setOffset((offset * 10).rounded() / 10, for: videoId, version: version)
    }

    // MARK: Internals

    /// Reported words are stored next to the reported version ids, as `text:<source id>:<fingerprint>`: only that
    /// source's other entries with those words are covered (a report may be about one source's timing or
    /// translation, so the same words from another source stay eligible).
    static let rejectedTextPrefix = "text:"

    static func reportedTextKey(source: String, fingerprint: String) -> String {
        rejectedTextPrefix + source + ":" + fingerprint
    }

    /// Takes back the report of a version's words. A reported version isn't fetched again, so its words are often
    /// unknown by then: the track's reported words all go (the reported version ids themselves stay).
    private func takeBackReportedText(of versionID: String, videoId: String) async {
        if let text = await reportedTextKey(of: versionID, videoId: videoId) {
            await cache?.removeRejection(text, for: videoId)
            return
        }
        for id in await cache?.rejectedVersionIDs(for: videoId) ?? [] where id.hasPrefix(Self.rejectedTextPrefix) {
            await cache?.removeRejection(id, for: videoId)
        }
    }

    /// The fingerprint of a version's words, from the last lookup's versions (nil when it wasn't fetched).
    private func reportedTextKey(of versionID: String, videoId: String) async -> String? {
        guard let v = await cache?.entry(for: videoId)?.versions.first(where: { $0.id == versionID }),
              let fingerprint = v.textFingerprint else { return nil }
        return Self.reportedTextKey(source: v.source.id, fingerprint: fingerprint)
    }

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

    private func lookup(_ query: QTLyricsQuery, pinned: String?, rejected: Set<String>,
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

        // 2. Fetch the most promising candidates (pinned first), a few per provider. Versions the user reported are
        //    never fetched or chosen again; they are listed last, so the report can be taken back.
        let acceptable = found.filter {
            ($0.1.isAcceptable(for: $0.0.source) && !rejected.contains($0.0.id)) || $0.0.id == pinned
        }
        var reported: [String: (QTLyricsCandidate, QTLyricsMatchScore)] = [:]
        for (c, s) in found where rejected.contains(c.id) && c.id != pinned && s.isAcceptable(for: c.source) {
            if reported[c.id].map({ $0.1.total < s.total }) ?? true { reported[c.id] = (c, s) }
        }
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
        // Ending early is judged against the other versions: when none of them is sung past 40 % either, the song
        // just ends instrumental (long outro, extended mix) and that is no sign of a mismatch.
        if !evaluated.contains(where: { $0.parsed.syncKind != .plain && !$0.score.flags.contains(.lowCoverage) }) {
            for i in evaluated.indices where evaluated[i].score.flags.contains(.lowCoverage) {
                evaluated[i].score.flags.remove(.lowCoverage)
                evaluated[i].score.sanityPenalty = QTLyricsSanity.penalty(for: evaluated[i].score.flags)
            }
        }
        // An unofficial version that can't show its recording's length is kept only when no other version is there
        // for the song (then it may be all there is: a penalty and a badge, not a rejection).
        if evaluated.contains(where: { !$0.score.flags.contains(.unknownLength) && $0.score.isAcceptable(for: $0.candidate.source) }) {
            evaluated.removeAll { $0.score.flags.contains(.unknownLength) && $0.candidate.id != pinned }
        }

        // 3. Pick: pinned (if it fetched) else the best acceptable by tier, sync kind, target translation, score.
        let usable = evaluated.filter { $0.score.isAcceptable(for: $0.candidate.source) || $0.candidate.id == pinned }
        var ranked = usable.sorted { a, b in
            let ka = Self.rankKey(a.score.total, a.parsed.syncKind, hasLane(a.parsed, target), a.candidate.source)
            let kb = Self.rankKey(b.score.total, b.parsed.syncKind, hasLane(b.parsed, target), b.candidate.source)
            // Ties go by id, so the automatic pick doesn't depend on which fetch finished first.
            return ka == kb ? a.candidate.id < b.candidate.id : Self.isRankedHigher(ka, kb)
        }
        // Same text for different songs: a text already chosen for other songs (titles and artists not alike —
        // covers, re-releases and translated titles share lyrics) is a source's filler, not this song's lyrics. Never
        // picked automatically; listed after the others with a "Possible mismatch" badge, so it can still be picked.
        var shared: Set<String> = []
        for i in ranked.indices {
            guard let fingerprint = QTLyricsSanity.fingerprint(ranked[i].parsed),
                  await sharesText(fingerprint, with: query, scorer: scorer) else { continue }
            log.debug("same text as other songs: \(ranked[i].candidate.id, privacy: .public)")
            shared.insert(ranked[i].candidate.id)
            ranked[i].score.flags.insert(.sharedText)
            ranked[i].score.sanityPenalty = QTLyricsSanity.penalty(for: ranked[i].score.flags)
        }
        ranked = ranked.filter { !shared.contains($0.candidate.id) } + ranked.filter { shared.contains($0.candidate.id) }
        // Words the user reported for this track, fetched again from the same source under another entry id: never
        // picked automatically, and listed as reported (picking one takes the report back).
        let reportedText = Set(ranked.filter { e in
            e.candidate.id != pinned && QTLyricsSanity.fingerprint(e.parsed).map {
                rejected.contains(Self.reportedTextKey(source: e.candidate.source.id, fingerprint: $0))
            } == true
        }.map(\.candidate.id))
        let chosen = ranked.first { $0.candidate.id == pinned }
            ?? ranked.first { !shared.contains($0.candidate.id) && !reportedText.contains($0.candidate.id) }
        // Only the text actually shown counts as this song's (one per track). A lookup that couldn't reach every
        // source leaves the last one alone.
        if let chosen, let fingerprint = QTLyricsSanity.fingerprint(chosen.parsed) {
            await cache?.recordFingerprint(fingerprint, videoId: query.videoId, title: query.title, artist: query.artistLine)
        } else if chosen != nil || unreachable.isEmpty {
            await cache?.clearFingerprints(for: query.videoId)
        }

        var versions = ranked.filter { !reportedText.contains($0.candidate.id) }.map { e in
            var candidate = e.candidate
            if (candidate.duration ?? 0) <= 0 { candidate.duration = e.parsed.metadata.length }
            return QTResolvedLyricsVersion(candidate: candidate, score: e.score.total, syncKind: e.parsed.syncKind,
                                           hasTranslation: e.parsed.lanes.contains { $0.kind == .translation },
                                           translationLanguage: e.parsed.lanes.first { $0.kind == .translation }?.language,
                                           flags: QTLyricsMatchFlag.allCases.filter(e.score.flags.contains),
                                           textFingerprint: QTLyricsSanity.fingerprint(e.parsed))
        }
        // Candidates that were fetched but failed (empty, overrun, re-scored below threshold) are not offered.
        let fetchedIDs = Set(toFetch.map(\.0.id))
        versions += ordered.filter { !fetchedIDs.contains($0.0.id) }.map {
            QTResolvedLyricsVersion(candidate: $0.0, score: $0.1.total, syncKind: $0.0.syncHint, hasTranslation: false)
        }
        // The "Lyrics Source" menu stays short: the best few per source (the chosen and pinned ones always stay).
        var perSource: [String: Int] = [:]
        versions = versions.filter { v in
            let n = perSource[v.source.id, default: 0]
            perSource[v.source.id] = n + 1
            return n < config.versionsPerSource || v.id == chosen?.candidate.id || v.id == pinned
        }
        versions += ranked.filter { reportedText.contains($0.candidate.id) }.map { e in
            QTResolvedLyricsVersion(candidate: e.candidate, score: e.score.total, syncKind: e.parsed.syncKind,
                                    hasTranslation: false, isReported: true, textFingerprint: QTLyricsSanity.fingerprint(e.parsed))
        }
        versions += reported.values.sorted { $0.1.total == $1.1.total ? $0.0.id < $1.0.id : $0.1.total > $1.1.total }.map {
            QTResolvedLyricsVersion(candidate: $0.0, score: $0.1.total, syncKind: $0.0.syncHint, hasTranslation: false, isReported: true)
        }

        guard let chosen else {
            log.debug("no lyrics for \(query.videoId, privacy: .public)")
            return (QTLyricsCacheEntry(videoId: query.videoId, document: nil, versions: versions, chosenID: nil,
                                       attribution: nil, sourcesKey: sourcesKey(config), updated: now()), unreachable)
        }

        // A version the user picked shows no badge; one that failed a sanity check that counts on its own always
        // shows "Possible mismatch".
        let confidence = chosen.candidate.id == pinned ? max(chosen.score.total, QTLyricsMatchThreshold.accept)
            : !chosen.score.flags.contains(where: \.forcesBadge) ? chosen.score.total
            : min(chosen.score.total, QTLyricsMatchThreshold.accept - 0.01)
        var document = QTLyricsAssembler.document(from: chosen.parsed, source: chosen.candidate.source, confidence: confidence,
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

    /// True when this text was chosen for at least `QTLyricsSanity.sharedTextSongs` other songs — other titles than
    /// this one's, by other artists than this one's and than each other's (counted once per title and per artist:
    /// two uploads of one song are one song; one artist's song under two titles is one artist).
    private func sharesText(_ fingerprint: String, with query: QTLyricsQuery, scorer: QTLyricsMatchScorer) async -> Bool {
        var titles: [String] = []
        var artists: [String] = []
        for other in await cache?.fingerprintTracks(fingerprint, excluding: query.videoId) ?? [] {
            guard !QTLyricsSanity.isSameSong(other.title, query.title, scorer: scorer),
                  !QTLyricsSanity.isSameArtist(other.artist, query.artistLine, scorer: scorer) else { continue }
            if !titles.contains(where: { QTLyricsSanity.isSameSong($0, other.title, scorer: scorer) }) { titles.append(other.title) }
            if !artists.contains(where: { QTLyricsSanity.isSameArtist($0, other.artist, scorer: scorer) }) { artists.append(other.artist) }
        }
        return titles.count >= QTLyricsSanity.sharedTextSongs && artists.count >= QTLyricsSanity.sharedTextSongs
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

    /// Applies the chosen version's offset and the translation policy for the current target; hides the lyrics when
    /// the user turned them off for this track.
    /// - Parameter pin: the stored choice (a version id, `QTLyricsCache.noLyricsPin`, or nil for Automatic).
    private func present(_ entry: QTLyricsCacheEntry, pin: String?, fromCache: Bool,
                         _ config: QTLyricsResolverConfiguration) async -> QTLyricsResolution {
        // A file the user imported for this track is listed first, and shows while it is pinned.
        let imported = await imported(for: entry.videoId, config)
        let versions = (imported.map { [$0.version] } ?? []) + entry.versions
        if pin == QTLyricsCache.noLyricsPin {
            return QTLyricsResolution(document: nil, versions: versions, chosenID: nil, pinnedID: pin,
                                      attribution: nil, fromCache: fromCache, isLyricsOff: true)
        }
        let showsImported = pin == QTImportedLyrics.versionID && imported != nil
        let chosenID = showsImported ? QTImportedLyrics.versionID : entry.chosenID
        var full = showsImported ? imported?.document : entry.document
        // Entries cached before the LRC parser flattened NetEase's JSON credit lines still hold them as lyrics.
        full?.lines.removeAll { QTLRCParser.jsonCreditText(Substring($0.text)).map(QTLyricsCleanup.isCredit) == true }
        if full != nil { full?.offset = await cache?.offset(for: entry.videoId, version: chosenID ?? "") ?? 0 }
        let doc = full.map { QTLyricsTranslationPolicy.applyProviderLane(to: $0, target: config.translationLanguage) }
        return QTLyricsResolution(document: doc, fullDocument: full, versions: versions, chosenID: chosenID,
                                  pinnedID: pin, attribution: showsImported ? nil : entry.attribution, fromCache: fromCache)
    }
}
