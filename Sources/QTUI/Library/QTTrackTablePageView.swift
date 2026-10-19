import AppKit
import QTCore

/// AppKit page for a track list: one NSScrollView whose document holds the big SwiftUI header, the native
/// NSTableHeaderView and the NSTableView. When the big header scrolls away, a compact bar (title, Play,
/// Shuffle, filter) pins to the top with the column headings pinned beneath it, over a header material —
/// the prototype's sticky header (`.lib-compact` + `.t-row.header.pinned`), done with real AppKit parts.
@MainActor
final class QTTrackTablePageView: NSView {
    let scrollView = NSScrollView()
    let documentView = QTFlippedView()
    let tableView = QTTrackNSTableView()
    let columnHeader = QTColumnHeaderView(frame: NSRect(x: 0, y: 0, width: 400, height: QTTrackTablePageView.columnHeaderHeight))
    let pinnedBackground = NSVisualEffectView()
    private let pinnedSeparator = NSBox()
    let emptyLabel = NSTextField(labelWithString: "")
    var headerHost: NSView? { didSet { oldValue?.removeFromSuperview(); if let headerHost { documentView.addSubview(headerHost, positioned: .below, relativeTo: tableView) } } }
    var compactHost: NSView? { didSet { oldValue?.removeFromSuperview(); if let compactHost { compactHost.alphaValue = 0; documentView.addSubview(compactHost, positioned: .above, relativeTo: pinnedBackground) } } }
    var alphabetHost: NSView? { didSet { oldValue?.removeFromSuperview(); if let alphabetHost { documentView.addSubview(alphabetHost) } } }

    static let columnHeaderHeight: CGFloat = 30
    static let compactHeight: CGFloat = 56
    static let leadingInset: CGFloat = 32
    static let trailingInset: CGFloat = 44
    static let bottomInset: CGFloat = 44
    static let alphabetWidth: CGFloat = 20
    static let alphabetLetterHeight: CGFloat = 14

    var headerHeight: CGFloat = 0 { didSet { needsLayout = true } }
    var hasCompactBar = true
    var reduceMotion = false
    /// Scroll offset changed (y in document coordinates).
    var onScroll: ((CGFloat) -> Void)?
    /// Pinned state flipped.
    var onPinnedChange: ((Bool) -> Void)?
    private(set) var isPinned = false
    private var pendingScrollY: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.verticalScrollElasticity = .allowed
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tableView.headerView = columnHeader
        columnHeader.tableView = tableView
        tableView.cornerView = nil
        documentView.addSubview(tableView)

        pinnedBackground.material = .headerView
        pinnedBackground.blendingMode = .withinWindow
        pinnedBackground.state = .followsWindowActiveState
        pinnedBackground.alphaValue = 0
        pinnedSeparator.boxType = .separator
        pinnedBackground.addSubview(pinnedSeparator)
        documentView.addSubview(pinnedBackground)
        documentView.addSubview(columnHeader)

        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.setAccessibilityIdentifier("qt.library.emptyFilter")
        documentView.addSubview(emptyLabel)

        // Selector-based observers are removed automatically when the view goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clipBoundsChanged(_ note: Notification) { scrolled() }
    @objc private func clipFrameChanged(_ note: Notification) { needsLayout = true }

    // MARK: Layout

    var tableTop: CGFloat { headerHeight + Self.columnHeaderHeight }
    private var tableWidth: CGFloat { max(200, scrollView.contentView.bounds.width - Self.leadingInset - Self.trailingInset) }
    /// Height covered at the top of the visible area when pinned (compact bar + column headings).
    var pinnedObstruction: CGFloat { (isPinned && hasCompactBar ? Self.compactHeight : 0) + Self.columnHeaderHeight }

    override func layout() {
        super.layout()
        layoutDocument()
        if let y = pendingScrollY, scrollView.contentView.bounds.height > 0 {
            pendingScrollY = nil
            scroll(toY: y, animated: false)
        }
    }

