import Foundation
import Network
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
    /// Every version found (the "Lyrics Source" menu), best first.
    public private(set) var versions: [QTResolvedLyricsVersion] = []
    public private(set) var chosenVersionID: String?
    /// The user's stored choice for this track: a version id (possibly one that wasn't found this time, while the
    /// automatic pick shows), or `QTLyricsCache.noLyricsPin`. nil = Automatic.
    public private(set) var pinnedVersionID: String?
    /// The user pinned a version for this track, or turned lyrics off for it (persisted).
    public var isPinned: Bool { pinnedVersionID != nil }
    /// "No Lyrics for This Song" is chosen for this track (persisted): no document, `versions` still listed.
    public private(set) var isLyricsOff = false
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
    /// The Mac has a network path (NWPathMonitor; `-qt.lyrics.offline YES` pretends it hasn't). With `phase ==
    /// .unreachable` this tells "Offline" apart from "the sources didn't answer".
    public private(set) var isNetworkAvailable = true
    /// The rendition playing (Song⇄Video), when the lyrics know it. A counterpart of another length gets lyrics
    /// timed for its own cut, or unsynced lyrics — never the track's, drifting.
    public private(set) var rendition: QTLyricsRendition?
    /// How the shown lyrics relate to the playing rendition.
    public private(set) var renditionTiming: QTLyricsRenditionDisplay = .base

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
    /// Offsets are kept per version; the bundled mock lyrics (mock engine, offline fallback) count as one.
    static let bundledVersionID = "bundled"

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
    /// Offsets nudged but not yet written (debounced), per `offsetKey` (videoId + version).
    @ObservationIgnored private var pendingOffsets: [String: TimeInterval] = [:]
    /// The version the track's own lyrics come from (`chosenVersionID`, or `bundledVersionID`): their offset's key.
    @ObservationIgnored private var baseVersionID: String?
    @ObservationIgnored private var offsetWrites: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics-session")
    @ObservationIgnored private var networkMonitor: QTLyricsNetworkMonitor?
    @ObservationIgnored private var lastRetry: Date?
    /// The track's own lyrics (timed for the track's duration) and, for a counterpart of another length, the lookup
    /// for that cut. `document` / `fullDocument` publish whichever the rendition shows.
    @ObservationIgnored private var baseShown: QTLyricsDocument?
    @ObservationIgnored private var baseFull: QTLyricsDocument?
    @ObservationIgnored private var own: QTLyricsRenditionLookup?
    @ObservationIgnored private var ownTask: Task<Void, Never>?
    /// Per track: the counterpart's lyric shift (counterpart lyric time − song lyric time), when both timings agree
    /// on one. Maps the position across Song⇄Video switches.
    @ObservationIgnored private var shifts: [String: QTLyricsRenditionShift] = [:]
    /// Bumped when a shift becomes known (the rendition coordinator re-checks a switch that went unmapped).
    public private(set) var shiftGeneration = 0
    /// The last "Report Wrong Lyrics", for the toast's Undo: which lookup it acted on (the track's own, or the
    /// counterpart cut's key) and whether the version was pinned.
    @ObservationIgnored private var lastReport: (videoId: String, ownKey: String?, versionID: String, wasPinned: Bool)?

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
        versionStore?.onUnpin = { [weak self] videoId in
            guard let self, self.track?.videoId == videoId else { return }
            self.unpin()
        }
        versionStore?.onLyricsOff = { [weak self] videoId in
            guard let self, self.track?.videoId == videoId else { return }
            self.turnOffLyrics()
        }
        versionStore?.onReport = { [weak self] videoId, versionID in
            guard let self, self.track?.videoId == videoId else { return false }
            return self.reportWrong(versionID: versionID)
        }
        versionStore?.onUndoReport = { [weak self] videoId, versionID in
            guard let self, self.track?.videoId == videoId else { return }
            self.undoReport(versionID: versionID)
        }
        observeSettings()
    }

    /// The app's session: standard provider chain over the on-disk cache (Application Support/<bundle id>), the
    /// YouTube Music provider on `QTInnerTubeLyricsClient`, mock-catalog fallback.
    public static func makeDefault(settings: QTSettingsStore, catalog: QTMockCatalog,
                                   launch: QTLaunchOptions) -> QTLyricsSession {
        var cache: QTLyricsCache?
        switch launch.string("qt.lyrics.cache") {
        case "memory"?: cache = try? QTLyricsCache(url: nil)
        case let path?: cache = try? QTLyricsCache(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case nil: cache = try? QTLyricsCache(url: QTLyricsCache.defaultURL())
        }
        // A file that can't be opened at all (a failed migration alone never stops it) still leaves this session
        // with a working cache: pins, reports and offsets hold until quit.
        if cache == nil {
            Logger(subsystem: "com.roderickqiu.qtube", category: "lyrics-session").error("lyrics cache unavailable; using memory")
            cache = try? QTLyricsCache(url: nil)
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
        // Machine translations are cached in the same SQLite file, per lyrics + language + engine.
        QTLyricsTranslationCenter.shared.attach(settings: settings, cache: cache)
        let session = QTLyricsSession(settings: settings, resolver: resolver, bundled: catalog.lyrics, engine: engine,
                                      isMockTrack: { mockIDs.contains($0.videoId) }, versionStore: .shared)
        if offline {
            session.isNetworkAvailable = false
        } else if engine == .live {
            session.startNetworkMonitor()
        }
        return session
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
        baseShown = nil
        baseFull = nil
        ownTask?.cancel()
        own = nil
        rendition = nil
        renditionTiming = .base
        versions = []
        chosenVersionID = nil
        baseVersionID = nil
        pinnedVersionID = nil
        isLyricsOff = false
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

    // MARK: Offline

    /// Watches the network path and looks the track up again when the Mac comes back online.
    func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        networkMonitor = QTLyricsNetworkMonitor { [weak self] available in self?.networkDidChange(available: available) }
    }

    /// Network path changed. Coming back online retries a lookup that failed because the sources were unreachable.
    public func networkDidChange(available: Bool) {
        let cameBack = available && !isNetworkAvailable
        isNetworkAvailable = available
        if cameBack { retryIfUnreachable(force: true) }
    }

    /// Retries the lookup when the last one couldn't reach the sources (offline, rate-limited): on reconnect, and
    /// when a lyrics surface opens again for the same track. Throttled to one attempt every few seconds unless forced.
    public func retryIfUnreachable(force: Bool = false) {
        guard phase == .unreachable, let track, engine == .live else { return }
        if !force, let lastRetry, Date().timeIntervalSince(lastRetry) < 5 { return }
        lastRetry = Date()
        phase = .loading
        run(for: track, holdsReadiness: false) { resolver, query, config in
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

    // The "Lyrics Source" menu lists the versions of the lyrics showing: in video mode with lyrics timed for the
    // video's own cut, those of that cut's lookup (`own`), so a pick or a report acts on what is on screen. "No Lyrics
    // for This Song" is about the song and always goes to the track's own lookup.

    /// The counterpart cut's lookup, when its lyrics are the ones showing.
    private var shownOwn: QTLyricsRenditionLookup? {
        guard renditionTiming == .own, let own, own.query != nil else { return nil }
        return own
    }

    /// "Lyrics Source": shows `versionID` for this track from now on (persisted).
    public func pin(versionID: String) {
        guard let track, engine == .live else { return }
        if let own = shownOwn {
            return runOwn(own, for: track) { resolver, query, config in
                await resolver.pin(versionID: versionID, for: query, configuration: config)
            }
        }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.pin(versionID: versionID, for: query, configuration: config)
        }
    }

    /// Back to the automatic pick.
    public func unpin() {
        guard let track, engine == .live else { return }
        if let own = shownOwn {
            return runOwn(own, for: track) { resolver, query, config in
                await resolver.unpin(for: query, configuration: config)
            }
        }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.unpin(for: query, configuration: config)
        }
    }

    /// "No Lyrics for This Song": hides lyrics for this track from now on (persisted).
    public func turnOffLyrics() {
        guard let track, engine == .live else { return }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.turnOffLyrics(for: query, configuration: config)
        }
    }

    /// A file was imported for this track ("Remove Imported Lyrics").
    public var hasImportedLyrics: Bool { versions.contains { $0.source == .imported } }

    /// "Import Lyrics…" / a lyrics file dropped on the lyrics: shows the file's lyrics for this track from now on
    /// (pinned, kept on this Mac). False when there is no track or the file holds no lyrics.
    public func importLyrics(_ file: QTImportedLyrics) -> Bool {
        guard let track, engine == .live, file.parsed != nil else { return false }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            if let r = await resolver.importLyrics(file, for: query, configuration: config) { return r }
            return await resolver.resolve(query, configuration: config)
        }
        return true
    }

    public func removeImportedLyrics() {
        guard let track, engine == .live else { return }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.removeImportedLyrics(for: query, configuration: config)
        }
    }

    /// "Report Wrong Lyrics" (the version showing by default): never chosen for this track again — remembered on this
    /// Mac, never sent anywhere — and the next best version replaces it at once. False when there is nothing to
    /// report (no version showing, the bundled demo lyrics).
    @discardableResult
    public func reportWrong(versionID: String? = nil) -> Bool {
        guard let track, engine == .live else { return false }
        if let own = shownOwn {
            guard let id = versionID ?? own.version else { return false }
            lastReport = (track.videoId, own.key, id, own.pinnedID == id)
            runOwn(own, for: track) { resolver, query, config in
                await resolver.reject(versionID: id, for: query, configuration: config)
            }
            return true
        }
        guard let id = versionID ?? chosenVersionID else { return false }
        lastReport = (track.videoId, nil, id, pinnedVersionID == id)
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.reject(versionID: id, for: query, configuration: config)
        }
        return true
    }

    /// Undo on the "Reported" toast: takes the last report back (and the pin it dropped) and shows that version
    /// again, if it is still about the lyrics this track shows.
    public func undoReport(versionID: String) {
        guard let track, engine == .live, let report = lastReport, report.videoId == track.videoId,
              report.versionID == versionID else { return }
        lastReport = nil
        let pinned = report.wasPinned
        if let key = report.ownKey {
            guard let own, own.key == key else { return }
            return runOwn(own, for: track) { resolver, query, config in
                await resolver.undoReject(versionID: versionID, wasPinned: pinned, for: query, configuration: config)
            }
        }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.undoReject(versionID: versionID, wasPinned: pinned, for: query, configuration: config)
        }
    }

    // MARK: Timing

    /// ⌥↑ (+0.1, earlier) / ⌥↓ (-0.1, later); applied live, saved per track and version.
    public func nudgeOffset(by delta: TimeInterval) {
        guard document != nil else { return }
        setOffset(offset + delta)
    }

    public func setOffset(_ value: TimeInterval) {
        guard let trackID = track?.videoId, document != nil else { return }
        let rounded = (value * 10).rounded() / 10
        // Lyrics timed for the counterpart keep their own offset (keyed by that cut); unsynced ones have none.
        let videoId: String, version: String
        switch renditionTiming {
        case .own:
            guard let key = own?.key, let v = own?.version else { return }
            (videoId, version) = (key, v)
            own?.shown?.offset = rounded
            own?.full?.offset = rounded
            if var s = shifts[trackID], s.renditionKey == key {
                s.renditionOffset = rounded
                shifts[trackID] = s
            }
        case .unsynced, .lookingUp:
            return
        case .base:
            guard let v = baseVersionID else { return }
            (videoId, version) = (trackID, v)
            baseShown?.offset = rounded
            baseFull?.offset = rounded
        }
        document?.offset = rounded
        fullDocument?.offset = rounded
        let key = Self.offsetKey(videoId, version)
        pendingOffsets[key] = rounded
        offsetWrites[key]?.cancel()
        let resolver = resolver
        offsetWrites[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await resolver.setOffset(rounded, for: videoId, version: version)
            guard let self, self.pendingOffsets[key] == rounded else { return }
            self.pendingOffsets[key] = nil
            self.offsetWrites[key] = nil
        }
    }

    private static func offsetKey(_ videoId: String, _ version: String) -> String { videoId + "|" + version }

    // MARK: Song⇄Video renditions

    /// The rendition playing changed (Song⇄Video, or its length became known). Called by
    /// `QTLyricsRenditionCoordinator`; nil = unknown (treated as the track's own).
    public func setRendition(_ r: QTLyricsRendition?) {
        if let a = rendition, let b = r, a.videoId == b.videoId, a.isCounterpart == b.isCounterpart,
           abs(a.duration - b.duration) < 0.75 { return }
        if rendition == nil, r == nil { return }
        rendition = r
        presentRendition()
    }

    /// Publishes the lyrics for the playing rendition (see `QTLyricsRenditionTiming.decide`), starting the lookup
    /// for a counterpart's own cut when needed.
    private func presentRendition() {
        let ownMatches = own != nil && own?.key == rendition.map(QTLyricsRenditionTiming.cacheKey(for:))
        let decision = QTLyricsRenditionTiming.decide(base: baseFull, baseDuration: track?.duration ?? 0, rendition: rendition,
                                                      own: ownMatches ? own?.full : nil, ownDuration: ownMatches ? own?.duration : nil,
                                                      ownLookupDone: ownMatches && own?.done == true)
        switch decision {
        case .base:
            renditionTiming = .base
            document = baseShown
            fullDocument = baseFull
        case .own(let full):
            renditionTiming = .own
            document = own?.shown
            fullDocument = full
        case .plain(let full):
            renditionTiming = .unsynced
            document = baseShown.map(QTLyricsRenditionTiming.plain)
            fullDocument = full
        case .lookUp:
            // Unsynced while the counterpart's own timing is looked up.
            renditionTiming = .lookingUp
            document = baseShown.map(QTLyricsRenditionTiming.plain)
            fullDocument = baseFull.map(QTLyricsRenditionTiming.plain)
            if !ownMatches, let rendition, let track { lookUpOwn(rendition, for: track) }
        }
        publishVersions()
    }

    private func lookUpOwn(_ r: QTLyricsRendition, for track: QTTrack) {
        let lookup = QTLyricsRenditionLookup(key: QTLyricsRenditionTiming.cacheKey(for: r),
                                             query: QTLyricsRenditionTiming.query(for: query(for: track), rendition: r),
                                             renditionDuration: r.duration)
        own = lookup
        runOwn(lookup, for: track) { resolver, query, config in
            await resolver.resolve(query, configuration: config)
        }
    }

    /// Runs a resolver call on the counterpart cut's lookup (the lookup itself, or a pick / report on it) and
    /// publishes the result. What shows meanwhile stays.
    private func runOwn(_ lookup: QTLyricsRenditionLookup, for track: QTTrack,
                        _ body: @escaping @Sendable (QTLyricsResolver, QTLyricsQuery, QTLyricsResolverConfiguration) async -> QTLyricsResolution) {
        guard let query = lookup.query else { return }
        ownTask?.cancel()
        let key = lookup.key, renditionDuration = lookup.renditionDuration
        let config = configuration
        let resolver = resolver
        let live = engine == .live
        ownTask = Task { @MainActor [weak self] in
            let resolution: QTLyricsResolution? = live ? await body(resolver, query, config) : nil
            guard let self, !Task.isCancelled, self.own?.key == key, self.track?.videoId == track.videoId else { return }
            var lookup = QTLyricsRenditionLookup(key: key, done: true, query: query, renditionDuration: renditionDuration)
            if let resolution {
                lookup.versions = resolution.versions
                lookup.pinnedID = resolution.pinnedID
                if let full = resolution.fullDocument {
                    lookup.full = full
                    lookup.shown = resolution.document
                    lookup.duration = resolution.versions.first { $0.id == resolution.chosenID }?.candidate.duration
                    lookup.version = resolution.chosenID
                    if let v = resolution.chosenID, let pending = self.pendingOffsets[Self.offsetKey(key, v)] {
                        lookup.full?.offset = pending
                        lookup.shown?.offset = pending
                    }
                }
            }
            self.own = lookup
            self.log.debug("rendition \(key, privacy: .public): \(lookup.full?.source.id ?? "none", privacy: .public) \(lookup.duration ?? 0)")
            if let base = self.baseFull, let ownFull = lookup.full,
               let d = lookup.duration, abs(d - renditionDuration) <= QTLyricsRenditionTiming.lookupTolerance,
               let shift = QTLyricsRenditionTiming.shift(from: base, to: ownFull) {
                self.shifts[track.videoId] = QTLyricsRenditionShift(renditionKey: key, shift: shift, renditionOffset: ownFull.offset)
                self.shiftGeneration += 1
            }
            self.presentRendition()
        }
    }

    /// The position to play the other rendition from on a Song⇄Video switch, when the lyrics know how the two cuts
    /// line up; nil = unknown (same position).
    /// - Parameters:
    ///   - toCounterpart: true from the track's own rendition to its counterpart, false for the way back.
    ///   - counterpartDuration: the counterpart's length, when known (clamps the result).
    public func switchTime(_ t: TimeInterval, track: QTTrack, toCounterpart: Bool, counterpartDuration: TimeInterval? = nil) -> TimeInterval? {
        guard let s = shifts[track.videoId], track.videoId == self.track?.videoId else { return nil }
        if let id = track.counterpart?.videoId, !s.renditionKey.hasPrefix(id + "~") { return nil }
        return QTLyricsRenditionTiming.map(t, shift: s.shift, baseOffset: baseFull?.offset ?? 0, renditionOffset: s.renditionOffset,
                                           toRendition: toCounterpart, renditionDuration: counterpartDuration)
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
                let offset = await resolver.offset(for: query.videoId, version: Self.bundledVersionID)
                resolution = Self.bundledResolution(self?.bundled[track.videoId], offset: offset, config: config)
            } else {
                resolution = await body(resolver, query, config)
            }
            guard let self, !Task.isCancelled, token == self.generation, self.track?.videoId == track.videoId else { return }
            var r = resolution
            if r.document == nil, !r.isComplete, !r.isLyricsOff, engine == .live, self.isMockTrack(track),
               let local = self.bundled[track.videoId], config.isEnabled(local.source) {
                let offset = await resolver.offset(for: query.videoId, version: Self.bundledVersionID)
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
        return QTLyricsResolution(document: shown, fullDocument: full, versions: [], chosenID: nil,
                                  attribution: nil, fromCache: true)
    }

    private func apply(_ r: QTLyricsResolution, for track: QTTrack, config: QTLyricsResolverConfiguration) {
        var shown = r.document
        var full = r.fullDocument
        baseVersionID = r.chosenID ?? (full != nil ? Self.bundledVersionID : nil)
        // A nudge that hasn't been written yet wins over the stored offset.
        if let v = baseVersionID, let pending = pendingOffsets[Self.offsetKey(track.videoId, v)] {
            shown?.offset = pending
            full?.offset = pending
        }
        baseShown = shown
        baseFull = full
        versions = r.versions
        chosenVersionID = r.chosenID
        pinnedVersionID = r.pinnedID
        isLyricsOff = r.isLyricsOff
        attribution = r.attribution
        unreachableSources = r.unreachableSources
        translationTarget = config.translationLanguage
        translationPlan = QTLyricsTranslationPolicy.plan(for: full, target: config.translationLanguage)
        phase = shown != nil ? .loaded : (r.isComplete ? .notFound : .unreachable)
        // The lookup itself counts as an attempt: re-opening a lyrics surface right away doesn't retry.
        if phase == .unreachable { lastRetry = Date() }
        lastConfiguration = config
        presentRendition()   // publishes the versions too
        log.debug("lyrics \(track.videoId, privacy: .public): \(shown?.source.id ?? "none", privacy: .public) \(shown?.syncKind.rawValue ?? "-", privacy: .public) tr \(shown?.translationLanguage ?? "-", privacy: .public)")
    }

    /// Feeds the "Lyrics Source" menu (Controls menu and options popover), keyed by the track: the versions of the
    /// lyrics showing (the track's own, or the counterpart cut's when those show) with how much longer or shorter
    /// each is timed than what plays, and the persisted choice.
    private func publishVersions() {
        guard let versionStore, engine == .live, let track else { return }
        let list: [QTResolvedLyricsVersion], chosen: String?, pin: String?, length: TimeInterval
        if let own = shownOwn {
            (list, chosen, pin, length) = (own.versions, own.version, own.pinnedID, own.renditionDuration)
        } else {
            (list, chosen, pin, length) = (versions, chosenVersionID, isLyricsOff ? QTLyricsCache.noLyricsPin : pinnedVersionID,
                                           track.duration)
        }
        let rows = list.map { v in
            QTLyricsVersion(id: v.id, source: v.source, syncKind: v.syncKind ?? .line,
                            translationLanguage: v.translationLanguage, confidence: v.score,
                            durationDelta: length > 0 ? v.duration.map { $0 - length } : nil,
                            isPossibleMismatch: v.isPossibleMismatch, isReported: v.isReported == true,
                            matchedName: v.source == .imported ? v.candidate.title
                                : v.candidate.nameDiffering(fromTitle: track.title, artists: track.artists.map(\.name)),
                            length: v.duration, album: v.candidate.album.flatMap { $0.isEmpty ? nil : $0 },
                            textFingerprint: v.textFingerprint)
        }
        versionStore.publish(rows, for: track.videoId, selected: chosen)
        let choice: QTLyricsSourceChoice = switch pin {
        case nil: .automatic
        case QTLyricsCache.noLyricsPin?: .off
        case let id?: .version(id)
        }
        versionStore.setChoice(choice, for: track.videoId)
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
        if let full = baseFull { baseShown = QTLyricsTranslationPolicy.applyProviderLane(to: full, target: config.translationLanguage) }
        // The counterpart's own lyrics are looked up again with the new sources / target.
        if own != nil {
            ownTask?.cancel()
            own = nil
            presentRendition()
        }
        translationPlan = QTLyricsTranslationPolicy.plan(for: fullDocument, target: config.translationLanguage)
        guard let track, engine == .live || sourcesChanged else { return }
        if document == nil { phase = .loading }
        run(for: track, holdsReadiness: false) { resolver, query, config in
            await resolver.resolve(query, configuration: config)
        }
    }
}

