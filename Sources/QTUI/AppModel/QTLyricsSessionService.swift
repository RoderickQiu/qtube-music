import Foundation
import Observation
import OSLog
import QTCore
import QTInnerTube
import QTLyrics

// Owner: builder "lyrics-live". The one source of truth for lyrics in the app: every surface (docked panel, Stage,
// mini player, menu bar, desktop lyrics, options popover) reads the current track's lyrics from here — directly or
// through `QTPlayerModel.lyrics`, which forwards to it.

/// Lyrics for the playing track, resolved through the real provider chain (`QTLyricsResolver`: SQLite cache by
/// videoId first, then YouTube Music · AMLL · LRCLIB, plus NetEase · Kugou · QQ when the user opted in).
///
/// Mock-catalog tracks have no real videoId, so they are matched by title / artist / duration (YouTube Music is
/// skipped); when the sources can't be reached the bundled mock lyrics stand in, if their source is enabled.
/// All network and SQLite work runs off the main actor; this type only publishes results.
@MainActor
@Observable
public final class QTLyricsSession {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        /// Every enabled source answered and none has lyrics for this track.
        case notFound
        /// No lyrics, and some sources couldn't be reached (offline, rate-limited) — not remembered as "no lyrics".
        case unreachable
    }

    /// `-qt.lyrics.engine live|mock`.
    public enum Engine: String, Sendable {
        /// The provider chain (default).
        case live
        /// Only the mock catalog's bundled lyrics (deterministic screenshots, no network).
        case mock
    }

    // MARK: Published state

    public private(set) var track: QTTrack?
    public private(set) var phase: Phase = .idle
    /// What every surface shows: per-track offset applied, translation lane only when it is in the current target
    /// language (and the song isn't already in it), romanization lane when there is one.
    public private(set) var document: QTLyricsDocument?
    /// The chosen version with every provider lane kept (re-presented instantly when the target changes).
    public private(set) var fullDocument: QTLyricsDocument?
    /// Every version found ("Other versions (n)" lists all but the chosen one), best first.
    public private(set) var versions: [QTResolvedLyricsVersion] = []
    public private(set) var chosenVersionID: String?
    /// The user pinned `chosenVersionID` for this track (persisted).
    public private(set) var isPinned = false
    /// Provider credit, e.g. "Source: LyricFind" for YouTube Music lyrics.
    public private(set) var attribution: String?
    /// Enabled sources that didn't answer during the last lookup.
    public private(set) var unreachableSources: [QTLyricsSource] = []
    /// The bundled mock lyrics are shown because the sources couldn't be reached.
    public private(set) var isShowingFallback = false
    /// Where the translation line comes from for the current target.
    public private(set) var translationPlan: QTLyricsTranslationPlan = .none(.off)
    /// The resolved translation target (BCP-47), nil = Off.
    public private(set) var translationTarget: String?

    // MARK: Derived

    public var isLoading: Bool { phase == .loading }
    public var syncKind: QTLyricsSyncKind? { document?.syncKind }
    public var source: QTLyricsSource? { document?.source }
    /// Display name of the lyrics source ("NetEase", "YouTube Music"…); localise with `QTLoc.tr` where a key exists.
    public var sourceName: String? { document?.source.name }
    public var otherVersions: [QTResolvedLyricsVersion] { versions.filter { $0.id != chosenVersionID } }
    /// Match score 0.60–0.80: show the "possible mismatch" badge.
    public var isPossibleMismatch: Bool { (document?.confidence ?? 1) < QTLyricsMatchThreshold.accept }
    public var translationLanguage: String? { document?.translationLanguage }
    /// "NetEase", "Apple Intelligence", "On-device translation" — nil when there is no translation line.
    public var translationEngineName: String? {
        switch translationPlan {
        case .provider(let source): source.name
        case .engine(let kind): kind.source?.name
        case .none, .needsDownload: nil
        }
    }
    public var isAlreadyInTargetLanguage: Bool {
        if case .none(.alreadyInTargetLanguage) = translationPlan { return true }
        return false
    }
    public var romanizationSource: QTLyricsSource? { document?.romanizationSource }
    public var hasRomanization: Bool { document?.lines.contains { $0.romanization?.isEmpty == false } ?? false }
    /// Per-track offset in seconds (positive = lyrics earlier).
    public var offset: TimeInterval { document?.offset ?? 0 }
    /// The unofficial sources in effect (settings, or the session-only launch override).
    public var unofficialSources: QTUnofficialLyricsSources { settings.settings.unofficialLyricsSources }

    // MARK: Dependencies

    @ObservationIgnored public let engine: Engine
    @ObservationIgnored private let settings: QTSettingsStore
    @ObservationIgnored private let resolver: QTLyricsResolver
    @ObservationIgnored private let bundled: [String: QTLyricsDocument]
    @ObservationIgnored private let isMockTrack: @MainActor (QTTrack) -> Bool
    @ObservationIgnored private let versionStore: QTLyricsVersionStore?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastConfiguration: QTLyricsResolverConfiguration?
    /// Offsets nudged but not yet written (debounced), per videoId.
    @ObservationIgnored private var pendingOffsets: [String: TimeInterval] = [:]
    @ObservationIgnored private var offsetWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics-session")

    /// - Parameters:
    ///   - resolver: the engine (the app passes `QTLyricsResolver.standard(…)` over the on-disk cache).
    ///   - bundled: mock-catalog lyrics by videoId (offline fallback; the whole source in `.mock`).
    ///   - isMockTrack: tracks without a real YouTube videoId (matched by metadata only).
    ///   - versionStore: the options popover's "Other versions" model (nil in tests).
    public init(settings: QTSettingsStore, resolver: QTLyricsResolver, bundled: [String: QTLyricsDocument] = [:],
                engine: Engine = .live, isMockTrack: @escaping @MainActor (QTTrack) -> Bool = { _ in false },
                versionStore: QTLyricsVersionStore? = nil) {
        self.settings = settings
        self.resolver = resolver
        self.bundled = bundled
        self.engine = engine
        self.isMockTrack = isMockTrack
        self.versionStore = versionStore
        translationTarget = Self.target(settings)
        lastConfiguration = configuration
        versionStore?.onPin = { [weak self] videoId, version in
            guard let self, self.track?.videoId == videoId else { return }
            self.pin(versionID: version.id)
        }
        observeSettings()
    }

    /// The app's session: standard provider chain over the on-disk cache (Application Support/<bundle id>), the
    /// YouTube Music provider on `QTInnerTubeLyricsClient`, mock-catalog fallback.
    public static func makeDefault(settings: QTSettingsStore, catalog: QTMockCatalog,
                                   launch: QTLaunchOptions) -> QTLyricsSession {
        let cache: QTLyricsCache?
        switch launch.string("qt.lyrics.cache") {
        case "memory"?: cache = try? QTLyricsCache(url: nil)
        case let path?: cache = try? QTLyricsCache(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case nil: cache = try? QTLyricsCache(url: QTLyricsCache.defaultURL())
        }
        let offline = launch.bool("qt.lyrics.offline") == true
        let http: any QTLyricsHTTPClient = offline ? QTOfflineLyricsHTTPClient() : QTURLSessionLyricsHTTPClient()
        let hl = QTInnerTubeConfiguration.hl(for: QTLoc.language)
        // With the live library, lyrics requests follow the app client's hl / gl / visitor id (still anonymous: no
        // cookies, no SAPISIDHASH).
        let appClient = QTLiveCatalogStore.wantsLive(launch) && !offline ? QTLiveCatalogStore.shared.client : nil
        let innerTube = QTInnerTubeLyricsClient(client: appClient,
                                                transport: offline ? QTOfflineInnerTubeTransport() : QTURLSessionTransport(),
                                                hl: hl, gl: QTInnerTubeConfiguration.gl())
        let resolver = QTLyricsResolver.standard(cache: cache, http: http,
                                                 innerTube: QTInnerTubeLyricsBridge(client: innerTube))
        let mockIDs = Set(catalog.tracks.map(\.videoId))
        let engine = Engine(rawValue: launch.string("qt.lyrics.engine") ?? "") ?? .live
        return QTLyricsSession(settings: settings, resolver: resolver, bundled: catalog.lyrics, engine: engine,
                               isMockTrack: { mockIDs.contains($0.videoId) }, versionStore: .shared)
    }

    /// `-qt.lyrics.unofficial all|none|netease,kugou,qq` → a session-only override of Settings › Unofficial sources.
    public static func unofficialSources(argument: String?) -> QTUnofficialLyricsSources? {
        guard let argument = argument?.lowercased(), !argument.isEmpty else { return nil }
        switch argument {
        case "all", "yes", "on", "true": return .init(netease: true, kugou: true, qq: true)
        case "none", "no", "off", "false": return .init()
        default:
            let names = Set(argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            return .init(netease: names.contains("netease"), kugou: names.contains("kugou"), qq: names.contains("qq"))
        }
    }

    // MARK: Track changes

    /// Called on every track change (not on Song⇄Video switches of the same track).
    public func load(_ track: QTTrack?) {
        lookupTask?.cancel()
        generation += 1
        self.track = track
        document = nil
        fullDocument = nil
        versions = []
        chosenVersionID = nil
        isPinned = false
        attribution = nil
        unreachableSources = []
        isShowingFallback = false
        translationPlan = .none(translationTarget == nil ? .off : .noLyrics)
        guard let track else {
            phase = .idle
            return
        }
        phase = .loading
        run(for: track, holdsReadiness: true) { resolver, query, config in
            await resolver.resolve(query, configuration: config)
        }
    }

    /// Looks the track up again, skipping the cache.
    public func reload() {
        guard let track else { return }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.resolve(query, configuration: config, forceRefresh: true)
        }
    }

    // MARK: Versions

    /// "Wrong lyrics? / Other versions": shows `versionID` for this track from now on (persisted).
    public func pin(versionID: String) {
        guard let track, engine == .live else { return }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.pin(versionID: versionID, for: query, configuration: config)
        }
    }

    /// Back to the automatic pick.
    public func unpin() {
        guard let track, engine == .live else { return }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.unpin(for: query, configuration: config)
        }
    }

    // MARK: Timing

    /// ⌥↑ (+0.1, earlier) / ⌥↓ (-0.1, later); applied live, saved per track.
    public func nudgeOffset(by delta: TimeInterval) {
        guard document != nil else { return }
        setOffset(offset + delta)
    }

    public func setOffset(_ value: TimeInterval) {
        guard let videoId = track?.videoId, document != nil else { return }
        let rounded = (value * 10).rounded() / 10
        document?.offset = rounded
        fullDocument?.offset = rounded
        pendingOffsets[videoId] = rounded
        offsetWrites[videoId]?.cancel()
        let resolver = resolver
        offsetWrites[videoId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await resolver.setOffset(rounded, for: videoId)
            guard let self, self.pendingOffsets[videoId] == rounded else { return }
            self.pendingOffsets[videoId] = nil
            self.offsetWrites[videoId] = nil
        }
    }

    // MARK: Internals

    /// Sources + translation target from the settings (launch overrides included).
    public var configuration: QTLyricsResolverConfiguration {
        QTLyricsResolverConfiguration(unofficialSources: settings.settings.unofficialLyricsSources,
                                      translationLanguage: Self.target(settings))
    }

    private static func target(_ settings: QTSettingsStore) -> String? {
        settings.settings.lyricsTranslation.resolvedLanguage(interface: QTLoc.language)
    }

    /// The query for a track. Mock tracks carry no YouTube id, so YouTube Music isn't asked about them.
    func query(for track: QTTrack) -> QTLyricsQuery {
        var q = QTLyricsQuery(track: track)
        if isMockTrack(track) { q.lyricsVideoId = "" }
        return q
    }

    private func run(for track: QTTrack, holdsReadiness: Bool,
                     _ body: @escaping @Sendable (QTLyricsResolver, QTLyricsQuery, QTLyricsResolverConfiguration) async -> QTLyricsResolution) {
        lookupTask?.cancel()
        generation += 1
        let token = generation
        let config = configuration
        let query = query(for: track)
        let resolver = resolver
        let engine = engine
        let hold = holdsReadiness ? QTReadiness.shared.hold("lyrics \(track.videoId)") : nil
        lookupTask = Task { @MainActor [weak self] in
            defer { if let hold { QTReadiness.shared.release(hold) } }
            let resolution: QTLyricsResolution
            if engine == .mock {
                let offset = await resolver.offset(for: query.videoId)
                resolution = Self.bundledResolution(self?.bundled[track.videoId], offset: offset, config: config)
            } else {
                resolution = await body(resolver, query, config)
            }
            guard let self, !Task.isCancelled, token == self.generation, self.track?.videoId == track.videoId else { return }
            var r = resolution
            if r.document == nil, !r.isComplete, engine == .live, self.isMockTrack(track),
               let local = self.bundled[track.videoId], config.isEnabled(local.source) {
                let offset = await resolver.offset(for: query.videoId)
                guard token == self.generation else { return }
                var fallback = Self.bundledResolution(local, offset: offset, config: config)
                fallback.unreachableSources = r.unreachableSources
                r = fallback
                self.isShowingFallback = true
            } else {
                self.isShowingFallback = false
            }
            self.apply(r, for: track, config: config)
        }
    }

    private static func bundledResolution(_ doc: QTLyricsDocument?, offset: TimeInterval,
                                          config: QTLyricsResolverConfiguration) -> QTLyricsResolution {
        var full = doc
        full?.offset = offset
        let shown = full.map { QTLyricsTranslationPolicy.applyProviderLane(to: $0, target: config.translationLanguage) }
        return QTLyricsResolution(document: shown, fullDocument: full, versions: [], chosenID: nil, isPinned: false,
                                  attribution: nil, fromCache: true)
    }

    private func apply(_ r: QTLyricsResolution, for track: QTTrack, config: QTLyricsResolverConfiguration) {
        var shown = r.document
        var full = r.fullDocument
        // A nudge that hasn't been written yet wins over the stored offset.
        if let pending = pendingOffsets[track.videoId] {
            shown?.offset = pending
            full?.offset = pending
        }
        document = shown
        fullDocument = full
        versions = r.versions
        chosenVersionID = r.chosenID
        isPinned = r.isPinned
        attribution = r.attribution
        unreachableSources = r.unreachableSources
        translationTarget = config.translationLanguage
        translationPlan = QTLyricsTranslationPolicy.plan(for: full, target: config.translationLanguage)
        phase = shown != nil ? .loaded : (r.isComplete ? .notFound : .unreachable)
        lastConfiguration = config
        if engine == .live { publishVersions(for: track) }
        log.debug("lyrics \(track.videoId, privacy: .public): \(shown?.source.id ?? "none", privacy: .public) \(shown?.syncKind.rawValue ?? "-", privacy: .public) tr \(shown?.translationLanguage ?? "-", privacy: .public)")
    }

    /// Feeds the options popover's "Other versions (n)" menu.
    private func publishVersions(for track: QTTrack) {
        guard let versionStore else { return }
        let rows = versions.map {
            QTLyricsVersion(id: $0.id, source: $0.source, syncKind: $0.syncKind ?? .line,
                            translationLanguage: $0.translationLanguage, confidence: $0.score)
        }
        versionStore.publish(rows, for: track.videoId, selected: chosenVersionID)
    }

    // MARK: Settings

    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings.unofficialLyricsSources
            _ = settings.settings.lyricsTranslation
            _ = QTLoc.language
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.settingsDidChange()
                self?.observeSettings()
            }
        }
    }

    /// A new target re-presents the current version at once (provider lane kept or dropped), then looks up again in
    /// the background in case another version has a lane in that language. New sources look up again.
    func settingsDidChange() {
        let config = configuration
        guard config != lastConfiguration else { return }
        let sourcesChanged = config.unofficialSources != lastConfiguration?.unofficialSources
        lastConfiguration = config
        translationTarget = config.translationLanguage
        if let full = fullDocument {
            document = QTLyricsTranslationPolicy.applyProviderLane(to: full, target: config.translationLanguage)
        }
        translationPlan = QTLyricsTranslationPolicy.plan(for: fullDocument, target: config.translationLanguage)
        guard let track, engine == .live || sourcesChanged else { return }
        if document == nil { phase = .loading }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.resolve(query, configuration: config)
        }
    }
}

/// Lyrics HTTP client for `-qt.lyrics.offline YES`: every request fails as if the Mac were offline.
struct QTOfflineLyricsHTTPClient: QTLyricsHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw QTLyricsError.transport("offline (qt.lyrics.offline)")
    }
}

/// InnerTube transport for `-qt.lyrics.offline YES`.
struct QTOfflineInnerTubeTransport: QTHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
