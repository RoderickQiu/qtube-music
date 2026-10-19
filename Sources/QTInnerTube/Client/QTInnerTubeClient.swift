import Foundation
import QTCore

/// Client-side values scraped from the web client's `ytcfg` (or the configured fallbacks).
public struct QTInnerTubeClientConfig: Sendable, Hashable {
    public var apiKey: String?
    public var clientVersion: String
    public var visitorData: String?
    /// Region YouTube inferred for this connection (`INNERTUBE_CONTEXT_GL`).
    public var gl: String?
    /// True when the values came from a live scrape.
    public var isScraped: Bool

    public init(apiKey: String? = nil, clientVersion: String, visitorData: String? = nil, gl: String? = nil,
                isScraped: Bool = false) {
        self.apiKey = apiKey
        self.clientVersion = clientVersion
        self.visitorData = visitorData
        self.gl = gl
        self.isScraped = isScraped
    }

    /// Extracts `ytcfg` values from the music.youtube.com HTML.
    public static func scrape(html: String, fallbackVersion: String) -> QTInnerTubeClientConfig? {
        func value(_ key: String) -> String? {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
            guard let range = html.range(of: pattern, options: .regularExpression) else { return nil }
            let match = String(html[range])
            guard let colon = match.firstIndex(of: ":") else { return nil }
            let rest = match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return String(rest.dropFirst().dropLast())
        }
        let version = value("INNERTUBE_CLIENT_VERSION")
        let key = value("INNERTUBE_API_KEY")
        guard version != nil || key != nil else { return nil }
        return QTInnerTubeClientConfig(apiKey: key, clientVersion: version ?? fallbackVersion,
                                       visitorData: value("VISITOR_DATA"),
                                       gl: value("INNERTUBE_CONTEXT_GL"), isScraped: true)
    }
}

