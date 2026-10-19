import Foundation
import os
import QTInnerTube

// Native engine — getting a track's audio into memory: resolve (WEB_REMIX, signed in) → download in ≤ 10 MB range
// requests with the resolving client's User-Agent → `QTNativeAudioBytes`. Nothing is written to disk.
//
// Recovery, before anything is reported as a failure:
//  - googlevideo refuses the URL (403/410): resolve again with a re-checked player (signatures follow the player), once;
//  - the solver fails: check for a new player and solve again, once.
// What is still failing after that is a `QTNativeFailure` — systemic (the engine falls back to YouTube's player for
// the session) or about the item.
//
// A few tracks stay in memory (current, next, previous): Previous and gapless/crossfade never wait on the network.

/// One track's audio, ready to decode.
public struct QTNativeTrackAudio: Sendable {
    public let videoId: String
    let bytes: QTNativeAudioBytes
    public let stream: QTNativeResolvedStream
    /// Seconds from asking to having the bytes (0 for a memory hit).
    public let fetchSeconds: Double
    public var byteCount: Int { bytes.data.count }
}

public actor QTNativeAudioFetcher {
    static let log = Logger(subsystem: "com.roderickqiu.qtube", category: "native")
    /// Largest single range request (bigger ones get throttled or refused).
    public static let chunkSize = 10 * 1024 * 1024
    /// Tracks kept in memory.
    public static let memoryLimit = 4

    private let resolver: QTNativeStreamResolver
    private let session: URLSession
    private var memory: [(videoId: String, audio: QTNativeTrackAudio)] = []
    private var inFlight: [String: Task<QTNativeTrackAudio, any Error>] = [:]

    public init(resolver: QTNativeStreamResolver, session: URLSession = QTURLSessionTransport.makeSession()) {
        self.resolver = resolver
        self.session = session
    }

    /// The track's audio: from memory, joining a fetch already running (a prefetch), or fetched now.
    public func audio(for videoId: String) async throws -> QTNativeTrackAudio {
        if let i = memory.firstIndex(where: { $0.videoId == videoId }) {
            let hit = memory.remove(at: i)
            memory.append(hit)
            return QTNativeTrackAudio(videoId: videoId, bytes: hit.audio.bytes, stream: hit.audio.stream, fetchSeconds: 0)
        }
        if let running = inFlight[videoId] { return try await running.value }
        let task = Task { try await self.fetch(videoId) }
        inFlight[videoId] = task
        defer { inFlight[videoId] = nil }
        let audio = try await task.value
        remember(audio)
        return audio
    }

    /// Starts fetching in the background (the next track); errors surface when the track is asked for.
    public func prefetch(_ videoId: String) {
        guard !memory.contains(where: { $0.videoId == videoId }), inFlight[videoId] == nil else { return }
        let task = Task { try await self.fetch(videoId) }
        inFlight[videoId] = task
        Task {
            let audio = try? await task.value
            self.finishPrefetch(videoId, audio)
        }
    }

    public func isInMemory(_ videoId: String) -> Bool { memory.contains { $0.videoId == videoId } }

    /// Drops everything in memory (sign-out, the engine going away).
    public func purge() {
        memory.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    private func finishPrefetch(_ videoId: String, _ audio: QTNativeTrackAudio?) {
        inFlight[videoId] = nil
        if let audio { remember(audio) }
    }

    private func remember(_ audio: QTNativeTrackAudio) {
        memory.removeAll { $0.videoId == audio.videoId }
        memory.append((audio.videoId, audio))
        if memory.count > Self.memoryLimit { memory.removeFirst(memory.count - Self.memoryLimit) }
    }

    private func fetch(_ videoId: String) async throws -> QTNativeTrackAudio {
        let start = ProcessInfo.processInfo.systemUptime
        var retried = false
        while true {
            try Task.checkCancellation()
            do {
                let stream = try await resolver.resolvePremium(videoId: videoId)
                let resolved = ProcessInfo.processInfo.systemUptime
                let data = try await download(stream)
                let done = ProcessInfo.processInfo.systemUptime
                Self.log.info("native fetch \(videoId, privacy: .public): resolve \(resolved - start, format: .fixed(precision: 3)) s, download \(done - resolved, format: .fixed(precision: 3)) s, \(data.count) bytes, itag \(stream.format.itag)")
                return QTNativeTrackAudio(videoId: videoId, bytes: QTNativeAudioBytes(data), stream: stream,
                                          fetchSeconds: done - start)
            } catch let error as CancellationError {
                throw error
            } catch {
                let failure = QTNativeFailure.from(error)
                // Signatures and URLs follow the player: a refused URL or a failed solve gets one more try with a
                // re-checked player before it counts.
                guard failure.isSystemic, !retried, Self.isRetryable(error) else { throw failure }
                retried = true
                await resolver.invalidatePlayer()
            }
        }
    }

    static func isRetryable(_ error: any Error) -> Bool {
        if case .http(let code)? = error as? QTNativeStreamError { return code == 403 || code == 410 }
        if case .systemic(let reason)? = error as? QTNativeFailure {
            return reason.hasPrefix("solver") || reason == "HTTP 403" || reason == "HTTP 410"
        }
        return false
    }

    /// The whole file into memory, in ≤ `chunkSize` range requests.
    private func download(_ stream: QTNativeResolvedStream) async throws -> Data {
        var data = Data()
        if let total = stream.format.contentLength { data.reserveCapacity(total) }
        let total = stream.format.contentLength
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let end = total.map { min($0, offset + Self.chunkSize) - 1 } ?? (offset + Self.chunkSize - 1)
            var request = URLRequest(url: stream.url)
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (chunk, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 206 || status == 200 else {
                if status == 403 || status == 410 { await resolver.forget(videoId: stream.videoId) }
                throw QTNativeStreamError.http(status)
            }
            data.append(chunk)
            offset += chunk.count
            if chunk.isEmpty || status == 200 { break }
        } while offset < (total ?? 0)
        guard !data.isEmpty else { throw QTNativeFailure.item("empty media") }
        return data
    }
}
