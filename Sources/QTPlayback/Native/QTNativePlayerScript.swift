import Foundation
@preconcurrency import JavaScriptCore

// M5 SPIKE — signature / `n` challenge solving for web and TV clients.
//
// Since 2025 YouTube's player (`base.js`, ~3 MB) is control-flow-flattened: the old regex extraction that yt-dlp,
// NewPipe and YouTube.js used breaks within days. yt-dlp now ships "EJS" (github.com/yt-dlp/ejs, Unlicense; bundles
// meriyah (ISC) + astring (MIT)): it parses the player into an AST, finds every candidate function, and runs the
// challenges through them in a real JS runtime. macOS has a JS runtime built in — JavaScriptCore — so the spike runs
// that solver in a `JSContext`, no extra binary.
//
// The solver is NOT vendored (third-party code needs the user's OK): `QTNativeSolverSource` downloads the pinned
// release into the user Caches folder on first use. Shipping the native engine would mean vendoring ~370 KB of JS
// or writing our own AST matcher (a permanent arms race).

/// The current YouTube player script plus its solver context.
public final class QTNativePlayerScript: @unchecked Sendable {
    /// Player version hash (`/s/player/<hash>/`). Changes whenever YouTube ships a new player (cipher churn).
    public let playerHash: String
    /// `signatureTimestamp` (sts) web/TV clients must send so the server ciphers for this player.
    public let signatureTimestamp: Int?
    public let playerByteCount: Int
    /// Seconds to fetch the player script.
    public let fetchSeconds: Double
    /// Seconds the first solve took (AST preprocessing of the player) — nil until the first challenge.
    public private(set) var preprocessSeconds: Double?

    private let playerSource: String
    private let lock = NSLock()
    private var context: JSContext?
    private var preprocessed: String?
    private var cache: [String: String] = [:]