/// YouTube Music InnerTube client (WEB_REMIX). One per app; safe to share across tasks.
///
/// Anonymous by default. With a `QTInnerTubeCredentialsProvider` (QTAuth) requests carry the session cookies and a
/// SAPISIDHASH. Account writes (likes, playlist edits) are implemented but refused unless `allowsAccountWrites` is
/// turned on — writing to the user's account needs the user's go-ahead.
public actor QTInnerTubeClient {
    public private(set) var configuration: QTInnerTubeConfiguration
    public private(set) var allowsAccountWrites = false

    private let transport: any QTHTTPTransport
    private var credentialsProvider: (any QTInnerTubeCredentialsProvider)?
    private let retry: QTRetryPolicy
    private let scrapesClientConfig: Bool
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    private var cache = QTResponseCache()
    private var clientConfigValue: QTInnerTubeClientConfig?
    private var clientConfigTask: Task<QTInnerTubeClientConfig, Never>?
    private var visitorData: String?

    public init(configuration: QTInnerTubeConfiguration = QTInnerTubeConfiguration(),
                transport: any QTHTTPTransport = QTURLSessionTransport(),
                credentials: (any QTInnerTubeCredentialsProvider)? = nil,
                retry: QTRetryPolicy = .default,
                scrapesClientConfig: Bool = true,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.transport = transport
        self.credentialsProvider = credentials
        self.retry = retry
        self.scrapesClientConfig = scrapesClientConfig
        self.sleep = sleep
        self.now = now
    }

    // MARK: Settings

    /// Interface language changed: `hl` follows it. Clears the cache (titles are localized server-side).
    public func setLanguage(hl: String) {
        guard hl != configuration.hl else { return }
        configuration.hl = hl
        cache.removeAll()
    }

    /// Account region (`gl`).
    public func setRegion(gl: String) {
        guard gl != configuration.gl else { return }
        configuration.gl = gl
        cache.removeAll()
    }

    public func setCredentialsProvider(_ provider: (any QTInnerTubeCredentialsProvider)?) {
        credentialsProvider = provider
        cache.removeAll()
    }

    /// Enables like/playlist-edit endpoints. Off by default; only turn on with the user's consent.
    public func setAllowsAccountWrites(_ allowed: Bool) {
        allowsAccountWrites = allowed
    }

    public func clearCache() {
        cache.removeAll()
    }

    var cachedResponseCount: Int { cache.count }

    // MARK: Client config (ytcfg scrape)

    /// The live client version / API key / visitor id, scraped once from music.youtube.com (anonymous, consent
    /// cookie only). Falls back to the configured values if the page can't be read.
    public func clientConfig() async -> QTInnerTubeClientConfig {
        if let clientConfigValue { return clientConfigValue }
        let fallback = QTInnerTubeClientConfig(clientVersion: configuration.clientVersion)
        guard scrapesClientConfig else {
            clientConfigValue = fallback
            return fallback
        }
        if let clientConfigTask { return await clientConfigTask.value }
        let transport = transport
        let configuration = configuration
        let task = Task<QTInnerTubeClientConfig, Never> {
            var request = URLRequest(url: configuration.webClientURL)
            request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
            // Pre-accepted consent so EU connections get the real page, not consent.youtube.com.
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
            request.setValue(configuration.hl, forHTTPHeaderField: "Accept-Language")
            request.timeoutInterval = 10
            guard let (data, response) = try? await transport.send(request), (200..<400).contains(response.statusCode),
                  let html = String(data: data, encoding: .utf8),
                  let scraped = QTInnerTubeClientConfig.scrape(html: html, fallbackVersion: configuration.clientVersion)
            else { return fallback }
            return scraped
        }
        clientConfigTask = task
        let value = await task.value
        clientConfigValue = value
        clientConfigTask = nil
        if visitorData == nil { visitorData = value.visitorData }
        return value
    }

    // MARK: Raw requests

    /// Endpoints that only make sense signed in (refused up front when anonymous).
    static let authOnlyBrowseIds: Set<String> = [
        "VLLM", "FEmusic_liked_playlists", "FEmusic_liked_albums", "FEmusic_liked_videos", "FEmusic_history",
        "FEmusic_library_landing", "FEmusic_library_corpus_artists", "FEmusic_library_corpus_track_artists",
        "FEmusic_library_songs", "FEmusic_library_albums", "FEmusic_library_artists",
    ]
    static let writeEndpoints: Set<String> = [
        "like/like", "like/dislike", "like/removelike", "browse/edit_playlist", "playlist/create", "playlist/delete",
        "subscription/subscribe", "subscription/unsubscribe", "feedback",
    ]

    /// POSTs `body` (plus the client context) to `endpoint` and returns the parsed JSON.
    /// - Parameters:
    ///   - ttl: cache lifetime; nil = don't cache.
    ///   - requiresAuth: refuse with `.notSignedIn` when there's no session.
    public func send(_ endpoint: String, body: [String: QTJSON], ttl: TimeInterval? = nil,
                     requiresAuth: Bool = false) async throws -> QTJSON {
        if Self.writeEndpoints.contains(endpoint), !allowsAccountWrites { throw QTInnerTubeError.writesDisabled }
        let credentials = await credentialsProvider?.credentials()
        let needsAuth = requiresAuth || Self.writeEndpoints.contains(endpoint)
            || (body["browseId"]?.string).map(Self.authOnlyBrowseIds.contains) == true
            || endpoint.hasPrefix("account/")
        if needsAuth, credentials == nil { throw QTInnerTubeError.notSignedIn }

        let client = await clientConfig()
        let cacheKey = try ttl.map { _ in try cacheKey(endpoint: endpoint, body: body, credentials: credentials) }
        if let cacheKey, let hit = cache.value(for: cacheKey, now: now()) { return hit }

        let request = try makeRequest(endpoint: endpoint, body: body, client: client, credentials: credentials)
        let json = try await perform(request, authenticated: credentials != nil, endpoint: endpoint)
        if visitorData == nil, let v = QTInnerTubeParser.visitorData(json) { visitorData = v }
        if let cacheKey, let ttl { cache.store(json, for: cacheKey, ttl: ttl, now: now()) }
        return json
    }

    func makeRequest(endpoint: String, body: [String: QTJSON], client: QTInnerTubeClientConfig,
                     credentials: QTInnerTubeCredentials?) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL.appendingPathComponent(endpoint),
                                             resolvingAgainstBaseURL: false) else {
            throw QTInnerTubeError.invalidResponse
        }
        var query = [URLQueryItem(name: "prettyPrint", value: "false")]
        if let key = client.apiKey { query.insert(URLQueryItem(name: "key", value: key), at: 0) }
        components.queryItems = query
        guard let url = components.url else { throw QTInnerTubeError.invalidResponse }

        var full = body
        full["context"] = context(client: client, credentials: credentials)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = try QTJSON.object(full).data()
        let origin = QTInnerTubeConfiguration.origin
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(configuration.hl, forHTTPHeaderField: "Accept-Language")
        request.setValue(QTInnerTubeConfiguration.clientNameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let credentials {
            request.setValue(QTSAPISIDHash.header(sapisid: credentials.sapisid, origin: origin,
                                                  timestamp: Int(now().timeIntervalSince1970)),
                             forHTTPHeaderField: "Authorization")
            request.setValue(String(credentials.authUser), forHTTPHeaderField: "X-Goog-AuthUser")
            request.setValue(origin, forHTTPHeaderField: "X-Origin")
            request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    func context(client: QTInnerTubeClientConfig, credentials: QTInnerTubeCredentials?) -> QTJSON {
        var c: [String: QTJSON] = [
            "clientName": .string(configuration.clientName),
            "clientVersion": .string(client.clientVersion),
            "hl": .string(configuration.hl),
            "gl": .string(configuration.gl),
            "platform": "DESKTOP",
            "userAgent": .string(configuration.userAgent),
            "utcOffsetMinutes": .number(Double(TimeZone.current.secondsFromGMT(for: now()) / 60)),
        ]
        if let visitorData { c["visitorData"] = .string(visitorData) }
        var user: [String: QTJSON] = ["lockedSafetyMode": false]
        // Brand accounts only on authenticated requests; anonymous requests must look like a signed-out client.
        if let brand = credentials?.onBehalfOfUser { user["onBehalfOfUser"] = .string(brand) }
        return ["client": .object(c), "user": .object(user)]
    }

    func cacheKey(endpoint: String, body: [String: QTJSON], credentials: QTInnerTubeCredentials?) throws -> String {
        let data = try QTJSON.object(body).data()
        return "\(endpoint)|\(configuration.hl)|\(configuration.gl)|\(credentials?.cacheScope ?? "anon")|"
            + String(decoding: data, as: UTF8.self)
    }

    private func perform(_ request: URLRequest, authenticated: Bool, endpoint: String) async throws -> QTJSON {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await performOnce(request, authenticated: authenticated, endpoint: endpoint)
            } catch let error as QTInnerTubeError where error.isTransient && attempt < retry.maxAttempts {
                var retryAfter: TimeInterval?
                if case .rateLimited(let after) = error { retryAfter = after }
                try await sleep(retry.delay(afterAttempt: attempt, retryAfter: retryAfter))
            }
        }
    }

    private func performOnce(_ request: URLRequest, authenticated: Bool, endpoint: String) async throws -> QTJSON {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw QTInnerTubeError.network(code: error.errorCode)
        } catch let error as QTInnerTubeError {
            throw error
        } catch {
            throw QTInnerTubeError.network(code: URLError.Code.unknown.rawValue)
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            if authenticated {
                await credentialsProvider?.sessionDidExpire()
                cache.removeAll()
                throw QTInnerTubeError.sessionExpired
            }
            throw response.statusCode == 401 ? QTInnerTubeError.notSignedIn : QTInnerTubeError.http(status: 403)
        case 429, 503:
            let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw QTInnerTubeError.rateLimited(retryAfter: after)
        default:
            if let json = try? QTJSON(data: data), let message = json[path: "error", "message"].string {
                throw response.statusCode >= 500 ? QTInnerTubeError.http(status: response.statusCode)
                    : QTInnerTubeError.api(status: response.statusCode, message: message)
            }
            throw QTInnerTubeError.http(status: response.statusCode)
        }
        if authenticated, let url = response.url, let fields = response.allHeaderFields as? [String: String],
           fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) {
            let rotated = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !rotated.isEmpty { await credentialsProvider?.didReceive(cookies: rotated) }
        }
        guard let json = try? QTJSON(data: data), json.object != nil else { throw QTInnerTubeError.invalidResponse }
        // Signed-in request answered as signed out → the session is gone (cookies expired/revoked).
        if authenticated, ["browse", "next", "search"].contains(endpoint), QTInnerTubeParser.loggedIn(json) == false {
            await credentialsProvider?.sessionDidExpire()
            cache.removeAll()
            throw QTInnerTubeError.sessionExpired
        }
        return json
    }

    // MARK: Browse

    func browse(_ browseId: String, params: String? = nil, ttl: TimeInterval?) async throws -> QTJSON {
        var body: [String: QTJSON] = ["browseId": .string(browseId)]
        if let params { body["params"] = .string(params) }
        return try await send("browse", body: body, ttl: ttl)
    }

    func continuation(_ endpoint: String, _ token: QTContinuation, ttl: TimeInterval? = nil,
                      extra: [String: QTJSON] = [:], requiresAuth: Bool = false) async throws -> QTJSON {
        var body = extra
        body["continuation"] = .string(token.token)
        return try await send(endpoint, body: body, ttl: ttl, requiresAuth: requiresAuth)
    }

    /// Home. Pass a mood chip's target (from `QTHomeFeed.moods`) for the filtered home.
    public func home(_ target: QTBrowseTarget? = nil) async throws -> QTHomePage {
        let t = target ?? QTBrowseTarget(browseId: "FEmusic_home")
        return QTInnerTubeParser.home(try await browse(t.browseId, params: t.params, ttl: QTCacheTTL.home))
    }

    /// More Home shelves.
    public func homeContinuation(_ token: QTContinuation) async throws -> QTHomePage {
        QTInnerTubeParser.home(try await continuation("browse", token, ttl: QTCacheTTL.home))
    }

    public func explore() async throws -> QTExplorePage {
        QTInnerTubeParser.explore(try await browse("FEmusic_explore", ttl: QTCacheTTL.explore))
    }

    public func newReleases() async throws -> [QTShelf] {
        QTInnerTubeParser.shelves(try await browse("FEmusic_new_releases", ttl: QTCacheTTL.explore))
    }

    public func charts() async throws -> [QTShelf] {
        QTInnerTubeParser.shelves(try await browse("FEmusic_charts", ttl: QTCacheTTL.explore))
    }

    public func moodsAndGenres() async throws -> QTMoodsPage {
        QTInnerTubeParser.moods(try await browse("FEmusic_moods_and_genres", ttl: QTCacheTTL.explore))
    }

    /// A mood/genre page (playlists) for a chip from `moodsAndGenres()` / `explore()`; home chips go to `home(_:)`.
    public func moodPage(_ chip: QTMoodChip) async throws -> [QTShelf] {
        let t = QTBrowseTarget(moodChipID: chip.id)
        return QTInnerTubeParser.shelves(try await browse(t.browseId, params: t.params, ttl: QTCacheTTL.explore))
    }

    // MARK: Search

    public func search(_ query: String, filter: QTSearchFilter = .all) async throws -> QTSearchResults {
        var body: [String: QTJSON] = ["query": .string(query)]
        if let params = filter.params { body["params"] = .string(params.removingPercentEncoding ?? params) }
        return QTInnerTubeParser.search(try await send("search", body: body, ttl: QTCacheTTL.search), filter: filter)
    }

    public func searchContinuation(_ token: QTContinuation, filter: QTSearchFilter) async throws -> QTSearchResults {
        QTInnerTubeParser.search(try await continuation("search", token, ttl: QTCacheTTL.search), filter: filter)
    }

    // MARK: Album / artist / playlist

    public func album(_ browseId: String) async throws -> QTAlbumPage {
        let json = try await browse(browseId, ttl: QTCacheTTL.album)
        guard let page = QTInnerTubeParser.album(json, browseId: browseId) else { throw QTInnerTubeError.parse("album") }
        return page
    }

    public func artist(_ browseId: String) async throws -> QTArtistPage {
        let browseId = Self.channelId(browseId)
        let json = try await browse(browseId, ttl: QTCacheTTL.artist)
        guard let page = QTInnerTubeParser.artist(json, browseId: browseId) else { throw QTInnerTubeError.parse("artist") }
        return page
    }

    /// A playlist by id (`VL…`, raw `PL…`/`OLAK…`/`RDCLAK…`, or `LM` for Liked Music). First page of tracks.
    public func playlist(_ id: String) async throws -> QTPlaylistPage {
        let browseId = id == "LM" ? QTInnerTube.likedSongsBrowseId : QTParse.playlistBrowseId(id)
        let json = try await browse(browseId, ttl: browseId == QTInnerTube.likedSongsBrowseId ? QTCacheTTL.library
                                        : QTCacheTTL.playlist)
        guard let page = QTInnerTubeParser.playlist(json, browseId: browseId) else {
            throw QTInnerTubeError.parse("playlist")
        }
        return page
    }

    public func playlistContinuation(_ token: QTContinuation) async throws -> QTTrackPage {
        QTInnerTubeParser.trackContinuation(try await continuation("browse", token, ttl: QTCacheTTL.playlist))
    }

    /// Every track of a playlist, following continuations (bounded by `maxPages`).
    public func playlistAllTracks(_ id: String, maxPages: Int = 50) async throws -> QTPlaylist {
        let first = try await playlist(id)
        var playlist = first.playlist
        var tracks = playlist.tracks ?? []
        var token = first.continuation
        var pages = 1
        while let t = token, pages < maxPages {
            let page = try await playlistContinuation(t)
            tracks += page.tracks
            token = page.continuation
            pages += 1
        }
        playlist.tracks = tracks
        return playlist
    }

    // MARK: Library (signed in)

    public func likedSongs() async throws -> QTPlaylistPage { try await playlist("LM") }

    public func libraryPlaylists() async throws -> QTLibraryPage<QTPlaylist> {
        library("FEmusic_liked_playlists", try await browse("FEmusic_liked_playlists", ttl: QTCacheTTL.library)) {
            if case .playlist(let p) = $0 { p } else { nil }
        }
    }

    public func libraryAlbums() async throws -> QTLibraryPage<QTAlbum> {
        library("FEmusic_liked_albums", try await browse("FEmusic_liked_albums", ttl: QTCacheTTL.library)) {
            if case .album(let a) = $0 { a } else { nil }
        }
    }

    /// Artists of the songs in the library. Ids are channel ids (`UC…`; the library's `MPLA…` wrappers are unwrapped).
    public func libraryArtists() async throws -> QTLibraryPage<QTArtist> {
        library("FEmusic_library_corpus_track_artists",
                try await browse("FEmusic_library_corpus_track_artists", ttl: QTCacheTTL.library)) {
            if case .artist(var a) = $0 { a.id = Self.channelId(a.id); return a } else { return nil }
        }
    }

    /// Songs saved to the library (`FEmusic_liked_videos`; `FEmusic_library_songs` answers 400 as of 2026-10).
    public func librarySongs() async throws -> QTLibraryPage<QTTrack> {
        library("FEmusic_liked_videos", try await browse("FEmusic_liked_videos", ttl: QTCacheTTL.library)) {
            $0.track
        }
    }

    /// Library artist pages (`MPLAUC…`) only list the user's songs; the artist page is the channel (`UC…`).
    public static func channelId(_ browseId: String) -> String {
        browseId.hasPrefix("MPLA") ? String(browseId.dropFirst(4)) : browseId
    }

    /// Next page of any library list.
    public func libraryContinuation(_ token: QTContinuation) async throws -> QTLibraryPage<QTShelfItem> {
        QTInnerTubeParser.libraryItems(try await continuation("browse", token, requiresAuth: true))
    }

    private func library<T>(_ id: String, _ json: QTJSON, _ pick: (QTShelfItem) -> T?) -> QTLibraryPage<T> {
        let page = QTInnerTubeParser.libraryItems(json)
        return QTLibraryPage(items: page.items.compactMap(pick), continuation: page.continuation)
    }

    // MARK: Watch

    /// Up Next / radio for a track. With `playlistId` nil, YouTube Music builds the default queue; pass
    /// `"RDAMVM" + videoId` for a radio. `isAudioOnly` asks for the Song versions where an account has them.
    public func next(videoId: String?, playlistId: String? = nil, params: String? = nil,
                     isAudioOnly: Bool = true) async throws -> QTWatchNext {
        var body: [String: QTJSON] = ["enablePersistentPlaylistPanel": true, "isAudioOnly": .bool(isAudioOnly),
                                      "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"]
        if let videoId { body["videoId"] = .string(videoId) }
        if let playlistId { body["playlistId"] = .string(QTParse.rawPlaylistId(playlistId)) }
        if let params { body["params"] = .string(params) }
        return QTInnerTubeParser.next(try await send("next", body: body))
    }

    /// More of a radio/autoplay queue.
    public func nextContinuation(_ token: QTContinuation, playlistId: String?) async throws -> QTWatchNext {
        var extra: [String: QTJSON] = ["enablePersistentPlaylistPanel": true, "isAudioOnly": true]
        if let playlistId { extra["playlistId"] = .string(QTParse.rawPlaylistId(playlistId)) }
        return QTInnerTubeParser.next(try await continuation("next", token, extra: extra))
    }

    /// Track metadata for a batch of video ids (`music/get_queue`).
    public func queue(videoIds: [String]) async throws -> [QTTrack] {
        guard !videoIds.isEmpty else { return [] }
        return QTInnerTubeParser.queue(try await send("music/get_queue", body: ["videoIds": .array(videoIds.map { .string($0) })]))
    }

    /// Playability + metadata. Stream URLs are out of scope here (playback engine).
    public func player(videoId: String) async throws -> QTPlayerInfo {
        let json = try await send("player", body: ["videoId": .string(videoId)])
        guard let info = QTInnerTubeParser.player(json) else { throw QTInnerTubeError.parse("player") }
        return info
    }

    /// The Song⇄Video counterpart YouTube Music states for a video id in `next` (signed-in clients get a
    /// `playlistPanelVideoWrapperRenderer`; anonymous ones don't). See `counterpart(for: QTTrack)` for fallbacks.
    public func counterpart(for videoId: String) async throws -> QTCounterpart? {
        let next = try await next(videoId: videoId)
        return (next.current ?? next.tracks.first { $0.videoId == videoId })?.counterpart
    }

    /// Plain lyrics from the Lyrics tab (`QTWatchNext.lyricsBrowseId`).
    public func plainLyrics(browseId: String) async throws -> QTPlainLyrics? {
        QTInnerTubeParser.plainLyrics(try await browse(browseId, ttl: QTCacheTTL.lyrics))
    }

    /// Related tab shelves (`QTWatchNext.relatedBrowseId`).
    public func related(browseId: String) async throws -> [QTShelf] {
        QTInnerTubeParser.shelves(try await browse(browseId, ttl: QTCacheTTL.album))
    }

    // MARK: Account

    /// Signed-in account summary (read-only).
    public func account() async throws -> QTAccountInfo {
        let json = try await send("account/account_menu", body: [:], requiresAuth: true)
        guard let info = QTInnerTubeParser.account(json) else { throw QTInnerTubeError.parse("account") }
        return info
    }

    /// Facts only the signed-in web client page states (its `ytcfg`): Music Premium (`IS_SUBSCRIBER`), the region
    /// YouTube uses for the account (`INNERTUBE_CONTEXT_GL`) and its language. A read-only GET of music.youtube.com.
    public func accountContext() async throws -> QTAccountContext {
        guard let credentials = await credentialsProvider?.credentials() else { throw QTInnerTubeError.notSignedIn }
        var request = URLRequest(url: configuration.webClientURL)
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.hl, forHTTPHeaderField: "Accept-Language")
        request.setValue(credentials.cookieHeader + "; SOCS=CAI", forHTTPHeaderField: "Cookie")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError {
            throw QTInnerTubeError.network(code: error.errorCode)
        }
        guard (200..<300).contains(response.statusCode) else { throw QTInnerTubeError.http(status: response.statusCode) }
        if let url = response.url, let fields = response.allHeaderFields as? [String: String] {
            let rotated = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !rotated.isEmpty { await credentialsProvider?.didReceive(cookies: rotated) }
        }
        let context = QTAccountContext.scrape(html: String(decoding: data, as: UTF8.self))
        if context.isLoggedIn == false {
            await credentialsProvider?.sessionDidExpire()
            cache.removeAll()
            throw QTInnerTubeError.sessionExpired
        }
        return context
    }

    // MARK: Writes (gated: never exercised against a live account without the user's consent)

    public enum QTLikeStatus: String, Sendable { case like = "like/like", dislike = "like/dislike", none = "like/removelike" }

    public func rate(videoId: String, _ status: QTLikeStatus) async throws {
        _ = try await send(status.rawValue, body: ["target": ["videoId": .string(videoId)]], requiresAuth: true)
    }

    public func addToPlaylist(_ playlistId: String, videoIds: [String]) async throws {
        let actions: [QTJSON] = videoIds.map { ["action": "ACTION_ADD_VIDEO", "addedVideoId": .string($0)] }
        _ = try await send("browse/edit_playlist", body: ["playlistId": .string(QTParse.rawPlaylistId(playlistId)),
                                                          "actions": .array(actions)], requiresAuth: true)
    }

    /// `setVideoId` is the per-row `playlistSetVideoId`.
    public func removeFromPlaylist(_ playlistId: String, items: [(videoId: String, setVideoId: String)]) async throws {
        let actions: [QTJSON] = items.map {
            ["action": "ACTION_REMOVE_VIDEO", "removedVideoId": .string($0.videoId), "setVideoId": .string($0.setVideoId)]
        }
        _ = try await send("browse/edit_playlist", body: ["playlistId": .string(QTParse.rawPlaylistId(playlistId)),
                                                          "actions": .array(actions)], requiresAuth: true)
    }
}
