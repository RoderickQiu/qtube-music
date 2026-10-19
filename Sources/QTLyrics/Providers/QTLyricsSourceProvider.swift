import Foundation
import QTCore

/// One lyrics source in the chain (YouTube Music, LRCLIB, AMLL, NetEase, Kugou, QQ). Search returns candidates
/// (metadata only); `lyrics(for:)` fetches and parses one of them. Providers never score — the resolver does.
public protocol QTLyricsSourceProvider: Sendable {
    var source: QTLyricsSource { get }
    func search(_ query: QTLyricsQuery) async throws -> [QTLyricsCandidate]
    func lyrics(for candidate: QTLyricsCandidate) async throws -> QTParsedLyrics?
}

/// Small JSON helpers for loosely-typed responses (InnerTube, NetEase).
enum QTJSON {
    static func object(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw QTLyricsError.decoding("invalid JSON") }
    }

    /// Depth-first search for every value stored under `key`.
    static func find(_ key: String, in value: Any, limit: Int = .max) -> [Any] {
        var out: [Any] = []
        func walk(_ v: Any) {
            guard out.count < limit else { return }
            if let d = v as? [String: Any] {
                for (k, child) in d {
                    if k == key { out.append(child); if out.count >= limit { return } }
                    walk(child)
                }
            } else if let a = v as? [Any] {
                for child in a { walk(child) }
            }
        }
        walk(value)
        return out
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func strings(_ v: Any?) -> [String] {
        (v as? [Any])?.compactMap { string($0) }.filter { !$0.isEmpty } ?? []
    }
}
