import Foundation
import QTCore

/// AMLL TTML DB (CC0, GitHub raw): community word-synced TTML, mostly CJK. Files are keyed by NetEase/QQ ids,
/// so search runs locally against the repository's metadata index (`raw-lyrics-index.jsonl`, ~1.6 MB),
/// fetched at most once a week and kept in the lyrics cache.
public struct QTAMLLLyricsProvider: QTLyricsSourceProvider {
    public let source = QTLyricsSource.amll
    public var http: any QTLyricsHTTPClient
    public var baseURL: String
    private let index: QTAMLLIndexStore

    public init(http: any QTLyricsHTTPClient = QTURLSessionLyricsHTTPClient(),
                baseURL: String = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main",
                cache: QTLyricsCache? = nil, indexMaxAge: TimeInterval = 7 * 86_400) {
        self.http = http
        self.baseURL = baseURL
        self.index = QTAMLLIndexStore(http: http, url: baseURL + "/metadata/raw-lyrics-index.jsonl", cache: cache,
                                      maxAge: indexMaxAge)
    }

    public func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate] {
        let entries = try await index.entries()
        let clean = query.cleanTitle
        let titleKeys = Set(([clean.core] + clean.alternates + [query.subtitle].compactMap { $0 })
            .map(QTLyricsTextFolding.comparisonKey).filter { !$0.isEmpty })
        guard !titleKeys.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [QTLyricsCandidate] = []
        for e in entries where !e.titleKeys.isDisjoint(with: titleKeys) {
            guard let (folder, id) = e.file, seen.insert(folder + "/" + id).inserted else { continue }
            out.append(QTLyricsCandidate(source: source, remoteID: id, title: e.titles.first ?? "",
                                         titleAliases: Array(e.titles.dropFirst()), artists: e.artists,
                                         album: e.album, syncHint: .word, extra: ["folder": folder]))
            if out.count >= 8 { break }
        }
        return out
    }

    public func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics? {
        let folder = candidate.extra["folder"] ?? "ncm-lyrics"
        let path = folder == "raw-lyrics" ? candidate.remoteID : candidate.remoteID + ".ttml"
        let data: Data
        do {
            data = try await QTLyricsRequest.send(QTLyricsRequest.get("\(baseURL)/\(folder)/\(path)"), with: http)
        } catch QTLyricsError.http(status: 404) {
            return nil
        }
        return QTTTMLParser.parse(data)
    }
}

/// One line of the AMLL metadata index.
struct QTAMLLIndexEntry: Sendable {
    var titles: [String]
    var artists: [String]
    var album: String?
    var ncmIDs: [String]
    var qqIDs: [String]
    var rawFile: String?
    var titleKeys: Set<String>

    /// Preferred file: NetEase-keyed, then QQ-keyed, then the raw submission.
    var file: (folder: String, id: String)? {
        if let id = ncmIDs.first { return ("ncm-lyrics", id) }
        if let id = qqIDs.first { return ("qq-lyrics", id) }
        if let raw = rawFile { return ("raw-lyrics", raw) }
        return nil
    }

    static func parse(jsonl data: Data) -> [QTAMLLIndexEntry] {
        var out: [QTAMLLIndexEntry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let meta = obj["metadata"] as? [[Any]] else { continue }
            var fields: [String: [String]] = [:]
            for pair in meta where pair.count == 2 {
                if let k = pair[0] as? String { fields[k] = QTJSON.strings(pair[1]) }
            }
            let titles = fields["musicName"] ?? []
            guard !titles.isEmpty else { continue }
            out.append(QTAMLLIndexEntry(
                titles: titles, artists: fields["artists"] ?? [], album: fields["album"]?.first,
                ncmIDs: fields["ncmMusicId"] ?? [], qqIDs: fields["qqMusicId"] ?? [], rawFile: obj["rawLyricFile"] as? String,
                titleKeys: Set(titles.map { QTLyricsTextFolding.comparisonKey(QTTitleCleaner.clean($0).core) })))
        }
        // Later submissions supersede earlier ones for the same song.
        return out.reversed()
    }
}

/// Loads the AMLL index once per process, persisted in the lyrics cache with a max age.
actor QTAMLLIndexStore {
    private let http: any QTLyricsHTTPClient
    private let url: String
    private let cache: QTLyricsCache?
    private let maxAge: TimeInterval
    private var loaded: [QTAMLLIndexEntry]?
    private var loading: Task<[QTAMLLIndexEntry], any Error>?

    init(http: any QTLyricsHTTPClient, url: String, cache: QTLyricsCache?, maxAge: TimeInterval) {
        self.http = http
        self.url = url
        self.cache = cache
        self.maxAge = maxAge
    }

    func entries() async throws -> [QTAMLLIndexEntry] {
        if let loaded { return loaded }
        if let loading { return try await loading.value }
        let task = Task { [http, url, cache, maxAge] () throws -> [QTAMLLIndexEntry] in
            if let cached = await cache?.blob(named: "amll-index"), Date().timeIntervalSince(cached.updated) < maxAge {
                return QTAMLLIndexEntry.parse(jsonl: cached.data)
            }
            let data = try await QTLyricsRequest.send(QTLyricsRequest.get(url), with: http)
            await cache?.setBlob(data, named: "amll-index")
            return QTAMLLIndexEntry.parse(jsonl: data)
        }
        loading = task
        defer { loading = nil }
        let result = try await task.value
        loaded = result
        return result
    }
}
