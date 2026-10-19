import AppKit
import QTCore

// AppKit cells for the track table: native NSTableCellView text fields (so selection, VoiceOver and
// Increase Contrast behave like Finder/Music), artwork decoded off-main via QTImageLoader.

/// Colours the table needs that come from the artwork (tint only; system colours elsewhere).
struct QTTrackTableTint {
    var accentOnDark: NSColor?
    var accentOnLight: NSColor?
    /// Increase Contrast: use the system selection and accent instead of the artwork accent.
    var useSystem = false

    func accent(for appearance: NSAppearance) -> NSColor {
        guard !useSystem else { return .controlAccentColor }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? accentOnDark : accentOnLight) ?? .controlAccentColor
    }

    init(palette: QTArtworkPalette?, increaseContrast: Bool) {
        accentOnDark = palette.map { NSColor(qt: $0.accentOnDark) }
        accentOnLight = palette.map { NSColor(qt: $0.accentOnLight) }
        useSystem = increaseContrast || palette == nil
    }
}

extension NSColor {
    convenience init(qt c: QTRGBColor) {
        self.init(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

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

/// Rounded selection like the prototype (`--select`: artwork accent at ~1/3 strength), text stays in label
/// colours. Falls back to the system's emphasized selection under Increase Contrast or without artwork.
final class QTTrackRowView: NSTableRowView {
    var tint = QTTrackTableTint(palette: nil, increaseContrast: false) { didSet { needsDisplay = true } }
    var isUnavailable = false
    private var isHovered = false
    private var tracking: NSTrackingArea?

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        tint.useSystem ? super.interiorBackgroundStyle : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6)
        if tint.useSystem {
            (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        } else {
            tint.accent(for: effectiveAppearance).withAlphaComponent(isEmphasized ? 0.34 : 0.2).setFill()
        }
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected, !isUnavailable else { return }
        NSColor.quaternarySystemFill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}

// MARK: - Number / now-playing

final class QTTrackNumberCell: NSTableCellView {
    enum Playing { case none, playing, paused }
    private let label = makeLabel(font: QTTrackFonts.number, color: .tertiaryLabelColor)
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
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

    func configure(number: Int, playing: Playing, accent: NSColor) {
        label.stringValue = number.formatted(.number.locale(QTLoc.locale))
        label.isHidden = playing != .none
        icon.isHidden = playing == .none
        icon.image = QTNowPlayingIndicator.image(isPlaying: playing == .playing)
        icon.contentTintColor = accent
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

    /// `showsArtwork: false` on album pages, where every row would repeat the album cover (Music.app style).
    func configure(_ track: QTTrack, isPlaying: Bool, accent: NSColor, showsArtwork: Bool = true) {
        artwork.isHidden = !showsArtwork
        artworkWidth.constant = showsArtwork ? QTTheme.Metrics.rowArtwork : 0
        textLeading.constant = showsArtwork ? 14 : 0
        if showsArtwork { artwork.load(track.artwork, pointSize: QTTheme.Metrics.rowArtwork) }
        let s = NSMutableAttributedString(string: track.title, attributes: [
            .font: QTTrackFonts.title, .foregroundColor: isPlaying ? accent : NSColor.labelColor,
        ])
        if let sub = track.subtitle, !sub.isEmpty {
            s.append(NSAttributedString(string: " (\(sub))", attributes: [
                .font: QTTrackFonts.body, .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        title.attributedStringValue = s
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
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: alignment == .right ? 0 : -12),
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

    func configure(liked: Bool, accent: NSColor, enabled: Bool) {
        let label = QTLoc.tr(liked ? "Remove from Liked Songs" : "Like")
        button.image = NSImage(systemSymbolName: liked ? "heart.fill" : "heart", accessibilityDescription: label)
        button.contentTintColor = liked ? accent : .tertiaryLabelColor
        button.toolTip = "\(label)  ⌘L"
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
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