    func layoutDocument() {
        let clip = scrollView.contentView.bounds
        let width = clip.width
        guard width > 0 else { return }
        let rows = CGFloat(tableView.numberOfRows)
        let tableHeight = max(rows * tableView.rowHeight, 1)
        let emptyHeight: CGFloat = emptyLabel.isHidden ? 0 : 120
        let docHeight = max(tableTop + tableHeight + emptyHeight + Self.bottomInset, clip.height)
        if documentView.frame.size != NSSize(width: width, height: docHeight) {
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: docHeight)
        }
        headerHost?.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        let tableFrame = NSRect(x: Self.leadingInset, y: tableTop, width: tableWidth, height: tableHeight)
        if tableView.frame != tableFrame {
            tableView.pinnedSize = tableFrame.size
            tableView.frame = tableFrame
        }
        fitColumns(to: tableFrame.width)
        emptyLabel.frame = NSRect(x: Self.leadingInset, y: tableTop + 40, width: tableWidth, height: 24)
        layoutFloating()
    }

    /// Sticky parts: compact bar, column headings, A–Z strip. Called on every scroll.
    private func layoutFloating() {
        let clip = scrollView.contentView.bounds
        let y = max(0, clip.minY)
        let width = clip.width
        let pinned = hasCompactBar && headerHeight > 0 && y > headerHeight - Self.compactHeight
        if pinned != isPinned {
            isPinned = pinned
            setPinnedChrome(visible: pinned)
            onPinnedChange?(pinned)
        }
        let compactH = hasCompactBar ? Self.compactHeight : 0
        let headerY = pinned ? y + compactH : max(headerHeight, y)
        columnHeader.frame = NSRect(x: Self.leadingInset, y: headerY, width: tableWidth, height: Self.columnHeaderHeight)
        let pinnedHeight = compactH + Self.columnHeaderHeight
        let showsPinnedBackground = pinned || (!hasCompactBar && y > headerHeight)
        pinnedBackground.frame = NSRect(x: 0, y: pinned ? y : headerY, width: width, height: pinned ? pinnedHeight : Self.columnHeaderHeight)
        pinnedSeparator.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        if !hasCompactBar { pinnedBackground.alphaValue = showsPinnedBackground ? 1 : 0 }
        compactHost?.frame = NSRect(x: 0, y: y, width: width, height: compactH)
        if let alphabetHost {
            let h = CGFloat(QTTextFolding.indexLetters.count) * Self.alphabetLetterHeight
            let top = max(tableTop + 6, y + (pinned ? pinnedHeight : 0) + 10)
            alphabetHost.frame = NSRect(x: width - Self.alphabetWidth - 12, y: top, width: Self.alphabetWidth, height: h)
        }
    }

    /// Fixed columns keep their width; the flexible ones (title, album) share the rest in their current ratio,
    /// so a user's column resize is kept proportionally when the window changes size.
    private func fitColumns(to width: CGFloat) {
        let cols = tableView.tableColumns
        let flexible = cols.filter { $0.resizingMask.contains(.autoresizingMask) }
        let fixed = cols.filter { !$0.resizingMask.contains(.autoresizingMask) }.reduce(0) { $0 + $1.width }
        let available = max(0, width - fixed)
        let current = flexible.reduce(0) { $0 + $1.width }
        guard current > 0, abs(current - available) > 0.5 else { return }
        var remaining = available
        for (i, c) in flexible.enumerated() {
            let w = i == flexible.count - 1 ? remaining : (available * c.width / current).rounded()
            c.width = max(c.minWidth, w)
            remaining -= c.width
        }
        columnHeader.needsDisplay = true
    }

    private func setPinnedChrome(visible: Bool) {
        let views = [pinnedBackground, compactHost].compactMap { $0 }
        if reduceMotion {
            views.forEach { $0.alphaValue = visible ? 1 : 0 }
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = QTTheme.Motion.caTimingFunction
            views.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    private func scrolled() {
        layoutFloating()
        onScroll?(scrollView.contentView.bounds.minY)
    }

    // MARK: Scrolling

    /// Restores a saved offset once the document has its size.
    func restoreScroll(_ y: CGFloat) {
        pendingScrollY = y
        needsLayout = true
    }

    func scroll(toY y: CGFloat, animated: Bool) {
        let clip = scrollView.contentView
        let maxY = max(0, documentView.frame.height - clip.bounds.height)
        let target = NSPoint(x: 0, y: min(max(0, y), maxY))
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = QTTheme.Motion.uiDuration
                ctx.timingFunction = QTTheme.Motion.caTimingFunction
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the row to the top of the visible table area (below pinned chrome).
    func scrollRowToTop(_ row: Int, animated: Bool) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let rowTop = tableTop + tableView.rect(ofRow: row).minY
        let obstruction = (hasCompactBar && headerHeight > 0 ? Self.compactHeight : 0) + Self.columnHeaderHeight
        scroll(toY: rowTop - obstruction - 8, animated: animated)
    }

    /// Minimal scroll so the row is fully visible below the pinned chrome (keyboard navigation).
    func scrollRowIntoView(_ row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        let clip = scrollView.contentView.bounds
        let r = tableView.rect(ofRow: row).offsetBy(dx: 0, dy: tableTop)
        let topLimit = clip.minY + pinnedObstruction
        if r.minY < topLimit {
            // Scrolling up may un-pin the header; account for the compact bar either way.
            let obstruction = (hasCompactBar && headerHeight > 0 && r.minY - Self.compactHeight - Self.columnHeaderHeight > headerHeight - Self.compactHeight)
                ? Self.compactHeight + Self.columnHeaderHeight : Self.columnHeaderHeight
            scroll(toY: r.minY - obstruction, animated: false)
        } else if r.maxY > clip.maxY {
            scroll(toY: r.maxY - clip.height, animated: false)
        }
    }
}

/// Column headings drawn without the header's own opaque background (it sits on the page, or on the pinned
/// header material): native header-cell text and sort indicators, a hairline separator below.
final class QTColumnHeaderView: NSTableHeaderView {
    /// Sort key whose indicator is hidden ("#" = the playlist's own order).
    var hiddenSortKey = QTTrackSort.Key.added.rawValue

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let t = tableView else { return }
        let sort = t.sortDescriptors.first
        for (i, col) in t.tableColumns.enumerated() {
            let r = headerRect(ofColumn: i)
            guard r.intersects(dirtyRect) else { continue }
            let cell = col.headerCell
            let isSorted = sort?.key != nil && sort?.key == col.sortDescriptorPrototype?.key && sort?.key != hiddenSortKey
            cell.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            cell.textColor = isSorted ? .labelColor : .tertiaryLabelColor
            let rightAligned = cell.alignment == .right
            var textRect = r
            if isSorted { textRect.size.width -= 16; if rightAligned { textRect.origin.x += 16 } }
            cell.drawInterior(withFrame: textRect, in: self)
            if isSorted, let sort {
                // Native indicator; for the right-aligned Time column it sits before the label (prototype).
                let frame = rightAligned ? NSRect(x: r.minX, y: r.minY, width: 22, height: r.height) : r
                cell.drawSortIndicator(withFrame: frame, in: self, ascending: sort.ascending, priority: 0)
            }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// Flipped container so the document lays out top-down.
final class QTFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The table: Finder keyboard behaviour (↩ plays, ⌥↩ plays next, Space play/pause, ⌘C copies links),
/// scrolls rows into view below the pinned chrome.
final class QTTrackNSTableView: NSTableView {
    var onReturn: ((_ option: Bool) -> Void)?
    var onSpace: (() -> Void)?
    var onCopy: (() -> Void)?
    var onScrollRowToVisible: ((Int) -> Void)?
    /// Frame size the page lays out; NSTableView would otherwise stretch itself to the clip view's width.
    var pinnedSize: NSSize?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(pinnedSize ?? newSize)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch event.keyCode {
        case 36, 76: // return, enter
            if mods.isEmpty || mods == .option { onReturn?(mods == .option); return }
        case 49 where mods.isEmpty: // space
            onSpace?()
            return
        default: break
        }
        super.keyDown(with: event)
    }

    override func scrollRowToVisible(_ row: Int) {
        if let onScrollRowToVisible { onScrollRowToVisible(row) } else { super.scrollRowToVisible(row) }
    }

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}
