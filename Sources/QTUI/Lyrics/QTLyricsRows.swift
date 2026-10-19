import AppKit
import QTCore
import QTPlayback
import QuartzCore

// Owner: builder "lyrics-ui". Row models (layout of one lyric line + its lanes, or an instrumental gap), the
// Core Animation layers that draw them, and the karaoke fill. The fill runs entirely in the render server
// (keyframe animations scheduled at the word timings), so the app does no per-frame work while a line is sung.

// MARK: - Metrics per surface (styles.css: .ly-panel / .ly-stage / .desk-lyrics / .pop-lyric)

struct QTLyricsMetrics {
    var main: QTLyricTextStyle
    var romanization: QTLyricTextStyle
    var translation: QTLyricTextStyle
    /// Vertical padding of a row (`.ly-line` padding).
    var rowPadding: CGFloat
    /// Gap between the lyric and its lanes (`.ly-tr` margin-top).
    var laneGap: CGFloat
    /// Horizontal inset of the rail (`.lyrics-rail` left/right).
    var inset: CGFloat
    /// Where the current line's centre sits, as a fraction of the height (prototype `anchor = 0.36`).
    var anchor: CGFloat
    var inactiveOpacity: Float
    var hoverOpacity: Float
    /// Stage only: lines more than 3 away fade further and blur (`.ly-line.far`).
    var farOpacity: Float?
    /// Unsung part of a karaoke line (`--ly-off`).
    var unsungOpacity: Float
    var inactiveScale: CGFloat
    var futureBlur: CGFloat
    var farBlur: CGFloat
    /// Soft edge of the karaoke fill, in points.
    var edge: CGFloat
    /// Fade-out mask (`.lyrics` mask-image: transparent → black 14 % … 80 % → transparent).
    var fadeTop: CGFloat
    var fadeBottom: CGFloat
    var overArt: Bool
    /// Desktop overlay: baked shadow + outline so it reads on any wallpaper.
    var shadow: NSShadow?
    var outline: (width: CGFloat, color: NSColor)?
    var dotSize: CGFloat

    var mainColor: NSColor { overArt ? .white : .labelColor }
    var laneColor: NSColor { overArt ? NSColor.white.withAlphaComponent(0.62) : .secondaryLabelColor }

    /// Same metrics with every lane in the given system font design.
    func withDesign(_ design: NSFontDescriptor.SystemDesign) -> QTLyricsMetrics {
        var m = self
        m.main.design = design
        m.romanization.design = design
        m.translation.design = design
        return m
    }

