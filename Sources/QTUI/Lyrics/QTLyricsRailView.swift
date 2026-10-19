import AppKit
import Observation
import QTCore
import QTPlayback
import QuartzCore

// Owner: builder "lyrics-ui". The scrolling lyric rail for the docked panel and the Stage: a layer-hosting NSView.
// - Follows the current line with a staggered spring (additive animations, so interruptions blend).
// - Free scrolling (trackpad momentum, mouse wheel, rubber band) detaches auto-follow and shows "Current".
// - Click a line to seek; drag or ⇧-click to select lines, ⌘C copies, ⌘A selects all; NSMenu context menu.
// - No timer runs while a line is sung: one one-shot timer fires at the next line boundary.

/// Bridges the rail's follow state to SwiftUI (the "Current" pill).
@MainActor
@Observable
final class QTLyricsRailController {
    /// The user scrolled away; auto-follow is off.
    var isDetached = false
    /// The current line is below the visible part (pill shows a down chevron).
    var currentIsBelow = false
    @ObservationIgnored weak var rail: QTLyricsRailView?

    func returnToCurrent() { rail?.returnToCurrent(animated: true) }
}

struct QTLyricsRailConfiguration: Equatable {
    var document: QTLyricsDocument
    var lanes: QTLyricsLanes
    var clock: QTLyricsClock
    var style: QTLyricsStyle
    var textScale: CGFloat
    var increaseContrast: Bool
    var reduceMotion: Bool
    /// Launch option `qt.lyrics.scrolled`: start detached (screenshots of the "Current" pill).
    var startsScrolled: Bool = false
}

@MainActor
final class QTLyricsRailView: NSView, NSMenuItemValidation {
    var onSeek: (TimeInterval) -> Void = { _ in }
    weak var controller: QTLyricsRailController?

    private var config: QTLyricsRailConfiguration?
    private var metrics = QTLyricsMetrics.make(.panel)
    private var rows: [QTLyricsRowModel] = []
    private var rowY: [CGFloat] = []
    private var nodes: [Int: QTLyricsRowNode] = [:]
    private var current: Int?
    private var hovered: Int?
    private var selection: ClosedRange<Int>?
    private var selectionAnchor: Int?
    private var mouseDownPoint: NSPoint?
    private var mouseDownRow: Int?
    private var isDragSelecting = false

    private let root = CALayer()
    private let rail = CALayer()
    private let fadeMask = CAGradientLayer()
    /// Rail offset (y of the rail's top in view coordinates) while following.
    private var followOffset: CGFloat = 0
    /// Rail offset while the user browses; nil = following.
    private var manualOffset: CGFloat?
    private var displayedOffset: CGFloat = 0
    private var boundaryTimer: Timer?
    private var resumeTimer: Timer?
    private var layoutWidth: CGFloat = 0
    private var didApplyLaunchScroll = false
    private var axElements: [QTLyricsLineAccessibilityElement] = []

