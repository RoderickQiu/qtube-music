import AppKit
import Foundation

/// Tells Scripts/shoot.sh when the first frame is settled: writes `-qt.readyFile <path>` (JSON with pid and
/// window numbers) once launch finished and every hold (artwork loads, lyrics fetches…) is released.
/// Anything that loads asynchronously during launch should `hold` and `release`; after the file is written
/// holds become no-ops.
@MainActor
public final class QTReadiness {
    public static let shared = QTReadiness()

    public private(set) var isReady = false
    private var holds: [UUID: String] = [:]
    private var launchFinished = false
    private var path: String?
    private var settle: Duration = .milliseconds(400)
    private var pending: Task<Void, Never>?

    public func configure(readyFile: String?, settle: Duration = .milliseconds(400)) {
        path = readyFile
        self.settle = settle
    }

    /// Registers something the first frame waits for. Returns a token for `release`.
    @discardableResult
    public func hold(_ reason: String) -> UUID {
        let id = UUID()
        guard !isReady else { return id }
        holds[id] = reason
        pending?.cancel()
        return id
    }

    public func release(_ token: UUID) {
        guard holds.removeValue(forKey: token) != nil else { return }
        check()
    }

    /// Call once the launch options were applied and the windows exist.
    public func markLaunchFinished() {
        launchFinished = true
        check()
    }

    private func check() {
        guard launchFinished, holds.isEmpty, !isReady else { return }
        pending?.cancel()
        pending = Task { @MainActor [settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, self.holds.isEmpty, !self.isReady else { return }
            self.isReady = true
            self.write()
        }
    }

    private func write() {
        guard let path else { return }
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map {
            ["identifier": $0.identifier?.rawValue ?? "", "number": $0.windowNumber, "title": $0.title,
             "frame": NSStringFromRect($0.frame)]
        }
        let info: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "windows": windows,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