    static func make(_ style: QTLyricsStyle, textScale: CGFloat = 1, increaseContrast: Bool = false,
                     desktopFontSize: CGFloat? = nil) -> QTLyricsMetrics {
        let dim: Float = increaseContrast ? 0.5 : 0.32
        switch style {
        case .panel:
            let s = QTTheme.Typography.lyricSizes(.panel)
            return QTLyricsMetrics(
                main: .init(size: s.main * textScale, weight: .bold, lineHeight: 1.3, centered: false, tracking: -0.005),
                romanization: .init(size: (s.translation - 1) * textScale, weight: .medium, lineHeight: 1.3, centered: false),
                translation: .init(size: s.translation * textScale, weight: .medium, lineHeight: 1.3, centered: false),
                rowPadding: 7, laneGap: 3, inset: 30, anchor: 0.36, inactiveOpacity: dim, hoverOpacity: 0.62,
                farOpacity: nil, unsungOpacity: increaseContrast ? 0.5 : 0.36, inactiveScale: 0.97,
                futureBlur: 0, farBlur: 0, edge: 10 * textScale, fadeTop: 0.14, fadeBottom: 0.80, overArt: false,
                shadow: nil, outline: nil, dotSize: 7 * textScale)
        case .stage(let centered):
            let s = QTTheme.Typography.lyricSizes(.stage)
            return QTLyricsMetrics(
                main: .init(size: s.main * textScale, weight: .bold, lineHeight: 1.22, centered: centered, tracking: -0.005),
                romanization: .init(size: (s.translation - 3) * textScale, weight: .semibold, lineHeight: 1.25, centered: centered),
                translation: .init(size: s.translation * textScale, weight: .semibold, lineHeight: 1.3, centered: centered),
                rowPadding: 12, laneGap: 4, inset: 0, anchor: 0.36, inactiveOpacity: dim, hoverOpacity: 0.62,
                farOpacity: increaseContrast ? 0.36 : 0.2, unsungOpacity: increaseContrast ? 0.5 : 0.34,
                inactiveScale: 0.955, futureBlur: increaseContrast ? 0 : 0.6, farBlur: increaseContrast ? 0 : 1.6,
                edge: 18 * textScale, fadeTop: 0.14, fadeBottom: 0.80, overArt: true, shadow: nil, outline: nil,
                dotSize: 12 * textScale)
        case .mini:
            let s = QTTheme.Typography.lyricSizes(.mini)
            return QTLyricsMetrics(
                main: .init(size: s.main * textScale, weight: .semibold, lineHeight: 1.3, centered: false, balanced: false),
                romanization: .init(size: s.translation * textScale, weight: .regular, lineHeight: 1.3, centered: false, balanced: false),
                translation: .init(size: s.translation * textScale, weight: .regular, lineHeight: 1.3, centered: false, balanced: false),
                rowPadding: 0, laneGap: 1, inset: 0, anchor: 0.5, inactiveOpacity: dim, hoverOpacity: 1,
                farOpacity: nil, unsungOpacity: 0.45, inactiveScale: 1, futureBlur: 0, farBlur: 0, edge: 6,
                fadeTop: 0, fadeBottom: 1, overArt: false, shadow: nil, outline: nil, dotSize: 5)
        case .desktop:
            let s = QTTheme.Typography.lyricSizes(.desktop)
            let main = (desktopFontSize ?? s.main) * textScale
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return QTLyricsMetrics(
                main: .init(size: main, weight: .bold, lineHeight: 1.2, centered: true),
                romanization: .init(size: main * 0.5, weight: .semibold, lineHeight: 1.3, centered: true),
                translation: .init(size: main * s.translation / s.main, weight: .semibold, lineHeight: 1.3, centered: true),
                rowPadding: 0, laneGap: 6, inset: 0, anchor: 0.5, inactiveOpacity: 0.55, hoverOpacity: 1,
                farOpacity: nil, unsungOpacity: 0.45, inactiveScale: 1, futureBlur: 0, farBlur: 0, edge: 16,
                fadeTop: 0, fadeBottom: 1, overArt: true, shadow: shadow,
                outline: (width: max(1.5, main / 18), color: NSColor.black.withAlphaComponent(0.28)), dotSize: 10)
        }
    }
}

// MARK: - Lyric time ↔ media time

/// Maps the lyric timeline onto Core Animation's media clock so animations start exactly at word timings.
struct QTLyricsClock: Equatable {
    var timeline: QTPlaybackTimeline
    /// Document offset (positive = lyrics earlier).
    var offset: TimeInterval
    /// Ads / buffering: lyrics stand still.
    var stalled: Bool

    var rate: Double { stalled ? 0 : timeline.rate }

    /// Lyric time now and the matching media time.
    func now() -> (lyric: Double, media: CFTimeInterval) {
        let media = CACurrentMediaTime()
        let uptime = ProcessInfo.processInfo.systemUptime
        return (timeline.time(atUptime: uptime) + offset, media)
    }

    func mediaTime(forLyric t: Double, at now: (lyric: Double, media: CFTimeInterval)) -> CFTimeInterval {
        guard rate > 0 else { return now.media }
        return now.media + (t - now.lyric) / rate
    }
}

// MARK: - Row model

/// One row of the rail: a lyric line (with lanes) or an instrumental gap shown as three filling dots.
struct QTLyricsRowModel {
    enum Kind: Equatable {
        case line(Int)
        case gap(start: Double, end: Double)
    }

