import Foundation
@preconcurrency import JavaScriptCore

// Native engine — signature / `n` challenge solving for the WEB_REMIX client (docs/native-engine-spike.md).
//
// Since 2025 YouTube's player (`base.js`, ~3 MB) is control-flow-flattened: the old regex extraction that yt-dlp,
// NewPipe and YouTube.js used breaks within days. yt-dlp now ships "EJS" (github.com/yt-dlp/ejs, Unlicense; bundles
// meriyah (ISC) + astring (MIT)): it parses the player into an AST, finds every candidate function, and runs the
// challenges through them in a real JS runtime. macOS has a JS runtime built in — JavaScriptCore — so the engine runs
// that solver in a `JSContext`, no extra binary. The solver is vendored (Resources/EJS, `Scripts/update-ejs.sh`).
//
// The first solve for a player release preprocesses the 3 MB player into a much smaller script (1–2 s of
// JavaScriptCore). `QTNativePlayerCache` keeps that result per player hash in Caches, so a launch with a known player
// skips both the player download and the preprocessing.

/// The current YouTube player script plus its solver context.
public final class QTNativePlayerScript: @unchecked Sendable {
    /// Player version hash (`/s/player/<hash>/`). Changes whenever YouTube ships a new player (cipher churn).
    public let playerHash: String
    /// `signatureTimestamp` (sts) web/TV clients must send so the server ciphers for this player.
    public let signatureTimestamp: Int?
    public let playerByteCount: Int
    /// Seconds to fetch the player script (0 when it came from the cache).
    public let fetchSeconds: Double
    /// Seconds the first solve took (AST preprocessing of the player) — nil until the first challenge, or when the
    /// preprocessed player came from the cache.
    public private(set) var preprocessSeconds: Double?
    /// When this script was fetched or read from the cache (uptime); the resolver re-checks the hash after a while.
    public let loadedAt = ProcessInfo.processInfo.systemUptime

    private let playerSource: String?
    private let lock = NSLock()
    private var context: JSContext?
    private var preprocessed: String?
    private var cache: [String: String] = [:]
    /// Called once with the preprocessed player after the first solve (the cache stores it).
    var onPreprocessed: (@Sendable (String) -> Void)?

    init(playerHash: String, source: String, fetchSeconds: Double) {
        self.playerHash = playerHash
        self.playerSource = source
        self.playerByteCount = source.utf8.count
        self.fetchSeconds = fetchSeconds
        signatureTimestamp = Self.signatureTimestamp(in: source)
    }

    /// From the cache: the preprocessed player only (the full player isn't needed to solve).
    init(playerHash: String, signatureTimestamp: Int?, preprocessed: String) {
        self.playerHash = playerHash
        self.playerSource = nil
        self.playerByteCount = 0
        self.fetchSeconds = 0
        self.signatureTimestamp = signatureTimestamp
        self.preprocessed = preprocessed
    }

