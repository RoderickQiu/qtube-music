import Foundation

/// Runs main-actor code from AppKit / Foundation callbacks (notification blocks, KVO, timers, AX getters, WebKit
/// delegates) without `MainActor.assumeIsolated`.
///
/// `assumeIsolated` asks the concurrency runtime which executor is current. On macOS 27 that check itself crashed
/// (`swift_task_isMainExecutorImpl` → `swift_getObjectType` on a bad executor, EXC_BAD_ACCESS) in a window
/// notification AppKit posted on the main thread while it set up the status item's scene
/// (QTubeMusic-2026-10-19-003124.ips). These helpers decide by the thread instead: on the main thread the body runs
/// synchronously (the main thread is the main actor's executor); anywhere else it hops onto the main actor.
public enum QTMainActorHop {
    /// Runs `body` now when called on the main thread, otherwise asynchronously on the main actor.
    /// For callbacks whose work may land a moment later (notifications, KVO, cookie observers, timers).
    public static func run(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            onMainThread(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    /// Runs `body` synchronously and returns its value. Off the main thread it waits for the main queue
    /// (`DispatchQueue.main.sync`), so never call it from work the main thread itself is waiting on.
    public static func sync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return onMainThread(body) }
        return withoutActuallyEscaping(body) { escapable in
            let box = QTUncheckedSendableBox(escapable)
            return DispatchQueue.main.sync { onMainThread(box.value) }
        }
    }

    /// `body` run with its main-actor isolation taken as given. Only valid on the main thread (checked).
    @discardableResult
    public static func onMainThread<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread, "QTMainActorHop.onMainThread called off the main thread")
        typealias Isolated = @MainActor () throws -> T
        typealias Plain = () throws -> T
        return try withoutActuallyEscaping(body) { (escapable: @escaping Isolated) throws -> T in
            try unsafeBitCast(escapable, to: Plain.self)()
        }
    }
}

/// Carries a non-Sendable value across a synchronous hop the caller blocks on.
struct QTUncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