/// How the published lyrics relate to the playing rendition.
public enum QTLyricsRenditionDisplay: Equatable, Sendable {
    /// The track's own lyrics (same cut).
    case base
    /// Lyrics timed for the counterpart's own cut.
    case own
    /// Another cut with nothing timed for it: unsynced.
    case unsynced
    /// Another cut; its timing is being looked up (unsynced meanwhile).
    case lookingUp
}

/// A counterpart's own lyrics lookup.
struct QTLyricsRenditionLookup {
    var key: String
    var done = false
    /// The cut's own query (videoId = `key`); picks and reports on its versions go to it.
    var query: QTLyricsQuery?
    /// Length of the cut that plays.
    var renditionDuration: TimeInterval = 0
    var shown: QTLyricsDocument?
    var full: QTLyricsDocument?
    /// Length the chosen version declares.
    var duration: TimeInterval?
    /// The chosen version (its offset's key).
    var version: String?
    /// Every version found for the cut ("Lyrics Source" while its lyrics show) and the stored pin.
    var versions: [QTResolvedLyricsVersion] = []
    var pinnedID: String?
}

/// How a counterpart's own lyrics line up with the track's.
struct QTLyricsRenditionShift {
    var renditionKey: String
    /// Counterpart lyric time − track lyric time.
    var shift: TimeInterval
    var renditionOffset: TimeInterval
}