    static func signatureTimestamp(in source: String) -> Int? {
        firstMatch(#"signatureTimestamp:(\d{5})"#, in: source).flatMap(Int.init)
            ?? firstMatch(#"sts:(\d{5})"#, in: source).flatMap(Int.init)
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// The current player's hash, from the embed API stub (a tiny response).
    public static func currentHash(session: URLSession) async throws -> String {
        let (stub, response) = try await session.data(from: URL(string: "https://www.youtube.com/iframe_api")!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw QTNativeStreamError.http(status) }
        let text = String(decoding: stub, as: UTF8.self)
        guard let hash = firstMatch(#"player\\?/([0-9a-zA-Z_-]{6,})"#, in: text) else {
            throw QTNativeStreamError.cipherUnsolved("player hash not found")
        }
        return hash
    }

    /// The current player: from `cache` when it knows the hash, else downloaded (and cached after its first solve).
    public static func fetchCurrent(session: URLSession, cache: QTNativePlayerCache? = nil) async throws -> QTNativePlayerScript {
        let start = ProcessInfo.processInfo.systemUptime
        let hash = try await currentHash(session: session)
        if let cache, let entry = cache.entry(for: hash) {
            return QTNativePlayerScript(playerHash: hash, signatureTimestamp: entry.signatureTimestamp, preprocessed: entry.preprocessed)
        }
        let url = URL(string: "https://www.youtube.com/s/player/\(hash)/player_ias.vflset/en_US/base.js")!
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw QTNativeStreamError.http(status) }
        let script = QTNativePlayerScript(playerHash: hash, source: String(decoding: data, as: UTF8.self),
                                          fetchSeconds: ProcessInfo.processInfo.systemUptime - start)
        if let cache {
            let sts = script.signatureTimestamp
            script.onPreprocessed = { cache.store(hash: hash, signatureTimestamp: sts, preprocessed: $0) }
        }
        return script
    }

    // MARK: Solving

    public enum Challenge: String, Sendable { case n, sig }

    /// Test hook: every solve fails (the engine's fallback path).
    nonisolated(unsafe) public static var debugFailSolves = false

    /// Solves challenges with the EJS solver in JavaScriptCore. The first call preprocesses the player (~1–2 s);
    /// later calls reuse the preprocessed script (5–70 ms).
    public func solve(_ type: Challenge, _ challenge: String) throws -> String {
        if Self.debugFailSolves { throw QTNativeStreamError.cipherUnsolved("forced failure (debug)") }
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache["\(type.rawValue):\(challenge)"] { return hit }
        let ctx = try solverContext()
        let started = ProcessInfo.processInfo.systemUptime
        let requests: [[String: Any]] = [["type": type.rawValue, "challenges": [challenge]]]
        let input: [String: Any]
        if let preprocessed {
            input = ["type": "preprocessed", "preprocessed_player": preprocessed, "requests": requests]
        } else if let playerSource {
            input = ["type": "player", "player": playerSource, "output_preprocessed": true, "requests": requests]
        } else {
            throw QTNativeStreamError.cipherUnsolved("no player")
        }
        guard let main = ctx.objectForKeyedSubscript("jsc"), let output = main.call(withArguments: [input]),
              ctx.exception == nil, let dict = output.toDictionary() else {
            let message = ctx.exception?.toString() ?? "solver returned nothing"
            ctx.exception = nil
            throw QTNativeStreamError.cipherUnsolved(message)
        }
        if preprocessed == nil, let result = dict["preprocessed_player"] as? String {
            preprocessed = result
            preprocessSeconds = ProcessInfo.processInfo.systemUptime - started
            onPreprocessed?(result)
            onPreprocessed = nil
        }
        guard let responses = dict["responses"] as? [[String: Any]], let first = responses.first else {
            throw QTNativeStreamError.cipherUnsolved("no responses")
        }
        guard first["type"] as? String == "result", let data = first["data"] as? [String: Any],
              let value = data[challenge] as? String else {
            throw QTNativeStreamError.cipherUnsolved(String(describing: first["error"] ?? "unsolved"))
        }
        if cache.count > 512 { cache.removeAll() }
        cache["\(type.rawValue):\(challenge)"] = value
        return value
    }

    private func solverContext() throws -> JSContext {
        if let context { return context }
        let sources = try QTNativeSolverSource.load()
        guard let ctx = JSContext() else { throw QTNativeStreamError.cipherUnsolved("no JSContext") }
        ctx.name = "QTube Music EJS solver"
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

/// Preprocessed players by hash, in Caches (`com.roderickqiu.qtube/native-player/<hash>.json`). Only YouTube's own
/// player code, never audio. Keeps the newest few.
public final class QTNativePlayerCache: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var playerHash: String
        public var signatureTimestamp: Int?
        public var preprocessed: String
        /// The solver release that produced it (a new solver re-preprocesses).
        public var solverVersion: String
    }

    public static let shared = QTNativePlayerCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.roderickqiu.qtube/native-player", directoryHint: .isDirectory))

    let directory: URL
    private let keep: Int
    private let lock = NSLock()

    public init(directory: URL, keep: Int = 3) {
        self.directory = directory
        self.keep = keep
    }

    private func file(_ hash: String) -> URL { directory.appending(path: "\(hash).json") }

    public func entry(for hash: String) -> Entry? {
        lock.withLock {
            guard let data = try? Data(contentsOf: file(hash)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.playerHash == hash, entry.solverVersion == QTNativeSolverSource.version else { return nil }
            return entry
        }
    }

    public func store(hash: String, signatureTimestamp: Int?, preprocessed: String) {
        let entry = Entry(playerHash: hash, signatureTimestamp: signatureTimestamp, preprocessed: preprocessed,
                          solverVersion: QTNativeSolverSource.version)
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: file(hash), options: .atomic)
            // Oldest first; drop all but the newest `keep`.
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let sorted = files.filter { $0.pathExtension == "json" }.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            for old in sorted.dropLast(keep) { try? FileManager.default.removeItem(at: old) }
        }
    }

    public func removeAll() {
        lock.withLock { try? FileManager.default.removeItem(at: directory) }
    }
}

private final class QTNativeSolverBundleFinder {}

/// The vendored yt-dlp EJS solver (Resources/EJS, pinned by `Scripts/update-ejs.sh`).
public enum QTNativeSolverSource {
    /// QTPlayback's resource bundle, looked up the way SwiftPM's generated `Bundle.module` does — but nil instead of
    /// its `fatalError` when the bundle is missing, so a broken app bundle makes the native engine fall back to the
    /// web engine (a solver error) rather than crash.
    static let resources: Bundle? = {
        let name = "QTubeMusic_QTPlayback.bundle"
        var candidates: [URL?] = []
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        #endif
        candidates += [Bundle.main.resourceURL, Bundle(for: QTNativeSolverBundleFinder.self).resourceURL, Bundle.main.bundleURL]
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    public static let version: String = {
        guard let url = resources?.url(forResource: "VERSION", withExtension: nil, subdirectory: "EJS"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "unknown" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    static func load() throws -> (lib: String, core: String) {
        func read(_ name: String) throws -> String {
            guard let url = resources?.url(forResource: name, withExtension: "js", subdirectory: "EJS") else {
                throw QTNativeStreamError.cipherUnsolved("solver \(name).js missing from the app bundle")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return (try read("yt.solver.lib"), try read("yt.solver.core"))
    }
}