    static let resumeDelay: TimeInterval = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.masksToBounds = true
        root.actions = QTLyricsRowNode.noActions
        rail.anchorPoint = .zero
        rail.actions = QTLyricsRowNode.noActions
        root.addSublayer(rail)
        fadeMask.actions = QTLyricsRowNode.noActions
        layer = root
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        qtLocalizedAccessibility("Lyrics")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { !rows.isEmpty }
    /// System focus ring when reached with Tab (Full Keyboard Access).
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 6, dy: 6) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 10, yRadius: 10).fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Configuration

    func apply(_ new: QTLyricsRailConfiguration) {
        let old = config
        // Parents re-render for unrelated reasons; only play/pause/seek/offset/content changes matter here.
        if let old, old == new, didApplyLaunchScroll || !new.startsScrolled { return }
        config = new
        identifier = NSUserInterfaceItemIdentifier(new.style.railIdentifier)
        setAccessibilityIdentifier(new.style.railIdentifier)
        let needsRows = old == nil || old?.document.lines != new.document.lines || old?.lanes != new.lanes
            || old?.style != new.style || old?.textScale != new.textScale || old?.document.syncKind != new.document.syncKind
        metrics = QTLyricsMetrics.make(new.style, textScale: new.textScale, increaseContrast: new.increaseContrast)
        if needsRows {
            if old?.document.lines != new.document.lines { exitManual(animated: false); selection = nil; current = nil }
            rebuildRows()
        }
        refresh(animated: !needsRows && window != nil)
        if new.startsScrolled, !didApplyLaunchScroll, !rows.isEmpty, bounds.height > 0 {
            didApplyLaunchScroll = true
            let (lo, _) = scrollRange
            manualOffset = max(lo, followOffset - bounds.height * 0.55)
            setDisplayedOffset(manualOffset!, animated: false)
            updateController()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        fadeMask.frame = bounds
        updateFadeMask()
        if widthChanged { rebuildRows() }
        refresh(animated: false)
        if let cfg = config, cfg.startsScrolled, !didApplyLaunchScroll { apply(cfg) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        nodes.values.forEach { $0.renderKey = nil }
        updateVisibleNodes()
        refresh(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        root.contentsScale = window?.backingScaleFactor ?? 2
        nodes.values.forEach { $0.renderKey = nil }
        updateVisibleNodes()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            boundaryTimer?.invalidate()
            resumeTimer?.invalidate()
        } else {
            refresh(animated: false)
        }
    }

    private func updateFadeMask() {
        guard metrics.fadeTop > 0 || metrics.fadeBottom < 1 else { root.mask = nil; return }
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, NSNumber(value: Double(metrics.fadeTop)), NSNumber(value: Double(metrics.fadeBottom)), 1]
        // Gradient unit space is y-up on macOS: start at the top edge.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        root.mask = fadeMask
    }

    // MARK: Rows

    private var contentWidth: CGFloat { max(80, bounds.width - metrics.inset * 2) }

    private func rebuildRows() {
        guard let cfg = config, bounds.width > 1 else { return }
        layoutWidth = contentWidth
        rows = QTLyricsRowBuilder.rows(for: cfg.document, lanes: cfg.lanes, metrics: metrics, width: layoutWidth,
                                       includeGaps: cfg.document.syncKind != .plain)
        nodes.values.forEach { $0.container.removeFromSuperlayer() }
        nodes = [:]
        hovered = nil
        updateFadeMask()
        rebuildAccessibility()
    }

    /// Row tops for a given current row (inactive gap rows collapse).
    private func layoutYs(current: Int?) -> [CGFloat] {
        var ys: [CGFloat] = []
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            ys.append(y)
            y += height(of: r, isCurrent: i == current)
        }
        return ys
    }

    private func height(of r: QTLyricsRowModel, isCurrent: Bool) -> CGFloat {
        r.isIntro || (r.isGap && !isCurrent) ? 0 : r.height
    }

    /// Top of a row's layers: the intro dots sit just above the first line instead of in the flow.
    private func nodeY(_ i: Int) -> CGFloat {
        rows[i].isIntro ? rowY[i] - rows[i].height : rowY[i]
    }

    /// The row the rail centres on: the intro gap hands over to the first line.
    private func focusRow(_ i: Int) -> Int {
        var i = i
        while rows.indices.contains(i + 1), rows[i].isIntro { i += 1 }
        return i
    }

    private var totalHeight: CGFloat {
        guard let last = rows.indices.last else { return 0 }
        return rowY[last] + height(of: rows[last], isCurrent: last == current)
    }

    /// Which row is current at a lyric time: an active instrumental gap wins over the line before it.
    private func currentRow(at t: Double) -> Int? {
        guard let cfg = config, cfg.document.syncKind != .plain else { return nil }
        var best: Int?
        for (i, r) in rows.enumerated() {
            switch r.kind {
            case .line:
                if r.start <= t { best = i }
            case .gap(let s, let e):
                if t >= s && t < e { return i }
            }
            if r.start > t { break }
        }
        if let b = best, rows[b].isGap { return nil }
        return best
    }

    /// Next lyric time at which the current row changes.
    private func nextBoundary(after t: Double) -> Double? {
        var next: Double?
        for r in rows {
            switch r.kind {
            case .line: if r.start > t + 0.0005 { next = min(next ?? .infinity, r.start) }
            case .gap(let s, let e):
                if s > t + 0.0005 { next = min(next ?? .infinity, s) }
                if e > t + 0.0005 { next = min(next ?? .infinity, e) }
            }
        }
        return next
    }

    // MARK: Refresh (state, positions, karaoke, timer)

    private func refresh(animated: Bool) {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard let cfg = config, !rows.isEmpty, bounds.height > 0 else { return }
        let now = cfg.clock.now()
        let newCurrent = currentRow(at: now.lyric)
        let oldCurrent = current
        QTLyricsDebug.log("refresh t=\(now.lyric) rate=\(cfg.clock.rate) cur=\(String(describing: newCurrent)) old=\(String(describing: oldCurrent)) rows=\(rows.count) nodes=\(nodes.count) h=\(bounds.height) win=\(window != nil) animated=\(animated)")
        let oldYs = rowY.count == rows.count ? rowY : layoutYs(current: newCurrent)
        let oldOffset = displayedOffset
        current = newCurrent
        rowY = layoutYs(current: newCurrent)
        followOffset = computeFollowOffset()
        let target = manualOffset ?? followOffset
        let move = animated && (oldCurrent != newCurrent || oldOffset != target)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.frame = CGRect(x: metrics.inset, y: target, width: layoutWidth, height: max(1, totalHeight))
        displayedOffset = target
        updateVisibleNodes()
        for (i, node) in nodes {
            node.container.position = CGPoint(x: 0, y: nodeY(i))
            if move {
                let delta = (oldOffset + oldYs[i]) - (target + rowY[i])
                if abs(delta) > 0.5 { addSpring(to: node.container, from: delta, delay: stagger(row: i, current: newCurrent ?? 0, movingUp: delta > 0)) }
            }
        }
        CATransaction.commit()

        for (i, node) in nodes { applyState(node, row: i, animated: animated) }
        // Karaoke / dots on the current row; stop the previous one.
        if let o = oldCurrent, o != newCurrent, let node = nodes[o] {
            if rows[o].isGap { node.stopDots() } else { node.stopKaraoke(animated: animated, metrics: metrics) }
        }
        if let c = newCurrent, let node = nodes[c] {
            if rows[c].isGap { node.startDots(clock: cfg.clock) } else { node.startKaraoke(clock: cfg.clock, metrics: metrics) }
        }
        updateController()
        updateSelectionLayers()
        if cfg.clock.rate > 0, let next = nextBoundary(after: now.lyric) {
            let wait = max(0.005, (next - now.lyric) / cfg.clock.rate)
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                QTMainActorHop.onMainThread { self?.refresh(animated: true) }
            }
            timer.tolerance = 0.004
            RunLoop.main.add(timer, forMode: .common)
            boundaryTimer = timer
        }
    }

    private func computeFollowOffset() -> CGFloat {
        guard !rows.isEmpty else { return 0 }
        let h = bounds.height
        if config?.document.syncKind == .plain { return h * max(0.16, metrics.fadeTop + 0.02) }
        let i = focusRow(current ?? 0)
        return h * metrics.anchor - (rowY[i] + height(of: rows[i], isCurrent: i == current) / 2)
    }

    /// Allowed rail offsets: first row centred at the anchor … last row centred at the anchor.
    private var scrollRange: (CGFloat, CGFloat) {
        guard !rows.isEmpty else { return (0, 0) }
        let a = bounds.height * metrics.anchor
        let first = focusRow(0)
        let firstCentre = rowY[first] + height(of: rows[first], isCurrent: current == first) / 2
        let lastIndex = rows.count - 1
        let lastCentre = rowY[lastIndex] + height(of: rows[lastIndex], isCurrent: current == lastIndex) / 2
        let hi = config?.document.syncKind == .plain ? bounds.height * 0.16 : a - firstCentre
        return (min(hi, a - lastCentre), hi)
    }

    private func stagger(row i: Int, current c: Int, movingUp: Bool) -> CFTimeInterval {
        guard config?.reduceMotion != true else { return 0 }
        // Lines ahead of the motion follow a beat later: a gentle ripple from the current line outward.
        let distance = movingUp ? i - c + 1 : c - i + 1
        return min(0.16, Double(max(0, distance)) * 0.032)
    }

    private func addSpring(to layer: CALayer, from delta: CGFloat, delay: CFTimeInterval) {
        let anim: CABasicAnimation
        if config?.reduceMotion == true {
            anim = CABasicAnimation(keyPath: "position.y")
            anim.duration = 0.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        } else {
            let spring = CASpringAnimation(perceptualDuration: QTTheme.Motion.lyricDuration, bounce: 0.04)
            spring.keyPath = "position.y"
            spring.duration = spring.settlingDuration
            anim = spring
        }
        anim.fromValue = delta
        anim.toValue = 0
        anim.isAdditive = true
        anim.fillMode = .backwards
        anim.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        layer.add(anim, forKey: nil)
    }

    private func setDisplayedOffset(_ y: CGFloat, animated: Bool) {
        let delta = displayedOffset - y
        displayedOffset = y
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rail.frame.origin.y = y
        CATransaction.commit()
        if animated, abs(delta) > 0.5 { addSpring(to: rail, from: delta, delay: 0) }
        updateVisibleNodes()
    }

    /// Creates layers for rows near the viewport and drops far ones (keeps memory flat on long songs).
    private func updateVisibleNodes() {
        guard let window, !rows.isEmpty, rowY.count == rows.count else { return }
        let margin = bounds.height
        let top = -displayedOffset - margin, bottom = -displayedOffset + bounds.height + margin
        let scale = window.backingScaleFactor
        var keep = Set<Int>()
        for i in rows.indices {
            let y = nodeY(i), h = max(rows[i].height, 1)
            guard y + h >= top, y <= bottom else { continue }
            keep.insert(i)
            let node: QTLyricsRowNode
            if let n = nodes[i] {
                node = n
            } else {
                node = QTLyricsRowNode(model: rows[i])
                nodes[i] = node
                rail.addSublayer(node.container)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                node.container.position = CGPoint(x: 0, y: nodeY(i))
                CATransaction.commit()
                applyState(node, row: i, animated: false)
            }
            let rebuilt = node.render(metrics: metrics, scale: scale, appearance: effectiveAppearance)
            if rebuilt, i == current, let cfg = config {
                if rows[i].isGap { node.startDots(clock: cfg.clock) } else { node.startKaraoke(clock: cfg.clock, metrics: metrics) }
            }
        }
        for (i, node) in nodes where !keep.contains(i) && i != current {
            node.container.removeFromSuperlayer()
            nodes[i] = nil
        }
    }

    /// Opacity, scale and blur for a row relative to the current one.
    private func applyState(_ node: QTLyricsRowNode, row i: Int, animated: Bool) {
        guard let cfg = config else { return }
        let r = rows[i]
        let isCurrent = i == current
        let plain = cfg.document.syncKind == .plain
        var opacity: Float
        var scale: CGFloat = 1
        var blur: CGFloat = 0
        if plain {
            opacity = 1
        } else if r.isGap {
            opacity = isCurrent ? 1 : 0
        } else if isCurrent {
            opacity = 1
        } else {
            opacity = metrics.inactiveOpacity
            scale = metrics.inactiveScale
            let c = current ?? -1
            let far = abs(i - c) > 3 && manualOffset == nil
            if let farOpacity = metrics.farOpacity, far { opacity = farOpacity }
            if i > c { blur = far ? metrics.farBlur : metrics.futureBlur }
            if i < c, far { blur = metrics.farBlur }
            if hovered == i { opacity = max(opacity, metrics.hoverOpacity); blur = 0 }
        }
        if let sel = selection, sel.contains(i) { opacity = max(opacity, 0.9); blur = 0 }
        if cfg.clock.stalled { opacity *= 0.5; blur = 0 }
        if config?.reduceMotion == true { scale = 1 }

        let anchorX: CGFloat = metrics.main.centered ? 0.5 : 0
        let transform = scaleTransform(scale, width: r.width, height: height(of: r, isCurrent: isCurrent), anchorX: anchorX)
        let laneOpacity = metrics.laneOpacity(rowOpacity: opacity)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            if node.container.opacity != opacity { animate(node.container, "opacity", to: opacity) }
            for lane in node.lanes where lane.opacity != laneOpacity { animate(lane, "opacity", to: laneOpacity) }
            if !CATransform3DEqualToTransform(node.container.transform, transform) {
                animate(node.container, "transform", to: NSValue(caTransform3D: transform))
            }
        }
        node.container.opacity = opacity
        for lane in node.lanes { lane.opacity = laneOpacity }
        node.container.transform = transform
        let wantsBlur = blur > 0.05
        if wantsBlur {
            if node.container.filters?.isEmpty ?? true, let f = CIFilter(name: "CIGaussianBlur") {
                f.name = "blur"
                f.setValue(0, forKey: kCIInputRadiusKey)
                node.container.filters = [f]
            }
            node.container.setValue(blur, forKeyPath: "filters.blur.inputRadius")
        } else if node.container.filters?.isEmpty == false {
            node.container.filters = nil
        }
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, _ key: String, to value: Any) {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        a.toValue = value
        a.duration = config?.reduceMotion == true ? 0.15 : QTTheme.Motion.lyricDuration
        a.timingFunction = QTTheme.Motion.caTimingFunction
        layer.add(a, forKey: "qt.lyrics.\(key)")
    }

    /// Scale about the row's leading (or centre) edge without moving its top.
    private func scaleTransform(_ s: CGFloat, width: CGFloat, height: CGFloat, anchorX: CGFloat) -> CATransform3D {
        guard s != 1 else { return CATransform3DIdentity }
        // Layers are anchored at (0, 0): translate so the scale pivots around (anchorX·width, height/2).
        let px = width * anchorX, py = height / 2
        var t = CATransform3DMakeTranslation(px, py, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -px, -py, 0)
        return t
    }

    // MARK: Follow / manual scrolling

    func returnToCurrent(animated: Bool) {
        resumeTimer?.invalidate()
        guard manualOffset != nil else { return }
        manualOffset = nil
        setDisplayedOffset(followOffset, animated: animated)
        nodes.forEach { applyState($0.value, row: $0.key, animated: animated) }
        updateController()
    }

    private func exitManual(animated: Bool) {
        manualOffset = nil
        resumeTimer?.invalidate()
        updateController()
    }

    private func updateController() {
        guard let controller else { return }
        let detached = manualOffset != nil
        if controller.isDetached != detached { controller.isDetached = detached }
        let below = (manualOffset ?? followOffset) > followOffset
        if controller.currentIsBelow != below { controller.currentIsBelow = below }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !rows.isEmpty, config != nil else { return super.scrollWheel(with: event) }
        let precise = event.hasPreciseScrollingDeltas
        var dy = event.scrollingDeltaY
        if !precise { dy *= (metrics.main.size * metrics.main.lineHeight + metrics.rowPadding * 2) / 3 }
        if dy == 0 && event.phase != .ended && event.momentumPhase != .ended { return }
        if manualOffset == nil {
            manualOffset = displayedOffset
            nodes.forEach { applyState($0.value, row: $0.key, animated: true) }
        }
        let (lo, hi) = scrollRange
        var next = manualOffset! + dy
        if precise {
            // Rubber band past either end; settles back when the gesture or its momentum ends.
            if next > hi { next = manualOffset! + dy * max(0.08, 0.5 - (manualOffset! - hi) / max(1, bounds.height)) }
            if next < lo { next = manualOffset! + dy * max(0.08, 0.5 - (lo - manualOffset!) / max(1, bounds.height)) }
        } else {
            next = min(hi, max(lo, next))
        }
        manualOffset = next
        setDisplayedOffset(next, animated: false)
        let ended = event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase == []) || !precise
        if ended || event.momentumPhase == .changed && (next > hi + 40 || next < lo - 40) {
            let clamped = min(hi, max(lo, next))
            if clamped != next {
                manualOffset = clamped
                setDisplayedOffset(clamped, animated: true)
            }
        }
        updateController()
        scheduleResume()
    }

    private func scheduleResume() {
        resumeTimer?.invalidate()
        guard config?.startsScrolled != true else { return }
        let timer = Timer(timeInterval: Self.resumeDelay, repeats: false) { [weak self] _ in
            QTMainActorHop.onMainThread {
                guard let self, self.selection == nil else { return }
                self.returnToCurrent(animated: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    // MARK: Mouse: hover, click to seek, drag to select

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    private func row(at point: NSPoint) -> Int? {
        let y = point.y - displayedOffset
        for i in rows.indices where !(rows[i].isGap && i != current) {
            let top = rowY[i], h = height(of: rows[i], isCurrent: i == current)
            if y >= top && y < top + h { return i }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil)).flatMap { rows[$0].isGap ? nil : $0 }
        guard r != hovered else { return }
        let old = hovered
        hovered = r
        for i in [old, r].compactMap({ $0 }) { if let n = nodes[i] { applyState(n, row: i, animated: true) } }
    }

    override func mouseExited(with event: NSEvent) {
        guard let old = hovered else { return }
        hovered = nil
        if let n = nodes[old] { applyState(n, row: old, animated: true) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        mouseDownRow = row(at: p)
        isDragSelecting = false
        if event.modifierFlags.contains(.shift), let r = mouseDownRow, rows[r].lineIndex != nil {
            let anchor = selectionAnchor ?? current ?? r
            setSelection(min(anchor, r)...max(anchor, r))
            isDragSelecting = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isDragSelecting, hypot(p.x - start.x, p.y - start.y) < 4 { return }
        guard let a = mouseDownRow ?? row(at: start) else { return }
        isDragSelecting = true
        let b = row(at: p) ?? (p.y < 0 ? 0 : rows.count - 1)
        selectionAnchor = a
        setSelection(min(a, b)...max(a, b))
        if manualOffset == nil { manualOffset = displayedOffset; updateController() }
        resumeTimer?.invalidate()
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; mouseDownRow = nil }
        guard !isDragSelecting else { return }
        if selection != nil { setSelection(nil) }
        guard event.clickCount <= 2, let r = mouseDownRow, let line = rows[r].lineIndex, let doc = config?.document,
              doc.syncKind != .plain else { return }
        onSeek(doc.playbackTime(forLine: line))
        returnToCurrent(animated: true)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let r = row(at: p), let line = rows[r].lineIndex else { return nil }
        if selection.map({ !$0.contains(r) }) ?? true { setSelection(r...r) }
        let menu = NSMenu()
        if config?.document.syncKind != .plain {
            let play = NSMenuItem(title: QTLoc.tr("Play from Here", table: .lyrics), action: #selector(playFromMenu(_:)), keyEquivalent: "")
            play.target = self
            play.tag = line
            menu.addItem(play)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: QTLoc.tr("Copy", table: .lyrics), action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        let all = NSMenuItem(title: QTLoc.tr("Copy All Lyrics", table: .lyrics), action: #selector(copyAll(_:)), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        menu.addItem(.separator())
        let select = NSMenuItem(title: QTLoc.tr("Select All", table: .lyrics), action: #selector(selectAll(_:)), keyEquivalent: "a")
        select.target = self
        menu.addItem(select)
        return menu
    }

    @objc private func playFromMenu(_ sender: NSMenuItem) {
        guard let doc = config?.document, doc.lines.indices.contains(sender.tag) else { return }
        setSelection(nil)
        onSeek(doc.playbackTime(forLine: sender.tag))
        returnToCurrent(animated: true)
    }

    // MARK: Selection + copy

    private func setSelection(_ range: ClosedRange<Int>?) {
        let old = selection
        selection = range
        updateSelectionLayers()
        let touched = Set((old.map(Array.init) ?? []) + (range.map(Array.init) ?? []))
        for i in touched { if let n = nodes[i] { applyState(n, row: i, animated: false) } }
    }

    private func updateSelectionLayers() {
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        var color = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (focused ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, node) in nodes {
            let on = selection?.contains(i) == true && !rows[i].isGap
            node.selection.isHidden = !on
            if on {
                node.selection.backgroundColor = metrics.overArt ? NSColor.white.withAlphaComponent(0.16).cgColor : color
                node.selection.frame = CGRect(x: -10, y: 0, width: rows[i].width + 20, height: rows[i].height)
            }
        }
        CATransaction.commit()
    }

    override func becomeFirstResponder() -> Bool { defer { updateSelectionLayers() }; return true }
    override func resignFirstResponder() -> Bool { defer { DispatchQueue.main.async { self.updateSelectionLayers() } }; return true }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): return selection != nil || current != nil
        case #selector(selectAll(_:)), #selector(copyAll(_:)): return !rows.isEmpty
        default: return true
        }
    }

    private func text(of range: ClosedRange<Int>) -> String {
        range.compactMap { rows.indices.contains($0) && !rows[$0].isGap ? rows[$0].plainText : nil }.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let range = selection ?? current.map({ $0...$0 }) else { return NSSound.beep() }
        let s = text(of: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc func copyAll(_ sender: Any?) {
        guard !rows.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(of: 0...(rows.count - 1)), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard !rows.isEmpty else { return }
        setSelection(0...(rows.count - 1))
    }

    override func cancelOperation(_ sender: Any?) {
        if selection != nil { setSelection(nil) } else if manualOffset != nil { returnToCurrent(animated: true) } else { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return } // Esc
        super.keyDown(with: event)
    }

    // MARK: Accessibility

    private func rebuildAccessibility() {
        axElements = rows.indices.compactMap { i in
            guard let line = rows[i].lineIndex else { return nil }
            let el = QTLyricsLineAccessibilityElement()
            el.setAccessibilityParent(self)
            el.setAccessibilityRole(.staticText)
            el.setAccessibilityLabel(rows[i].plainText)
            el.setAccessibilityIdentifier("qt.lyrics.line.\(line)")
            el.rowIndex = i
            el.owner = self
            return el
        }
        setAccessibilityChildren(axElements)
    }

    fileprivate func accessibilityFrame(forRow i: Int) -> NSRect {
        guard rowY.indices.contains(i), let window else { return .zero }
        let local = NSRect(x: metrics.inset, y: displayedOffset + rowY[i], width: rows[i].width, height: height(of: rows[i], isCurrent: i == current))
        return window.convertToScreen(convert(local, to: nil))
    }

    fileprivate func accessibilityIsCurrent(_ i: Int) -> Bool { i == current }

    fileprivate func accessibilityPress(row i: Int) -> Bool {
        guard let line = rows[i].lineIndex, let doc = config?.document, doc.syncKind != .plain else { return false }
        onSeek(doc.playbackTime(forLine: line))
        returnToCurrent(animated: true)
        return true
    }
}

/// One lyric line for VoiceOver: label = lyric (+ lanes), press = seek there, selected = being sung.
final class QTLyricsLineAccessibilityElement: NSAccessibilityElement {
    var rowIndex = 0
    weak var owner: QTLyricsRailView?

    override func accessibilityFrame() -> NSRect {
        let owner = owner, row = rowIndex
        return QTMainActorHop.onMainThread { owner?.accessibilityFrame(forRow: row) ?? .zero }
    }

    override func isAccessibilitySelected() -> Bool {
        let owner = owner, row = rowIndex
        return QTMainActorHop.onMainThread { owner?.accessibilityIsCurrent(row) ?? false }
    }

    override func accessibilityPerformPress() -> Bool {
        let owner = owner, row = rowIndex
        return QTMainActorHop.onMainThread { owner?.accessibilityPress(row: row) ?? false }
    }
}

extension QTLyricsStyle {
    /// Area-specific identifiers (`qt.lyrics.rail.panel`), never a generic "stage"/"mini".
    var railIdentifier: String {
        switch self {
        case .panel: "qt.lyrics.rail.panel"
        case .stage(let c): c ? "qt.lyrics.rail.stageCentered" : "qt.lyrics.rail.stage"
        case .mini: "qt.lyrics.focus.miniPlayer"
        case .desktop: "qt.lyrics.focus.desktopOverlay"
        }
    }
}

/// `-qt.lyrics.debug YES`: appends renderer events to /tmp/qt-lyrics-ui-debug.log. DEBUG builds only: release builds
/// compile `log` to nothing (no fixed /tmp path in the shipping binary).
enum QTLyricsDebug {
    #if !DEBUG
    @inline(__always) static func log(_ message: @autoclosure () -> String) {}
    #else
    static let isEnabled = UserDefaults.standard.bool(forKey: "qt.lyrics.debug")
    static let path = "/tmp/qt-lyrics-ui-debug.log"

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(Data((message() + "\n").utf8))
        try? h.close()
    }
    #endif
}