/// The lyrics session's own network watcher (the web playback engine has one too, but the simulated engine and
/// the mock catalog don't, and lyrics must retry either way). Reports changes on the main actor.
final class QTLyricsNetworkMonitor: Sendable {
    private let monitor = NWPathMonitor()

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in onChange(available) }
        }
        monitor.start(queue: DispatchQueue(label: "com.roderickqiu.qtube.lyrics-network", qos: .utility))
    }

    deinit { monitor.cancel() }
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

extension QTLyricsCandidate {
    /// The parts of the song the source filed this under that differ from the playing song, for the "Lyrics Source"
    /// menu: "“Title (Remix)”", "Other Artist", or both; nil when it names the same song. Titles compare without
    /// noise ("Official Video") but with version markers (Live, Remix…); the provider's other titles and artist names
    /// count as the same ("出牌" for "Hạ Phỏm"). Unknown artists never show.
    func nameDiffering(fromTitle title: String, artists playingNames: [String]) -> String? {
        let key = QTLyricsTextFolding.comparisonKey
        let playing = QTTitleCleaner.clean(title), mine = QTTitleCleaner.clean(self.title)
        let playingTitles = Set(([playing.core] + playing.alternates).map(key))
        let myTitles = Set(([mine.core] + mine.alternates + titleAliases.map { QTTitleCleaner.clean($0).core }).map(key))
        let sameTitle = mine.tags == playing.tags && !playingTitles.isDisjoint(with: myTitles)
        let playingArtists = Set(playingNames.flatMap(QTTitleCleaner.splitArtists).map(key))
        let myArtists = Set((artists + artistAliases).flatMap(QTTitleCleaner.splitArtists).map(key))
        let sameArtist = artists.isEmpty || playingNames.isEmpty || !playingArtists.isDisjoint(with: myArtists)
        var parts: [String] = []
        if !sameTitle, !self.title.isEmpty {
            let shown = self.title.count > 60 ? self.title.prefix(59) + "…" : Substring(self.title)
            parts.append(QTLoc.tr("“%@”", table: .lyrics, String(shown)))
        }
        if !sameArtist { parts.append(artists.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
