import Foundation

#if DEBUG
/// DEBUG ONLY. The session Keychain item shared by every dev build (`QT_VARIANT` apps, the integrator's app, the
/// `QTDevSession` tool) without ever showing a Keychain dialog.
///
/// Why not `SecItem*` directly: ad-hoc signed builds get a new code hash on every rebuild, and macOS stamps each
/// Keychain item with its creator's partition (`cdhash:<hash>`). Any other build reading it — even with an
/// "any application" ACL — needs the user's Keychain password (a dialog). So dev builds never touch the item through
/// the Security framework. They go through Apple's `/usr/bin/security` tool, whose partition (`apple-tool:`) is
/// stable, and create the item with `-A` (any application, no prompt). Release builds keep the normal per-app item
/// (`QTKeychainStore`).
///
/// - Service `com.roderickqiu.qtube` (shared), account `youtube-music-session.dev` (the head) plus
///   `youtube-music-session.dev.<generation>.<n>` chunks: the tool's interactive mode reads lines of at most ~4 KB, so
///   the zlib-compressed, base64 session is split; the head names the generation and chunk count.
/// - Items are never updated in place (an in-place update of an "any application" item wakes SecurityAgent, even
///   though it shows nothing): a write adds a new generation, swaps the head, then deletes the old generation.
/// - Every item carries the comment `qt-dev-shared-v1`. Before reading a secret we check that marker on the item's
///   attributes (an attribute read never prompts); an item without it (e.g. made by a release build) is ignored, so
///   the tool is never asked to decrypt something that would prompt.
/// - Secrets travel through pipes only (stdin/stdout of the tool), never argv, files or logs.
public struct QTDevSharedKeychainStore: QTSecureStore {
    public static let marker = "qt-dev-shared-v1"
    public static let defaultAccount = "youtube-music-session.dev"
    static let tool = "/usr/bin/security"
    /// base64 characters per item; keeps every `security -i` line well under its 4 KB buffer.
    static let chunkSize = 3000

    public let service: String
    public let account: String

    public init(service: String = QTKeychainStore.defaultService, account: String = QTDevSharedKeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    /// Chunk `index` (≥ 1) of generation `generation`.
    func chunkAccount(_ index: Int, generation: String) -> String { "\(account).\(generation).\(index)" }

    /// The head's value: "qt2;<generation>;<count>;<chunk 0>" (or the first format, "qt1;<count>;<chunk 0>" with
    /// chunks at `<account>.<n>`, still read so an existing session survives the upgrade).
    struct Head {
        var generation: String?
        var count: Int
        var first: String

        init?(_ value: String) {
            let parts = value.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count >= 3, parts[0] == "qt1", let count = Int(parts[1]), (1..<64).contains(count) {
                generation = nil
                self.count = count
                first = parts.dropFirst(2).joined(separator: ";")
                return
            }
            guard parts.count == 4, parts[0] == "qt2", let count = Int(parts[2]), (1..<64).contains(count) else { return nil }
            generation = String(parts[1])
            self.count = count
            first = String(parts[3])
        }
    }

    func chunkAccount(_ index: Int, of head: Head) -> String {
        head.generation.map { chunkAccount(index, generation: $0) } ?? "\(account).\(index)"
    }

    // MARK: QTSecureStore

    public func read() throws -> Data? {
        guard let value = try secret(account: account) else { return nil }
        guard let head = Head(value) else { throw QTAuthError.encoding }
        var base64 = head.first
        for i in 1..<head.count {
            // Chunks are written in the same tool session as their (verified) head.
            guard let chunk = try secret(account: chunkAccount(i, of: head), verified: true) else {
                throw QTAuthError.encoding
            }
            base64 += chunk
        }
        guard let packed = Data(base64Encoded: base64),
              let data = try? (packed as NSData).decompressed(using: .zlib) as Data else { throw QTAuthError.encoding }
        return data
    }

    public func write(_ data: Data) throws {
        guard let packed = try? (data as NSData).compressed(using: .zlib) as Data else { throw QTAuthError.encoding }
        let base64 = packed.base64EncodedString()
        var chunks: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: Self.chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append(String(base64[index..<end]))
            index = end
        }
        if chunks.isEmpty { chunks = [""] }
        let hasHead = try hasMarkedItem(account: account)
        let previous = hasHead ? try secret(account: account, verified: true).flatMap(Head.init) : nil
        let generation = String(UInt32.random(in: 0...UInt32.max), radix: 16)
        var lines: [String] = []
        for (i, chunk) in chunks.enumerated().dropFirst() {
            lines.append(addLine(account: chunkAccount(i, generation: generation), value: chunk))
        }
        if hasHead { lines.append("delete-generic-password -s \(service) -a \(account)") }
        lines.append(addLine(account: account, value: "qt2;\(generation);\(chunks.count);\(chunks[0])"))
        let result = try run(arguments: ["-i"], input: lines.joined(separator: "\n") + "\n")
        // Interactive mode keeps going after a failed line; any "security: …" diagnostic means a part is missing.
        if result.errors.contains("security:") { throw QTAuthError.keychain(status: -2) }
        if let previous {
            for i in 1..<previous.count { try? deleteItem(account: chunkAccount(i, of: previous)) }
        }
    }

    public func delete() throws {
        let previous = try? secret(account: account).flatMap(Head.init)
        try deleteItem(account: account)
        if let previous {
            for i in 1..<previous.count { try? deleteItem(account: chunkAccount(i, of: previous)) }
        }
    }

    // MARK: Tool plumbing

    private func addLine(account: String, value: String) -> String {
        // New items only (no -U). base64, ';' and hex need no quoting; the label is quoted.
        "add-generic-password -A -s \(service) -a \(account) -j \(Self.marker) -l \"QTube Music dev session\" -w \(value)"
    }

    /// Whether an item exists and carries our marker (attributes only — never prompts).
    func hasMarkedItem(account: String) throws -> Bool {
        let result = try run(arguments: ["find-generic-password", "-s", service, "-a", account], allowFailure: true)
        guard result.status == 0 else { return false }
        return result.output.contains("\"icmt\"<blob>=\"\(Self.marker)\"")
    }

    private func secret(account: String, verified: Bool = false) throws -> String? {
        if !verified { guard try hasMarkedItem(account: account) else { return nil } }
        let result = try run(arguments: ["find-generic-password", "-s", service, "-a", account, "-w"], allowFailure: true)
        guard result.status == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deleteItem(account: String) throws {
        guard try hasMarkedItem(account: account) else { return }
        try run(arguments: ["delete-generic-password", "-s", service, "-a", account])
    }

    @discardableResult
    private func run(arguments: [String], input: String? = nil, allowFailure: Bool = false) throws
        -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tool)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        let inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = inPipe
        do { try process.run() } catch { throw QTAuthError.keychain(status: -1) }
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0, !allowFailure { throw QTAuthError.keychain(status: status) }
        return (status, String(decoding: data, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }
}
#endif

public extension QTKeychainStore {
    /// The store the app uses: the shared, prompt-free dev item in DEBUG builds; the per-app Keychain item otherwise.
    static var appDefault: any QTSecureStore {
        #if DEBUG
        QTDevSharedKeychainStore()
        #else
        QTKeychainStore()
        #endif
    }
}
