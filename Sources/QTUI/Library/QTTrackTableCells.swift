import AppKit
import QTCore

// AppKit cells for the track table: native NSTableCellView text fields (so selection, VoiceOver and
// Increase Contrast behave like Finder/Music), artwork decoded off-main via QTImageLoader.

enum QTTrackFonts {
    static var body: NSFont { NSFont.preferredFont(forTextStyle: .body) }
    static var title: NSFont { NSFont.systemFont(ofSize: body.pointSize, weight: .medium) }
    static var secondary: NSFont { NSFont.preferredFont(forTextStyle: .callout) }
    static var badge: NSFont { NSFont.systemFont(ofSize: max(9, secondary.pointSize - 2), weight: .semibold) }
    static var number: NSFont { NSFont.monospacedDigitSystemFont(ofSize: secondary.pointSize, weight: .regular) }
    static var time: NSFont { NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular) }
}

@MainActor
private func makeLabel(font: NSFont, color: NSColor) -> NSTextField {
    let f = NSTextField(labelWithString: "")
    f.font = font
    f.textColor = color
    f.lineBreakMode = .byTruncatingTail
    f.maximumNumberOfLines = 1
    f.cell?.truncatesLastVisibleLine = true
    f.translatesAutoresizingMaskIntoConstraints = false
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return f
}

// MARK: - Row

/// Rounded selection like Finder and Music: the app's accent when the table is focused (the song's colour, or the
/// system accent — Settings › Accent colour), the unemphasized grey otherwise. Hover draws a quiet fill and reveals
/// the row's heart.
final class QTTrackRowView: NSTableRowView {
    var isUnavailable = false
    /// The focused selection's fill (`QTTheme.Colors.nsAccent`; nil = the system's selection colour).
    var accent: NSColor? { didSet { if accent != oldValue, isSelected { needsDisplay = true } } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true; revealControls() } } }
    private var tracking: NSTrackingArea?

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { revealControls() } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6)
        (isEmphasized ? accent ?? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected, !isUnavailable else { return }
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    /// Cells added after the row (reuse, scrolling) ask through `isRevealingControls`.
    var isRevealingControls: Bool { isHovered || isSelected }

    private func revealControls() {
        for case let cell as QTTrackHeartCell in subviews { cell.isRowRevealing = isRevealingControls }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? QTTrackHeartCell)?.isRowRevealing = isRevealingControls
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { Self.hover(self) }
    override func mouseExited(with event: NSEvent) { if Self.hovered === self { Self.hover(nil) } }

    override func prepareForReuse() {
        super.prepareForReuse()
        if Self.hovered === self { Self.hover(nil) }
        isHovered = false
    }

    // Hover has one owner: AppKit drops a row's mouse-exited when the window loses key, when the list scrolls under a
    // still pointer, or while a menu tracks, which left rows lit after the pointer had gone. At most one row is
    // hovered; it's cleared when its window stops being key and rechecked against the pointer after a scroll.
    private static weak var hovered: QTTrackRowView?
    private static var observers: [NSObjectProtocol] = []

    private static func hover(_ row: QTTrackRowView?) {
        if hovered !== row { hovered?.isHovered = false }
        hovered = row
        row?.isHovered = true
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if hovered?.window?.isKeyWindow != true { hover(nil) } }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hover(nil) }
            },
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { recheckHover() }
            },
        ]
    }

    /// After a scroll: the hover moves to the row now under the pointer (none when it's outside the list).
    private static func recheckHover() {
        guard let row = hovered else { return }
        guard let table = row.superview as? NSTableView, let window = table.window, window.isKeyWindow else {
            hover(nil)
            return
        }
        let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let index = table.visibleRect.contains(point) ? table.row(at: point) : -1
        hover(index < 0 ? nil : table.rowView(atRow: index, makeIfNecessary: false) as? QTTrackRowView)
    }
}

private extension NSView.BackgroundStyle {
    /// Text over the accent-filled (focused) selection draws white.
    var isEmphasizedSelection: Bool { self == .emphasized }
}

// MARK: - Number / now-playing

final class QTTrackNumberCell: NSTableCellView {
    enum Playing { case none, playing, paused }
    private let label = makeLabel(font: QTTrackFonts.number, color: .tertiaryLabelColor)
    private let icon = QTNowPlayingBarsView(pointSize: 12, weight: .regular)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(icon)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var accent: NSColor = .controlAccentColor

