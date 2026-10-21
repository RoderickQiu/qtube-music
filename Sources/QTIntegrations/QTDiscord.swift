import Darwin
import Foundation

// Discord Rich Presence over the Discord desktop app's local IPC socket (`$TMPDIR/discord-ipc-0` … `-9`; no
// network from us). Frames: little-endian UInt32 opcode, little-endian UInt32 payload length, UTF-8 JSON.
// Opcode 0 = handshake `{"v":1,"client_id":…}`, 1 = frame (`SET_ACTIVITY` command), 2 = close, 3/4 = ping/pong.

public enum QTDiscordOpcode: UInt32, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

public enum QTDiscordIPC {
    public static let headerSize = 8

    public static func encode(_ opcode: QTDiscordOpcode, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        withUnsafeBytes(of: opcode.rawValue.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    public static func encode(_ opcode: QTDiscordOpcode, json: [String: Any]) throws -> Data {
        encode(opcode, payload: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
    }

    /// One frame from the front of `buffer`: (opcode, payload, bytes consumed), or nil if incomplete.
    public static func decode(_ buffer: Data) -> (opcode: UInt32, payload: Data, consumed: Int)? {
        guard buffer.count >= headerSize else { return nil }
        let bytes = [UInt8](buffer.prefix(headerSize))
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        let length = Int(u32(4))
        guard buffer.count >= headerSize + length else { return nil }
        let start = buffer.startIndex + headerSize
        return (u32(0), Data(buffer[start..<(start + length)]), headerSize + length)
    }

    public static func handshake(clientID: String) throws -> Data {
        try encode(.handshake, json: ["v": 1, "client_id": clientID])
    }

    /// `SET_ACTIVITY` with `activity` (nil clears the presence).
    public static func setActivity(_ activity: [String: Any]?, pid: Int32, nonce: String) throws -> Data {
        var args: [String: Any] = ["pid": Int(pid)]
        args["activity"] = activity ?? NSNull()
        return try encode(.frame, json: ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce])
    }

    /// Candidate socket paths, in Discord's order (`XDG_RUNTIME_DIR`, `TMPDIR`, `TMP`, `TEMP`, `/tmp`).
    public static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let dirs = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] } + ["/tmp"]
        var seen = Set<String>()
        return dirs.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { seen.insert($0).inserted }
            .flatMap { dir in (0...9).map { "\(dir)/discord-ipc-\($0)" } }
    }
}

/// What the presence shows for one track.
public struct QTDiscordTrack: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String?
    /// Public https URL of the artwork (Discord fetches it); nil = no image.
    public var artworkURL: URL?
    /// Link for the "Open in YouTube Music" button.
    public var link: URL?
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var isPlaying: Bool
    /// A song the user uploaded to their own library: its link and artwork are private, so neither is shown.
    public var isPrivatelyOwned: Bool

    public init(title: String, artist: String, album: String? = nil, artworkURL: URL? = nil, link: URL? = nil,
                duration: TimeInterval, elapsed: TimeInterval, isPlaying: Bool, isPrivatelyOwned: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.link = link
        self.duration = duration
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.isPrivatelyOwned = isPrivatelyOwned
    }
}

public enum QTDiscordActivity {
    /// Discord limits activity strings to 2…128 characters.
    static func clamp(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let padded = t.count < 2 ? t + "  ".prefix(2 - t.count) : t
        return padded.count > 128 ? String(padded.prefix(127)) + "…" : padded
    }

    /// A "Listening to" activity (type 2): title, artist, album art, elapsed/remaining while playing. Paused tracks
    /// show without timestamps. `buttonTitle` is the localized label of the link button. A private upload shows its
    /// title and artist only (no artwork URL, no link).
    public static func payload(for t: QTDiscordTrack, now: Date = Date(), showsArtwork: Bool = true,
                               buttonTitle: String? = nil) -> [String: Any] {
        var activity: [String: Any] = [
            "type": 2,
            "details": clamp(t.title),
            "state": clamp(t.artist),
        ]
        if t.isPlaying, t.duration > 0 {
            let start = now.addingTimeInterval(-t.elapsed)
            activity["timestamps"] = [
                "start": Int((start.timeIntervalSince1970 * 1000).rounded()),
                "end": Int((start.addingTimeInterval(t.duration).timeIntervalSince1970 * 1000).rounded()),
            ]
        }
        var assets: [String: Any] = [:]
        if showsArtwork, !t.isPrivatelyOwned, let art = t.artworkURL, art.scheme == "https" {
            assets["large_image"] = art.absoluteString
            assets["large_text"] = clamp(t.album?.isEmpty == false ? t.album! : t.title)
        }
        if !assets.isEmpty { activity["assets"] = assets }
        if !t.isPrivatelyOwned, let link = t.link, let buttonTitle {
            activity["buttons"] = [["label": String(buttonTitle.prefix(32)), "url": link.absoluteString]]
        }
        return activity
    }
}

/// Connects to the local Discord client and keeps one presence up to date. Silently idle when Discord isn't
/// running; reconnects on the next update.
public actor QTDiscordPresence {
    private var fd: Int32 = -1
    private var connectedClientID: String?
    private var nonce = 0
    private let paths: [String]

    public init(paths: [String] = QTDiscordIPC.socketPaths()) {
        self.paths = paths
    }

    public var isConnected: Bool { fd >= 0 }

    /// Shows `track` (nil clears the presence). Connects (handshake) on first use or after Discord restarted.
    @discardableResult
    public func update(clientID: String, track: QTDiscordTrack?, showsArtwork: Bool = true, buttonTitle: String? = nil) -> Bool {
        if connectedClientID != clientID { disconnect() }
        if fd < 0, !connect(clientID: clientID) { return false }
        nonce += 1
        let activity = track.map { QTDiscordActivity.payload(for: $0, showsArtwork: showsArtwork, buttonTitle: buttonTitle) }
        guard let frame = try? QTDiscordIPC.setActivity(activity, pid: getpid(), nonce: "qt-\(nonce)"),
              write(frame) else {
            disconnect()
            return false
        }
        drain()
        return true
    }

    public func disconnect() {
        if fd >= 0 {
            if let close = try? QTDiscordIPC.encode(.close, json: [:]) { _ = write(close) }
            Darwin.close(fd)
        }
        fd = -1
        connectedClientID = nil
    }

    private func connect(clientID: String) -> Bool {
        for path in paths {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A Discord client that stops reading must not block this actor's thread for good: a send gives up after
            // `sendTimeoutMicroseconds` (the presence is dropped and reconnects on the next update).
            var timeout = timeval(tv_sec: 0, tv_usec: Self.sendTimeoutMicroseconds)
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            if ok {
                fd = s
                guard let hello = try? QTDiscordIPC.handshake(clientID: clientID), write(hello) else {
                    disconnect()
                    return false
                }
                connectedClientID = clientID
                drain()
                return true
            }
            Darwin.close(s)
        }
        return false
    }

    /// How long one `send` may wait for Discord to read (0.5 s).
    static let sendTimeoutMicroseconds: Int32 = 500_000

    private func write(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Reads (and ignores) whatever Discord answered, without blocking.
    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Darwin.recv(fd, &buffer, buffer.count, MSG_DONTWAIT) > 0 {}
    }
}
