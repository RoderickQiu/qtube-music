import Foundation
import QTCore

/// LRCLIB (lrclib.net): free, community, line-synced. Identifies itself with a descriptive User-Agent and
/// honours `503 Retry-After` (waits once for short delays, otherwise backs off for the given time).
public struct QTLRCLIBProvider: QTLyricsSourceProvider {
    public let source = QTLyricsSource.lrclib
    public var http: any QTLyricsHTTPClient
    public var baseURL: String
    /// Longest `Retry-After` we wait inline before retrying once (seconds).
    public var maxInlineWait: TimeInterval
    private let gate: QTRetryAfterGate
    private let bodies: QTLRCLIBBodyCache

    public init(http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient(), baseURL: String = "https://lrclib.net",
                maxInlineWait: TimeInterval = 3) {
        self.http = http
        self.baseURL = baseURL
        self.maxInlineWait = maxInlineWait
        self.gate = QTRetryAfterGate()
        self.bodies = QTLRCLIBBodyCache()
    }

    struct Record: Decodable {
        var id: Int
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    public func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        var params = [("track_name", query.cleanTitle.core)]
        if !query.primaryArtist.isEmpty { params.append(("artist_name", query.primaryArtist)) }
        let data = try await send(QTLyricsRequest.get(baseURL + "/api/search", query: params,
                                                      headers: ["User-Agent": QTLyricsRequest.descriptiveUserAgent]))
        let records: [Record]
        do { records = try JSONDecoder().decode([Record].self, from: data) }
        catch { throw QTLyricsError.decoding("lrclib search") }
        var out: [QTLyricsCandidate] = []
        for r in records.prefix(12) where r.instrumental != true {
            let hint: QTLyricsSyncKind? = r.syncedLyrics?.isEmpty == false ? .line : (r.plainLyrics?.isEmpty == false ? .plain : nil)
            guard hint != nil else { continue }
            await bodies.store(id: r.id, synced: r.syncedLyrics, plain: r.plainLyrics)
            out.append(QTLyricsCandidate(source: source, remoteID: String(r.id), title: r.trackName ?? "",
                                         artists: (r.artistName).map { [$0] } ?? [], album: r.albumName,
                                         duration: r.duration, syncHint: hint))
        }
        return out
    }

    public func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        guard let id = Int(candidate.remoteID) else { return nil }
        var body = await bodies.body(id: id)
        if body == nil {
            let data = try await send(QTLyricsRequest.get(baseURL + "/api/get/\(id)",
                                                          headers: ["User-Agent": QTLyricsRequest.descriptiveUserAgent]))
            guard let r = try? JSONDecoder().decode(Record.self, from: data) else { throw QTLyricsError.decoding("lrclib get") }
            body = (r.syncedLyrics, r.plainLyrics)
        }
        if let synced = body?.0, !synced.isEmpty { return QTLRCParser.parse(synced) }
        if let plain = body?.1, !plain.isEmpty { return QTLRCParser.parse(plain) }
        return nil
    }

    private func send(_ request: URLRequest) async throws -> Data {
        try await gate.check()
        do {
            return try await QTLyricsRequest.send(request, with: http)
        } catch QTLyricsError.rateLimited(let wait) {
            guard wait <= maxInlineWait else {
                await gate.close(for: wait)
                throw QTLyricsError.rateLimited(retryAfter: wait)
            }
            try await Task.sleep(for: .seconds(wait))
            do {
                return try await QTLyricsRequest.send(request, with: http)
            } catch QTLyricsError.rateLimited(let again) {
                await gate.close(for: again)
                throw QTLyricsError.rateLimited(retryAfter: again)
            }
        }
    }
}

/// Search responses already contain the lyrics; keep them briefly so fetching a candidate costs no request.
actor QTLRCLIBBodyCache {
    private var bodies: [Int: (String?, String?)] = [:]
    private var order: [Int] = []

    func store(id: Int, synced: String?, plain: String?) {
        if bodies[id] == nil { order.append(id) }
        bodies[id] = (synced, plain)
        while order.count > 64 { bodies[order.removeFirst()] = nil }
    }

    func body(id: Int) -> (String?, String?)? { bodies[id] }
}
