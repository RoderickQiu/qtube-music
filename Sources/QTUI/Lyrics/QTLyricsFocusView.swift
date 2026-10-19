import AppKit
import QTCore
import QTPlayback
import QuartzCore

// Owner: builder "lyrics-ui". The current line only (mini player, menu bar) or one/two big lines (desktop
// overlay): cross-fades between lines, karaoke fill in the render server, a one-shot timer per line change.

struct QTLyricsFocusConfiguration: Equatable {
    var document: QTLyricsDocument
    var lanes: QTLyricsLanes
    var clock: QTLyricsClock
    var style: QTLyricsStyle
    var textScale: CGFloat
    var increaseContrast: Bool
    var reduceMotion: Bool
    /// Desktop: 1 = current line only; 2 = current line + its translation, or + the next line when there is none.
    var lineCount: Int
    var desktopFontSize: CGFloat?
    /// Desktop / mini: Settings › Desktop Lyrics font (System, Rounded, Serif).
    var fontDesign: QTLyricsFontDesign = .standard
}

@MainActor
final class QTLyricsFocusView: NSView {
    private var config: QTLyricsFocusConfiguration?
    private var metrics = QTLyricsMetrics.make(.mini)
    private var rows: [QTLyricsRowModel] = []
    private let root = CALayer()
    private var shown: [QTLyricsRowNode] = []
    private var shownKey: [Int] = []
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.actions = QTLyricsRowNode.noActions
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// The desktop overlay is click-through; the mini player handles its own clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ new: QTLyricsFocusConfiguration) {
        let old = config
        if let old, old == new { return }
        config = new
        metrics = QTLyricsMetrics.make(new.style, textScale: new.textScale, increaseContrast: new.increaseContrast,
                                       desktopFontSize: new.desktopFontSize)
            .withDesign(new.fontDesign.systemDesign)
        setAccessibilityIdentifier(new.style.railIdentifier)
        if old == nil || old?.document.lines != new.document.lines || old?.lanes != new.lanes || old?.style != new.style
            || old?.textScale != new.textScale || old?.desktopFontSize != new.desktopFontSize || old?.lineCount != new.lineCount
            || old?.fontDesign != new.fontDesign {
            rebuild()
        }
        refresh(animated: old != nil && window != nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { rebuild(); refresh(animated: false) } else { position(shown, animated: false) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
        refresh(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate() } else { rebuild(); refresh(animated: false) }
    }

    private var isDesktop: Bool { if case .desktop = config?.style { true } else { false } }

    private func rebuild() {
        guard let cfg = config, bounds.width > 1 else { return }
        var lanes = cfg.lanes
        lanes.showsRomanization = isDesktop
        if !isDesktop || cfg.lineCount < 2 { lanes.translations = isDesktop ? nil : lanes.translations }
        rows = QTLyricsRowBuilder.rows(for: cfg.document, lanes: lanes, metrics: metrics, width: bounds.width, includeGaps: false)
        shown.forEach { $0.container.removeFromSuperlayer() }
        shown = []
        shownKey = []
    }

    /// Rows to show at a lyric time: the current line, plus (desktop, 2 lines, no translation) the next one.
    private func keys(at t: Double) -> [Int] {
        guard let cfg = config else { return [] }
        let cur = cfg.document.lineIndex(atPlaybackTime: t - cfg.document.offset)
        let hasLane = rows.contains { $0.translation != nil }
        if isDesktop {
            let first = cur ?? 0
            if cfg.lineCount >= 2 && !hasLane && first + 1 < rows.count { return [first, first + 1] }
            return rows.isEmpty ? [] : [first]
        }
        return cur.map { [$0] } ?? []
    }

    private func refresh(animated: Bool) {
        timer?.invalidate()
        guard let cfg = config, !rows.isEmpty, let window else { return }
        let now = cfg.clock.now()
        let cur = cfg.document.lineIndex(atPlaybackTime: now.lyric - cfg.document.offset)
        let keys = keys(at: now.lyric)
        if keys != shownKey {
            let old = shown
            let scale = window.backingScaleFactor
            shown = keys.map { i in
                let node = QTLyricsRowNode(model: rows[i])
                node.render(metrics: metrics, scale: scale, appearance: effectiveAppearance)
                node.container.opacity = i == cur ? (cfg.clock.stalled ? 0.5 : 1) : metrics.inactiveOpacity
                for lane in node.lanes { lane.opacity = metrics.laneOpacity(rowOpacity: node.container.opacity) }
                root.addSublayer(node.container)
                return node
            }
            shownKey = keys
            position(shown, animated: false)
            transition(out: old, in: shown, animated: animated)
            setAccessibilityLabel(keys.compactMap { rows.indices.contains($0) ? rows[$0].plainText : nil }.joined(separator: "\n"))
        }
        for (k, node) in zip(keys, shown) {
            let isCurrent = k == cur
            if isCurrent { node.startKaraoke(clock: cfg.clock, metrics: metrics) } else { node.stopKaraoke(animated: false, metrics: metrics) }
            let target: Float = isCurrent ? (cfg.clock.stalled ? 0.5 : 1) : metrics.inactiveOpacity
            if node.container.opacity != target {
                CATransaction.begin()
                CATransaction.setAnimationDuration(animated ? QTTheme.Motion.uiDuration : 0)
                node.container.opacity = target
                for lane in node.lanes { lane.opacity = metrics.laneOpacity(rowOpacity: target) }
                CATransaction.commit()
            }
        }
        if cfg.clock.rate > 0, let next = cfg.document.lines.first(where: { $0.start > now.lyric + 0.0005 })?.start {
            let wait = max(0.005, (next - now.lyric) / cfg.clock.rate)
            let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                QTMainActorHop.onMainThread { self?.refresh(animated: true) }
            }
            t.tolerance = 0.004
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// Stacks the shown rows and centres them (desktop) or vertically centres at the leading edge (mini).
    private func position(_ nodes: [QTLyricsRowNode], animated: Bool) {
        let total = nodes.reduce(0) { $0 + $1.model.height } + CGFloat(max(0, nodes.count - 1)) * 4
        var y = ((bounds.height - total) / 2).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for n in nodes {
            n.container.position = CGPoint(x: 0, y: y)
            y += n.model.height + 4
        }
        CATransaction.commit()
    }

    private func transition(out old: [QTLyricsRowNode], in new: [QTLyricsRowNode], animated: Bool) {
        let reduce = config?.reduceMotion == true
        let rise: CGFloat = reduce ? 0 : max(6, metrics.main.size * 0.3)
        for n in old {
            guard animated else { n.container.removeFromSuperlayer(); continue }
            CATransaction.begin()
            CATransaction.setCompletionBlock { n.container.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = n.container.presentation()?.opacity ?? n.container.opacity
            fade.toValue = 0
            let move = CABasicAnimation(keyPath: "position.y")
            move.byValue = -rise
            let g = CAAnimationGroup()
            g.animations = [fade, move]
            g.duration = QTTheme.Motion.uiDuration
            g.timingFunction = QTTheme.Motion.caTimingFunction
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            n.container.add(g, forKey: "qt.lyrics.out")
            CATransaction.commit()
        }
        guard animated else { return }
        for n in new {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            let move = CASpringAnimation(perceptualDuration: QTTheme.Motion.lyricDuration, bounce: 0.05)
            move.keyPath = "position.y"
            move.fromValue = rise
            move.toValue = 0
            move.isAdditive = true
            move.duration = move.settlingDuration
            fade.toValue = n.container.opacity
            fade.duration = QTTheme.Motion.uiDuration
            fade.timingFunction = QTTheme.Motion.caTimingFunction
            n.container.add(fade, forKey: "qt.lyrics.in")
            if !reduce { n.container.add(move, forKey: "qt.lyrics.rise") }
        }
    }
}