    var kind: Kind
    var main: QTLyricTextLayout?
    var romanization: QTLyricTextLayout?
    var translation: QTLyricTextLayout?
    /// Block origins inside the row (top-left of each layout box).
    var mainOrigin: CGPoint = .zero
    var romanizationOrigin: CGPoint = .zero
    var translationOrigin: CGPoint = .zero
    /// Expanded height (gap rows collapse to 0 while inactive).
    var height: CGFloat = 0
    var width: CGFloat = 0
    var karaoke: [QTKaraokeTrack] = []
    /// Lyric-time range the row is "current" for (gap rows) or its start (lines).
    var start: Double
    var end: Double?

    var lineIndex: Int? { if case .line(let i) = kind { i } else { nil } }
    var isGap: Bool { if case .gap = kind { true } else { false } }
    var plainText: String {
        [main?.string, romanization?.string, translation?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Lanes resolved for display (translation may come from the provider or on-device translation).
struct QTLyricsLanes: Equatable {
    var translations: [String?]?
    var translationLanguage: String?
    var showsRomanization: Bool = true
}

enum QTLyricsRowBuilder {
    /// Minimum instrumental gap (s) that gets its own dots row; intros need less.
    static let interludeThreshold: Double = 7
    static let introThreshold: Double = 3.5

    /// The time a line stops being sung, when known (word timing or line duration).
    static func end(of line: QTLyricsLine) -> Double? {
        if let w = line.words?.last { return w.end }
        if let d = line.duration, d > 0 { return line.start + d }
        return nil
    }

    static func isInstrumental(_ doc: QTLyricsDocument) -> Bool {
        let markers = ["纯音乐，请欣赏", "纯音乐，请您欣赏", "此歌曲为没有填词的纯音乐，请您欣赏", "instrumental"]
        guard !doc.lines.isEmpty else { return false }
        let texts = doc.lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if texts.isEmpty { return true }
        return texts.count <= 2 && texts.contains { t in markers.contains { t.lowercased().contains($0.lowercased()) } }
    }

    /// Builds rows (layouts + karaoke tracks) for a document at a content width.
    static func rows(for doc: QTLyricsDocument, lanes: QTLyricsLanes, metrics m: QTLyricsMetrics, width: CGFloat,
                     includeGaps: Bool) -> [QTLyricsRowModel] {
        var rows: [QTLyricsRowModel] = []
        let synced = doc.syncKind != .plain
        let shadowRoom: CGFloat = m.shadow != nil ? 12 : 0
        for (i, line) in doc.lines.enumerated() {
            if includeGaps, synced {
                let gapStart: Double? = i == 0 ? 0 : end(of: doc.lines[i - 1])
                if let gs = gapStart {
                    let threshold = i == 0 ? introThreshold : interludeThreshold
                    if line.start - gs >= threshold {
                        let s = i == 0 ? 0 : gs + 0.4
                        rows.append(gapRow(start: s, end: line.start - 0.25, metrics: m, width: width))
                    }
                }
            }
            rows.append(lineRow(i, line, doc: doc, lanes: lanes, metrics: m, width: width, shadowRoom: shadowRoom))
        }
        return rows
    }

    static func gapRow(start: Double, end: Double, metrics m: QTLyricsMetrics, width: CGFloat) -> QTLyricsRowModel {
        var r = QTLyricsRowModel(kind: .gap(start: start, end: end), start: start, end: end)
        r.width = width
        r.height = (m.main.size * m.main.lineHeight).rounded(.up) + m.rowPadding * 2
        return r
    }

    static func lineRow(_ i: Int, _ line: QTLyricsLine, doc: QTLyricsDocument, lanes: QTLyricsLanes, metrics m: QTLyricsMetrics,
                        width: CGFloat, shadowRoom: CGFloat) -> QTLyricsRowModel {
        var r = QTLyricsRowModel(kind: .line(i), start: line.start, end: end(of: line))
        r.width = width
        let text = line.text.isEmpty ? " " : line.text
        let main = QTLyricTextLayout(string: text, style: m.main, maxWidth: width, documentLanguage: doc.language, shadowRoom: shadowRoom)
        r.main = main
        func x(_ l: QTLyricTextLayout) -> CGFloat { m.main.centered ? ((width - l.size.width) / 2).rounded() : 0 }
        var y = m.rowPadding
        r.mainOrigin = CGPoint(x: x(main), y: y)
        y += main.size.height
        if lanes.showsRomanization, let roma = line.romanization, !roma.isEmpty {
            let l = QTLyricTextLayout(string: roma, style: m.romanization, maxWidth: width, documentLanguage: "en", shadowRoom: shadowRoom)
            y += m.laneGap
            r.romanization = l
            r.romanizationOrigin = CGPoint(x: x(l), y: y)
            y += l.size.height
        }
        if let lane = lanes.translations, i < lane.count, let tr = lane[i], !tr.isEmpty {
            let l = QTLyricTextLayout(string: tr, style: m.translation, maxWidth: width,
                                      documentLanguage: lanes.translationLanguage, shadowRoom: shadowRoom)
            y += m.laneGap
            r.translation = l
            r.translationOrigin = CGPoint(x: x(l), y: y)
            y += l.size.height
        }
        r.height = y + m.rowPadding
        if let words = line.words, !words.isEmpty, doc.syncKind == .word {
            r.karaoke = karaokeTracks(words: words, layout: main, edge: m.edge)
        }
        return r
    }

    /// Maps word timings onto the laid-out glyphs. Words concatenate to the line text (trailing spaces included);
    /// if a provider's words don't, each word is searched for in order.
    static func karaokeTracks(words: [QTLyricsWord], layout: QTLyricTextLayout, edge: CGFloat) -> [QTKaraokeTrack] {
        let ns = layout.string as NSString
        var cursor = 0
        var spans: [(start: Double, end: Double, spans: [(fragment: Int, x0: CGFloat, x1: CGFloat)])] = []
        for w in words {
            let wordNS = w.text as NSString
            var range = NSRange(location: cursor, length: wordNS.length)
            if NSMaxRange(range) > ns.length || ns.substring(with: range) != w.text {
                let trimmed = w.text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let found = ns.range(of: trimmed, range: NSRange(location: cursor, length: ns.length - cursor))
                guard found.location != NSNotFound else { continue }
                range = found
            }
            cursor = NSMaxRange(range)
            // Fill ink only: trailing whitespace belongs to the gap before the next word.
            var ink = range
            while ink.length > 0, let scalar = UnicodeScalar(ns.character(at: NSMaxRange(ink) - 1)),
                  CharacterSet.whitespaces.contains(scalar) {
                ink.length -= 1
            }
            guard ink.length > 0 else { continue }
            spans.append((w.start, w.end, layout.xSpans(for: ink)))
        }
        return QTKaraoke.tracks(words: spans, fragments: layout.fragments.map { ($0.x, $0.width) }, edge: edge)
    }
}

// MARK: - Layers for one row

/// The Core Animation layers of one row. Text is rasterised once per (width, appearance, scale) and recoloured
/// only by opacity, so state changes are cheap and animate in the render server.
@MainActor
final class QTLyricsRowNode {
    let container = CALayer()
    let selection = CALayer()
    let mainBase = CALayer()
    let mainFill = CALayer()
    /// The glyphs as an alpha mask for `mainFill`, whose sublayers are the moving colour bands (one per visual line).
    let textMask = CALayer()
    var bands: [CAGradientLayer] = []
    let romanization = CALayer()
    let translation = CALayer()
    var dots: [CALayer] = []
    /// What the images were rendered for.
    var renderKey: String?
    var model: QTLyricsRowModel

    init(model: QTLyricsRowModel) {
        self.model = model
        container.anchorPoint = .zero
        container.masksToBounds = false
        selection.cornerRadius = 8
        selection.cornerCurve = .continuous
        selection.isHidden = true
        for l in [container, selection, mainBase, mainFill, textMask, romanization, translation] {
            l.actions = QTLyricsRowNode.noActions
        }
        container.addSublayer(selection)
        container.addSublayer(mainBase)
        container.addSublayer(mainFill)
        container.addSublayer(romanization)
        container.addSublayer(translation)
        mainFill.isHidden = true
        mainFill.mask = textMask
    }

    /// Disables implicit animations for geometry/contents; state changes use explicit transactions.
    static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull(),
        "sublayers": NSNull(), "mask": NSNull(), "backgroundColor": NSNull(),
    ]

    /// Lays out sublayers and (re)renders images when needed. Returns true when the layers were rebuilt (the
    /// caller restarts karaoke/dots on the current row).
    @discardableResult
    func render(metrics m: QTLyricsMetrics, scale: CGFloat, appearance: NSAppearance) -> Bool {
        let key = "\(model.width)|\(scale)|\(appearance.name.rawValue)|\(m.main.size)|\(m.overArt)"
        container.bounds = CGRect(x: 0, y: 0, width: model.width, height: model.height)
        guard key != renderKey else { return false }
        renderKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.contentsScale = scale
        if model.isGap {
            buildDots(metrics: m, appearance: appearance)
            return true
        }
        var mainImage: CGImage?, romaImage: CGImage?, trImage: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            mainImage = model.main?.render(color: m.mainColor, scale: scale, shadow: m.shadow, outline: m.outline)
            romaImage = model.romanization?.render(color: m.laneColor, scale: scale, shadow: m.shadow)
            trImage = model.translation?.render(color: m.laneColor, scale: scale, shadow: m.shadow)
        }
        func place(_ layer: CALayer, _ layout: QTLyricTextLayout?, _ origin: CGPoint, _ image: CGImage?) {
            guard let layout, let image else {
                layer.contents = nil
                layer.isHidden = true
                return
            }
            layer.isHidden = false
            layer.contents = image
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            let img = layout.imageSize
            layer.frame = CGRect(x: origin.x - layout.padding.left, y: origin.y - layout.padding.top, width: img.width, height: img.height)
        }
        place(mainBase, model.main, model.mainOrigin, mainImage)
        place(mainFill, model.main, model.mainOrigin, mainImage)
        mainFill.contents = nil
        textMask.contents = mainImage
        textMask.contentsScale = scale
        textMask.contentsGravity = .resize
        textMask.frame = mainFill.bounds
        place(romanization, model.romanization, model.romanizationOrigin, romaImage)
        place(translation, model.translation, model.translationOrigin, trImage)
        var fillColor = NSColor.white.cgColor
        appearance.performAsCurrentDrawingAppearance { fillColor = m.mainColor.cgColor.copy(alpha: 1) ?? m.mainColor.cgColor }
        buildBands(metrics: m, color: fillColor)
        selection.frame = container.bounds.insetBy(dx: -10, dy: 0)
        return true
    }

    private func buildBands(metrics m: QTLyricsMetrics, color: CGColor) {
        bands.forEach { $0.removeFromSuperlayer() }
        bands = []
        guard let main = model.main, !model.karaoke.isEmpty else { return }

        let img = main.imageSize
        let width = img.width + m.edge * 2
        for (i, f) in main.fragments.enumerated() {
            let band = CAGradientLayer()
            band.actions = QTLyricsRowNode.noActions
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.colors = [color, color, color.copy(alpha: 0) ?? color]
            band.locations = [0, NSNumber(value: Double((width - m.edge) / width)), 1]
            let top = i == 0 ? 0 : main.padding.top + f.top
            let bottom = i == main.fragments.count - 1 ? img.height : main.padding.top + f.top + main.lineHeight
            band.bounds = CGRect(x: 0, y: 0, width: width, height: bottom - top)
            band.anchorPoint = CGPoint(x: 0.5, y: 0)
            band.position = CGPoint(x: bandPosition(front: f.x - m.edge, layout: main, width: width, edge: m.edge), y: top)
            band.name = "\(i)"
            mainFill.addSublayer(band)
            bands.append(band)
        }
    }

    /// Band centre x (in image coordinates) for a front at block x `front`.
    private func bandPosition(front: CGFloat, layout: QTLyricTextLayout, width: CGFloat, edge: CGFloat) -> CGFloat {
        layout.padding.left + front + edge - width / 2
    }

    private func buildDots(metrics m: QTLyricsMetrics, appearance: NSAppearance) {
        dots.forEach { $0.removeFromSuperlayer() }
        dots = []
        let d = m.dotSize
        let gap = d * 0.9
        let total = d * 3 + gap * 2
        let x0 = m.main.centered ? (model.width - total) / 2 : 2
        var color = NSColor.white.cgColor
        appearance.performAsCurrentDrawingAppearance { color = m.mainColor.cgColor }
        for k in 0..<3 {
            let dot = CALayer()
            dot.actions = QTLyricsRowNode.noActions
            dot.backgroundColor = color
            dot.cornerRadius = d / 2
            dot.frame = CGRect(x: x0 + CGFloat(k) * (d + gap), y: (model.height - d) / 2, width: d, height: d)
            dot.opacity = 0.3
            container.addSublayer(dot)
            dots.append(dot)
        }
    }

    // MARK: Karaoke

    /// Shows the karaoke fill for a lyric time; animates it in the render server while playing.
    func startKaraoke(clock: QTLyricsClock, metrics m: QTLyricsMetrics) {
        guard let main = model.main, !model.karaoke.isEmpty, bands.count == main.fragments.count else {
            stopKaraoke(animated: false, metrics: m)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mainFill.isHidden = false
        mainFill.opacity = 1
        mainBase.opacity = m.unsungOpacity
        let now = clock.now()
        let width = main.imageSize.width + m.edge * 2
        for band in bands {
            band.removeAllAnimations()
            guard let fi = Int(band.name ?? ""), let track = model.karaoke.first(where: { $0.fragment == fi }) else {
                // A visual line with no timed words (rare): lit with the line.
                band.position.x = bandPosition(front: main.size.width + m.edge, layout: main, width: width, edge: m.edge)
                continue
            }
            band.position.x = bandPosition(front: track.front(at: now.lyric), layout: main, width: width, edge: m.edge)
            guard clock.rate > 0, let t0 = track.times.first, let t1 = track.times.last, t1 > now.lyric else { continue }
            let span = max(0.001, t1 - t0)
            let anim = CAKeyframeAnimation(keyPath: "position.x")
            anim.values = track.fronts.map { bandPosition(front: $0, layout: main, width: width, edge: m.edge) }
            anim.keyTimes = track.times.map { NSNumber(value: ($0 - t0) / span) }
            anim.calculationMode = .linear
            anim.duration = span
            anim.speed = Float(clock.rate)
            anim.beginTime = band.convertTime(clock.mediaTime(forLyric: t0, at: now), from: nil)
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            band.add(anim, forKey: "qt.lyrics.karaoke")
        }
        CATransaction.commit()
    }

    func stopKaraoke(animated: Bool, metrics m: QTLyricsMetrics) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(QTTheme.Motion.lyricDuration)
            CATransaction.setAnimationTimingFunction(QTTheme.Motion.caTimingFunction)
            fade(mainFill, to: 0)
            fade(mainBase, to: 1)
        } else {
            mainFill.opacity = 0
            mainBase.opacity = 1
        }
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, to value: Float) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = layer.presentation()?.opacity ?? layer.opacity
        a.toValue = value
        a.duration = QTTheme.Motion.lyricDuration
        a.timingFunction = QTTheme.Motion.caTimingFunction
        layer.opacity = value
        layer.add(a, forKey: "qt.lyrics.fade")
    }

    /// Instrumental dots: each lights up over its third of the gap.
    func startDots(clock: QTLyricsClock) {
        guard case .gap(let s, let e) = model.kind else { return }
        let now = clock.now()
        let third = max(0.1, (e - s) / 3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            let ds = s + Double(k) * third
            let p = min(1, max(0, (now.lyric - ds) / third))
            dot.opacity = Float(0.3 + 0.7 * p)
            dot.transform = CATransform3DMakeScale(CGFloat(0.85 + 0.15 * p), CGFloat(0.85 + 0.15 * p), 1)
            guard clock.rate > 0, p < 1 else { continue }
            let group = CAAnimationGroup()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3
            fade.toValue = 1
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.85
            grow.toValue = 1
            group.animations = [fade, grow]
            group.duration = third
            group.speed = Float(clock.rate)
            group.beginTime = dot.convertTime(clock.mediaTime(forLyric: ds, at: now), from: nil)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.add(group, forKey: "qt.lyrics.dot")
        }
        CATransaction.commit()
    }

    func stopDots() {
        dots.forEach { $0.removeAllAnimations(); $0.opacity = 0.3 }
    }
}
