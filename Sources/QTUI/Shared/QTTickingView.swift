import AppKit
import QTCore
import SwiftUI

// Added by builder "perf". The one way to redraw a SwiftUI view on a clock (scrubber, ad countdowns, progress
// lines, the current-lyric line). Don't use `TimelineView(.periodic)` / `.animation` for these: on macOS 26+ a TimelineView
// re-checks its schedule on every display frame (`UpdateFilter<PeriodicTimelineSchedule>` in the SwiftUI
// instrument), so a 4 Hz scrubber kept the whole window's view graph and layout running at the display's refresh
// rate — ~10–12 % CPU on a 120 Hz panel for one moving bar. This wakes only at its cadence, and not at all while
// its window is hidden or fully covered, or while the host says it is covered (`qtPausesTimeDrivenViews`).

/// Re-evaluates `content` on a clock while `isRunning`, its window is visible on screen and no ancestor has set
/// `qtPausesTimeDrivenViews`; re-renders once right away when any of those turns back on.
///
/// - `every:` a fixed cadence (scrubber 4 Hz, countdowns).
/// - `nextChange:` event-driven — wakes exactly when the content will next look different (the next lyric word
///   or line), re-asked after every wake; `restartOn` (e.g. the playback timeline) re-plans after a seek.
struct QTTickingView<Content: View>: View {
    private enum Cadence {
        case every(Duration)
        /// Seconds until the content next changes; nil = nothing scheduled (re-checked every 2 s).
        case until(() -> TimeInterval?)
    }

    private let cadence: Cadence
    private let isRunning: Bool
    private let restartKey: AnyHashable
    private let content: () -> Content

    @State private var tick: UInt64 = 0
    @State private var isWindowVisible = true
    @Environment(\.qtPausesTimeDrivenViews) private var pausedByHost

    init(every interval: Duration, isRunning: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        cadence = .every(interval)
        self.isRunning = isRunning
        restartKey = 0
        self.content = content
    }

    init(isRunning: Bool, restartOn key: some Hashable, nextChange: @escaping () -> TimeInterval?,
         @ViewBuilder content: @escaping () -> Content) {
        cadence = .until(nextChange)
        self.isRunning = isRunning
        restartKey = AnyHashable(key)
        self.content = content
    }

    private var runs: Bool { isRunning && isWindowVisible && !pausedByHost }

    private struct TaskKey: Hashable {
        var runs: Bool
        var restart: AnyHashable
    }

    var body: some View {
        let _ = tick  // the dependency that re-runs `content` on each tick
        ZStack { content() }
            .background(QTWindowVisibilityReader(isVisible: $isWindowVisible))
            .task(id: TaskKey(runs: runs, restart: restartKey)) {
                guard runs else { return }
                let clock = ContinuousClock()
                while !Task.isCancelled {
                    let delay: Duration, tolerance: Duration
                    switch cadence {
                    case .every(let interval):
                        delay = interval
                        tolerance = interval / 10  // lets the system coalesce wake-ups
                    case .until(let next):
                        tolerance = .milliseconds(4)
                        // A few ms past the boundary so the re-render lands on the new word, never just before it.
                        let seconds = next().map { $0 + 0.004 } ?? 2
                        delay = .milliseconds(Int((min(max(seconds, 0.016), 2) * 1000).rounded(.up)))
                    }
                    try? await clock.sleep(for: delay, tolerance: tolerance)
                    guard !Task.isCancelled else { return }
                    tick &+= 1
                }
            }
    }
}

extension EnvironmentValues {
    /// Set by a host that covers its content with something opaque (the main window's browsing UI under the
    /// in-window Stage): clock-driven views inside stop redrawing until it is uncovered.
    @Entry var qtPausesTimeDrivenViews = false
}

/// Reports whether the view's window is on screen and at least partly unobscured (`NSWindow.occlusionState`):
/// false when it's minimised, on another Space, ordered out, the app is hidden, or another window covers it.
struct QTWindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> QTWindowVisibilityNSView {
        let view = QTWindowVisibilityNSView()
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
        return view
    }

    func updateNSView(_ view: QTWindowVisibilityNSView, context: Context) {
        view.onChange = { visible in if isVisible != visible { isVisible = visible } }
    }

    static func dismantleNSView(_ view: QTWindowVisibilityNSView, coordinator: ()) {
        view.onChange = nil
    }
}

final class QTWindowVisibilityNSView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var reported: Bool?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityIsIgnored() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            QTMainActorHop.onMainThread { self?.report() }
        }
        report()
    }

    private func report() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        guard visible != reported else { return }
        reported = visible
        // Out of the view update that moved us into the window.
        DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
    }
}