    func configure(number: Int, playing: Playing, accent: NSColor) {
        label.stringValue = number.formatted(.number.locale(QTLoc.locale))
        label.isHidden = playing != .none
        icon.isHidden = playing == .none
        icon.show(isPlaying: playing == .playing, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        self.accent = accent
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    private func applyColors() {
        icon.tint = backgroundStyle.isEmphasizedSelection ? .alternateSelectedControlTextColor : accent
    }
}

// MARK: - Title + artist

final class QTTrackTitleCell: NSTableCellView {
    private let artwork = QTArtworkLayerView()
    private let title = makeLabel(font: QTTrackFonts.title, color: .labelColor)
    private let subtitleRow = NSStackView()
    private let artist = makeLabel(font: QTTrackFonts.secondary, color: .secondaryLabelColor)
    private let mvBadge = QTBadgeLabel()
    private let lyricsBadge = QTBadgeLabel()
    private var artworkWidth: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var shown: (title: String, subtitle: String?, isPlaying: Bool, accent: NSColor) = ("", nil, false, .labelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        subtitleRow.orientation = .horizontal
        subtitleRow.spacing = 6
        subtitleRow.alignment = .centerY
        subtitleRow.translatesAutoresizingMaskIntoConstraints = false
        subtitleRow.setViews([mvBadge, lyricsBadge, artist], in: .leading)
        subtitleRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, subtitleRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setClippingResistancePriority(.defaultLow, for: .horizontal)
        addSubview(artwork)
        addSubview(text)
        textField = title
        artworkWidth = artwork.widthAnchor.constraint(equalToConstant: QTTheme.Metrics.rowArtwork)
        textLeading = text.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkWidth,
            artwork.heightAnchor.constraint(equalToConstant: QTTheme.Metrics.rowArtwork),
            textLeading,
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { if backgroundStyle != oldValue { applyTitle() } } }

    /// The now-playing title takes the app's accent; over the focused (accent-filled) selection it's white.
    private func applyTitle() {
        let onSelection = backgroundStyle.isEmphasizedSelection
        let titleColor: NSColor = onSelection ? .alternateSelectedControlTextColor : (shown.isPlaying ? shown.accent : .labelColor)
        let s = NSMutableAttributedString(string: shown.title, attributes: [.font: QTTrackFonts.title, .foregroundColor: titleColor])
        if let sub = shown.subtitle, !sub.isEmpty {
            s.append(NSAttributedString(string: " (\(sub))", attributes: [
                .font: QTTrackFonts.body,
                .foregroundColor: onSelection ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7) : NSColor.tertiaryLabelColor,
            ]))
        }
        title.attributedStringValue = s
    }

    /// `showsArtwork: false` on album pages, where every row would repeat the album cover (Music.app style).
    func configure(_ track: QTTrack, isPlaying: Bool, accent: NSColor, showsArtwork: Bool = true) {
        artwork.isHidden = !showsArtwork
        artworkWidth.constant = showsArtwork ? QTTheme.Metrics.rowArtwork : 0
        textLeading.constant = showsArtwork ? 14 : 0
        if showsArtwork { artwork.load(track.artwork, pointSize: QTTheme.Metrics.rowArtwork) }
        shown = (track.title, track.subtitle, isPlaying, accent)
        applyTitle()
        artist.stringValue = track.artistLine
        mvBadge.stringValue = QTLoc.tr("MV", table: .main)
        mvBadge.isHidden = !track.hasVideo
        lyricsBadge.stringValue = QTLoc.tr("Word lyrics")
        lyricsBadge.isHidden = track.lyricsHint != .word
        setAccessibilityLabel([track.title, track.subtitle, track.artistLine].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Small filled badge ("MV", "Word lyrics"), like Music.app's quiet format badges.
final class QTBadgeLabel: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        font = QTTrackFonts.badge
        textColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.cornerCurve = .continuous
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 8, height: s.height + 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let text = attributedStringValue
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

// MARK: - Plain text (album, time)

final class QTTrackTextCell: NSTableCellView {
    private let label: NSTextField

    init(font: NSFont, alignment: NSTextAlignment) {
        label = makeLabel(font: font, color: .secondaryLabelColor)
        super.init(frame: .zero)
        label.alignment = alignment
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            // Right-aligned (Time) too: the row's selection and hover fills end at the cell's edge.
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) { label.stringValue = text }
}

// MARK: - Heart

final class QTTrackHeartCell: NSTableCellView {
    private let button = NSButton()
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var liked = false
    private var accent: NSColor = .controlAccentColor
    /// The now-playing row keeps its heart visible.
    private var isCurrent = false
    /// Set by the row: hovered or selected.
    var isRowRevealing = false { didSet { if isRowRevealing != oldValue { applyVisibility() } } }

    /// One stable heart that shows on hover, selection and the now-playing row: filled when
    /// liked, in the app's accent like the player bar's and Home's hearts.
    func configure(liked: Bool, accent: NSColor, enabled: Bool, isCurrent: Bool = false) {
        self.liked = liked
        self.isCurrent = isCurrent
        self.accent = accent
        let label = QTLoc.tr(liked ? "Remove from Liked Songs" : "Like")
        button.image = NSImage(systemSymbolName: liked ? "heart.fill" : "heart", accessibilityDescription: label)
        button.toolTip = "\(label)  ⌘L"
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
        applyColors()
        applyVisibility()
    }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    private func applyColors() {
        if backgroundStyle.isEmphasizedSelection {
            button.contentTintColor = .alternateSelectedControlTextColor
        } else {
            button.contentTintColor = liked ? accent : .tertiaryLabelColor
        }
    }

    private func applyVisibility() {
        // Hidden, not removed: VoiceOver and the ⌘L / context-menu paths keep working; the column keeps its width.
        button.alphaValue = isRowRevealing || isCurrent ? 1 : 0
    }

    @objc private func toggle() { onToggle?() }
}

// MARK: - Artwork

/// Layer-backed artwork thumbnail: rounded, no border, downsampled and cached by `QTImageLoader`.
final class QTArtworkLayerView: NSView {
    private var task: Task<Void, Never>?
    private var currentURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if layer?.contents == nil { layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor }
    }

    func load(_ images: [QTArtworkImage], pointSize: CGFloat) {
        let scale = window?.backingScaleFactor ?? 2
        let pixels = Int(pointSize * scale)
        guard let url = images.best(forPixelWidth: pixels)?.url else {
            task?.cancel(); currentURL = nil; layer?.contents = nil
            return
        }
        guard url != currentURL else { return }
        currentURL = url
        layer?.contents = nil
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let image = await QTImageLoader.shared.image(at: url, maxPixel: pixels)
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            let t = CATransition()
            t.duration = 0.15
            self.layer?.add(t, forKey: "contents")
            self.layer?.contents = image
            self.layer?.backgroundColor = image == nil ? NSColor.quaternarySystemFill.cgColor : nil
        }
    }
}