    init(playerHash: String, source: String, fetchSeconds: Double) {
        self.playerHash = playerHash
        self.playerSource = source
        self.playerByteCount = source.utf8.count
        self.fetchSeconds = fetchSeconds
        signatureTimestamp = Self.firstMatch(#"signatureTimestamp:(\d{5})"#, in: source).flatMap(Int.init)
            ?? Self.firstMatch(#"sts:(\d{5})"#, in: source).flatMap(Int.init)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// The player hash from the embed API stub (tiny response), then the player itself.
    public static func fetchCurrent(session: URLSession) async throws -> QTNativePlayerScript {
        let start = ProcessInfo.processInfo.systemUptime
        let (stub, _) = try await session.data(from: URL(string: "https://www.youtube.com/iframe_api")!)
        let text = String(decoding: stub, as: UTF8.self)
        guard let hash = firstMatch(#"player\\?/([0-9a-zA-Z_-]{6,})"#, in: text) else {
            throw QTNativeStreamError.cipherUnsolved("player hash not found")
        }
        let url = URL(string: "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_US/base.js")!
        let (data, _) = try await session.data(from: url)
        return QTNativePlayerScript(playerHash: hash, source: String(decoding: data, as: UTF8.self),
                                    fetchSeconds: ProcessInfo.processInfo.systemUptime - start)
    }

    // MARK: Solving

    public enum Challenge: String, Sendable { case n, sig }

    /// Solves challenges with the EJS solver in JavaScriptCore. The first call preprocesses the player (~1 s);
    /// later calls reuse the preprocessed script (~20 ms) — that string is what a shipping engine would cache per
    /// player hash.
    public func solve(_ type: Challenge, _ challenge: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache["\(type.rawValue):\(challenge)"] { return hit }
        let ctx = try solverContext()
        let started = ProcessInfo.processInfo.systemUptime
        let input: [String: Any] = preprocessed.map {
            ["type": "preprocessed", "preprocessed_player": $0,
             "requests": [["type": type.rawValue, "challenges": [challenge]]]]
        } ?? ["type": "player", "player": playerSource, "output_preprocessed": true,
              "requests": [["type": type.rawValue, "challenges": [challenge]]]]
        guard let main = ctx.objectForKeyedSubscript("jsc"), let output = main.call(withArguments: [input]),
              ctx.exception == nil, let dict = output.toDictionary() else {
            let message = ctx.exception?.toString() ?? "solver returned nothing"
            ctx.exception = nil
            throw QTNativeStreamError.cipherUnsolved(message)
        }
        if preprocessed == nil {
            preprocessed = dict["preprocessed_player"] as? String
            preprocessSeconds = ProcessInfo.processInfo.systemUptime - started
        }
        guard let responses = dict["responses"] as? [[String: Any]], let first = responses.first else {
            throw QTNativeStreamError.cipherUnsolved("no responses")
        }
        guard first["type"] as? String == "result", let data = first["data"] as? [String: Any],
              let value = data[challenge] as? String else {
            throw QTNativeStreamError.cipherUnsolved(String(describing: first["error"] ?? "unsolved"))
        }
        cache["\(type.rawValue):\(challenge)"] = value
        return value
    }

    private func solverContext() throws -> JSContext {
        if let context { return context }
        let sources = try QTNativeSolverSource.load()
        guard let ctx = JSContext() else { throw QTNativeStreamError.cipherUnsolved("no JSContext") }
        ctx.name = "QTNativeSpike EJS solver"
        ctx.evaluateScript(sources.lib)
        ctx.evaluateScript("var meriyah = lib.meriyah, astring = lib.astring;")
        ctx.evaluateScript(sources.core)
        if let e = ctx.exception { throw QTNativeStreamError.cipherUnsolved("solver load: \(e)") }
        context = ctx
        return ctx
    }

    /// The parts of a `signatureCipher` (`s=…&sp=sig&url=…`): scrambled signature, its query name, base URL.
    public static func parseSignatureCipher(_ signatureCipher: String) -> (s: String, sp: String, url: URLComponents)? {
        var parts: [String: String] = [:]
        for pair in signatureCipher.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            parts[String(kv[0])] = String(kv[1]).removingPercentEncoding
        }
        guard let s = parts["s"], let base = parts["url"], let comps = URLComponents(string: base) else { return nil }
        return (s, parts["sp"] ?? "signature", comps)
    }

    /// `signatureCipher` → signed URL.
    public func decipher(_ signatureCipher: String) throws -> URL {
        guard let parts = Self.parseSignatureCipher(signatureCipher) else {
            throw QTNativeStreamError.cipherUnsolved("malformed signatureCipher")
        }
        var comps = parts.url
        let signature = try solve(.sig, parts.s)
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: parts.sp, value: signature)]
        guard let url = comps.url else { throw QTNativeStreamError.cipherUnsolved("bad URL") }
        return url
    }

    /// Rewrites the `n` parameter, if the URL has one (an untransformed `n` historically meant throttled or refused media).
    public func transformN(_ url: URL) throws -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let index = comps.queryItems?.firstIndex(where: { $0.name == "n" }),
              let n = comps.queryItems?[index].value else { return url }
        comps.queryItems?[index].value = try solve(.n, n)
        return comps.url ?? url
    }
}

/// Fetches the pinned yt-dlp EJS solver release into ~/Library/Caches (never into the repo).
public enum QTNativeSolverSource {
    public static let version = "0.8.0"

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.roderickqiu.qtube.native-spike/ejs-\(version)", directoryHint: .isDirectory)
    }

    public static func ensureDownloaded() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["yt.solver.lib.js", "yt.solver.core.js"] {
            let dest = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            let url = URL(string: "https://github.com/yt-dlp/ejs/releases/download/\(version)/\(name)")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw QTNativeStreamError.http(-1) }
            try data.write(to: dest, options: .atomic)
        }
    }

    static func load() throws -> (lib: String, core: String) {
        let lib = try String(contentsOf: directory.appending(path: "yt.solver.lib.js"), encoding: .utf8)
        let core = try String(contentsOf: directory.appending(path: "yt.solver.core.js"), encoding: .utf8)
        return (lib, core)
    }
}
