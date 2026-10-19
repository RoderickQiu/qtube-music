import AppKit
import QTCore
import SwiftUI

/// A Finder-grade track table (NSTableView): system column headers with sort indicators, click selects,
/// double-click / ↩ plays, ⇧/⌘ multi-select, ⌥↩ plays next, type-select, NSMenu context menu, drag rows to
/// sidebar playlists (or as links to other apps), A–Z strip (long title-sorted lists only), sticky compact header. See `QTTrackTablePageView`.
struct QTTrackTable: NSViewRepresentable {
    var collection: QTTrackCollection
    var rows: [QTTrack]
    var state: QTTrackListState
    var destination: QTDestination?
    var header: AnyView?
    var headerHeight: CGFloat
    var compact: AnyView?
    var playingID: String?
    var isPlaying: Bool
    var likedIDs: Set<String>
    var reduceMotion: Bool
    var emptyText: String?
    var showsAlphabet: Bool
    /// Interface language the cells were drawn in; a runtime switch redraws every cached cell (badges, tooltips).
    var language: QTResolvedInterfaceLanguage = QTLoc.language

    func makeCoordinator() -> QTTrackTableCoordinator { QTTrackTableCoordinator() }

    func makeNSView(context: Context) -> QTTrackTablePageView {
        let page = QTTrackTablePageView()
        context.coordinator.attach(page)
        context.coordinator.update(self, first: true)
        return page
    }

    func updateNSView(_ page: QTTrackTablePageView, context: Context) {
        context.coordinator.update(self, first: false)
    }
}

@MainActor
final class QTTrackTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Column: String, CaseIterable {
        case number = "qt.library.column.number"
        case title = "qt.library.column.title"
        case album = "qt.library.column.album"
        case heart = "qt.library.column.liked"
        case time = "qt.library.column.time"

        var id: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    }

    private weak var page: QTTrackTablePageView?
    private var config: QTTrackTable?
    private var rows: [QTTrack] = []
    private var headerHost: NSHostingView<AnyView>?
    private var compactHost: NSHostingView<AnyView>?
    private var alphabetHost: NSHostingView<QTAlphabetStrip>?
    private var isApplyingSort = false
    private var isRestoringSelection = false
    private var model: QTAppModel { .shared }

    // MARK: Setup

    func attach(_ page: QTTrackTablePageView) {
        self.page = page
        let t = page.tableView
        t.dataSource = self
        t.delegate = self
        t.style = .plain
        t.rowHeight = QTTheme.Metrics.tableRowHeight
        t.intercellSpacing = NSSize(width: 0, height: 0)
        t.backgroundColor = .clear
        t.gridStyleMask = []
        t.focusRingType = .none
        t.allowsMultipleSelection = true
        t.allowsEmptySelection = true
        t.allowsColumnReordering = false
        t.allowsColumnResizing = true
        t.allowsTypeSelect = true
        t.usesAutomaticRowHeights = false
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.target = self
        t.doubleAction = #selector(doubleClicked(_:))
        t.setDraggingSourceOperationMask(.copy, forLocal: true)
        t.setDraggingSourceOperationMask(.copy, forLocal: false)
        t.setAccessibilityIdentifier("qt.library.table")
        t.onReturn = { [weak self] option in self?.returnPressed(option: option) }
        t.onSpace = { [weak self] in self?.model.player.togglePlayPause() }
        t.onCopy = { [weak self] in
            guard let self else { return }
            QTTrackActions.copyLinks(self.tracks(at: self.page?.tableView.selectedRowIndexes ?? []))
        }
        t.onScrollRowToVisible = { [weak page] row in page?.scrollRowIntoView(row) }

        for c in Column.allCases {
            let col = NSTableColumn(identifier: c.id)
            switch c {
            case .number:
                col.width = 40; col.minWidth = 40; col.maxWidth = 40; col.resizingMask = []
                col.headerCell.alignment = .center
                col.sortDescriptorPrototype = NSSortDescriptor(key: QTTrackSort.Key.added.rawValue, ascending: true)
            case .title:
                col.width = 380; col.minWidth = 220; col.resizingMask = [.autoresizingMask, .userResizingMask]
                col.sortDescriptorPrototype = NSSortDescriptor(key: QTTrackSort.Key.title.rawValue, ascending: true)
            case .album:
                col.width = 250; col.minWidth = 140; col.resizingMask = [.autoresizingMask, .userResizingMask]
                col.sortDescriptorPrototype = NSSortDescriptor(key: QTTrackSort.Key.album.rawValue, ascending: true)
            case .heart:
                col.width = 44; col.minWidth = 44; col.maxWidth = 44; col.resizingMask = []
            case .time:
                col.width = 60; col.minWidth = 60; col.maxWidth = 60; col.resizingMask = []
                col.headerCell.alignment = .right
                col.sortDescriptorPrototype = NSSortDescriptor(key: QTTrackSort.Key.time.rawValue, ascending: true)
            }
            t.addTableColumn(col)
        }
        let menu = NSMenu()
        menu.delegate = self
        t.menu = menu

        page.onScroll = { [weak self] y in
            guard let self, let config = self.config else { return }
            config.state.scrollY = y
            if let d = config.destination { QTNavigator.shared.setScrollOffset(y, for: d) }
        }
        page.onPinnedChange = { [weak self] pinned in
            self?.config?.state.isHeaderPinned = pinned
        }
    }

    func update(_ new: QTTrackTable, first: Bool) {
        guard let page else { return }
        let old = config
        config = new
        page.reduceMotion = new.reduceMotion
        page.hasCompactBar = new.compact != nil
        page.headerHeight = new.header == nil ? 0 : new.headerHeight
        // An album page doesn't repeat its own title in every row.
        page.tableView.tableColumn(withIdentifier: Column.album.id)?.isHidden = new.collection.kind == .album
        updateHosts(new, page: page)
        updateHeaderTitles()

        let t = page.tableView
        let newIDs = new.rows.map(\.videoId)
        let rowsChanged = newIDs != rows.map(\.videoId)
        let languageChanged = old.map { $0.language != new.language } ?? false
        if languageChanged { page.tableView.tableColumn(withIdentifier: Column.heart.id)?.headerToolTip = QTLoc.tr("Liked Songs") }
        if rowsChanged || first || languageChanged {
            rows = new.rows
            t.reloadData()
            restoreSelection(new.state.selection)
            page.emptyLabel.stringValue = new.emptyText ?? ""
            page.emptyLabel.isHidden = !(rows.isEmpty && new.emptyText != nil)
            page.needsLayout = true
        } else if old?.playingID != new.playingID || old?.isPlaying != new.isPlaying || old?.likedIDs != new.likedIDs {
            rows = new.rows
            // The rows whose marks changed (old/new now-playing, liked changes) by index — not only the visible
            // rect, which can be empty while the table is still being laid out (the launch cue lands then).
            var ids: Set<String> = []
            if let id = old?.playingID { ids.insert(id) }
            if let id = new.playingID { ids.insert(id) }
            ids.formUnion((old?.likedIDs ?? []).symmetricDifference(new.likedIDs))
            reloadVisibleRows(including: IndexSet(rows.indices.filter { ids.contains(rows[$0].videoId) }))
        }
        let descriptor = NSSortDescriptor(key: new.state.sort.key.rawValue, ascending: new.state.sort.ascending)
        if t.sortDescriptors.first != descriptor {
            isApplyingSort = true
            t.sortDescriptors = [descriptor]
            isApplyingSort = false
        }
        if first { page.restoreScroll(new.state.scrollY) }
        new.state.focusTable = { [weak self] in self?.focusTable() }
    }

    private func focusTable() {
        guard let page else { return }
        let t = page.tableView
        if t.selectedRowIndexes.isEmpty, !rows.isEmpty { t.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        page.window?.makeFirstResponder(t)
        if let r = t.selectedRowIndexes.first { page.scrollRowIntoView(r) }
    }

    private func updateHosts(_ new: QTTrackTable, page: QTTrackTablePageView) {
        if let header = new.header {
            if let headerHost { headerHost.rootView = header } else {
                let h = NSHostingView(rootView: header)
                h.sizingOptions = []
                headerHost = h
                page.headerHost = h
            }
        } else if headerHost != nil {
            headerHost = nil
            page.headerHost = nil
        }
        if let compact = new.compact {
            if let compactHost { compactHost.rootView = compact } else {
                let h = NSHostingView(rootView: compact)
                h.sizingOptions = []
                compactHost = h
                page.compactHost = h
            }
        } else if compactHost != nil {
            compactHost = nil
            page.compactHost = nil
        }
        if new.showsAlphabet && Self.wantsAlphabet(rowCount: new.rows.count, sort: new.state.sort.key) {
            let strip = QTAlphabetStrip(available: availableLetters(new.rows, sort: new.state.sort.key),
                                        onJump: { [weak self] letter in self?.jump(to: letter) })
            if let alphabetHost { alphabetHost.rootView = strip } else {
                let h = NSHostingView(rootView: strip)
                h.sizingOptions = []
                alphabetHost = h
                page.alphabetHost = h
            }
        } else if alphabetHost != nil {
            alphabetHost = nil
            page.alphabetHost = nil
        }
    }

    private func updateHeaderTitles() {
        guard let t = page?.tableView else { return }
        let titles: [Column: String] = [.number: "#", .title: QTLoc.tr("Title"), .album: QTLoc.tr("Album"), .heart: "", .time: QTLoc.tr("Time")]
        var changed = false
        for c in Column.allCases {
            guard let col = t.tableColumn(withIdentifier: c.id), let title = titles[c], col.title != title else { continue }
            col.title = title
            changed = true
        }
        if c(.heart, in: t)?.headerToolTip == nil { c(.heart, in: t)?.headerToolTip = QTLoc.tr("Liked Songs") }
        if changed { page?.columnHeader.needsDisplay = true }
    }

    private func c(_ column: Column, in t: NSTableView) -> NSTableColumn? { t.tableColumn(withIdentifier: column.id) }

    private func reloadVisibleRows(including extra: IndexSet = []) {
        guard let t = page?.tableView else { return }
        let visible = t.rows(in: t.visibleRect)
        var indexes = extra.filteredIndexSet { $0 < t.numberOfRows }
        if visible.length > 0 { indexes.formUnion(IndexSet(integersIn: visible.location..<(visible.location + visible.length))) }
        guard !indexes.isEmpty else { return }
        t.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns))
    }

    private func restoreSelection(_ ids: [String]) {
        guard let t = page?.tableView else { return }
        let set = Set(ids)
        let idx = IndexSet(rows.enumerated().filter { set.contains($0.element.videoId) }.map(\.offset))
        isRestoringSelection = true
        t.selectRowIndexes(idx, byExtendingSelection: false)
        isRestoringSelection = false
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSort, let d = tableView.sortDescriptors.first, let key = d.key.flatMap(QTTrackSort.Key.init(rawValue:)),
              let state = config?.state else { return }
        // "#" always returns to the playlist's own order.
        state.sort = QTTrackSort(key: key, ascending: key == .added ? true : d.ascending)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), rows[row].availability.isPlayable else { return nil }
        let item = NSPasteboardItem()
        item.setString(QTTrackActions.link(for: rows[row]), forType: .string)
        return item
    }

    // MARK: Delegate

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("qt.library.row")
        let v = (tableView.makeView(withIdentifier: id, owner: nil) as? QTTrackRowView) ?? {
            let r = QTTrackRowView()
            r.identifier = id
            return r
        }()
        v.isUnavailable = rows.indices.contains(row) && !rows[row].availability.isPlayable
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue), rows.indices.contains(row),
              let config else { return nil }
        let track = rows[row]
        // Now-playing marks (speaker glyph, title) use the system accent like every mark and control in the window;
        // the artwork colour stays an ambient wash (accent policy).
        let accent = NSColor.controlAccentColor
        let isCurrent = track.videoId == config.playingID
        let cellID = NSUserInterfaceItemIdentifier(column.rawValue + ".cell")
        let view: NSView
        switch column {
        case .number:
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? QTTrackNumberCell) ?? QTTrackNumberCell()
            cell.configure(number: row + 1, playing: isCurrent ? (config.isPlaying ? .playing : .paused) : .none, accent: accent)
            view = cell
        case .title:
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? QTTrackTitleCell) ?? QTTrackTitleCell()
            cell.configure(track, isPlaying: isCurrent, accent: accent, showsArtwork: config.collection.kind != .album)
            view = cell
        case .album:
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? QTTrackTextCell)
                ?? QTTrackTextCell(font: QTTrackFonts.body, alignment: .left)
            cell.configure(track.album?.title ?? "")
            view = cell
        case .heart:
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? QTTrackHeartCell) ?? QTTrackHeartCell()
            cell.configure(liked: config.likedIDs.contains(track.videoId), accent: accent, enabled: true, isCurrent: isCurrent)
            cell.onToggle = { [weak self] in self?.model.player.toggleLike(track) }
            view = cell
        case .time:
            let cell = (tableView.makeView(withIdentifier: cellID, owner: nil) as? QTTrackTextCell)
                ?? QTTrackTextCell(font: QTTrackFonts.time, alignment: .right)
            cell.configure(track.duration > 0 ? QTFormat.duration(track.duration) : "")
            view = cell
        }
        view.identifier = cellID
        view.alphaValue = track.availability.isPlayable ? 1 : 0.42
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection, let t = page?.tableView, let state = config?.state else { return }
        let ids = t.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].videoId : nil }
        state.selection = ids
        model.selectedTrackIDs = Set(ids)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == Column.title.id, rows.indices.contains(row) else { return nil }
        return QTTextFolding.sortKey(rows[row].title)
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?,
                   row: Int, mouseLocation: NSPoint) -> String {
        guard rows.indices.contains(row), !rows[row].availability.isPlayable else { return "" }
        return QTLoc.tr("Not available in your region")
    }

    func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch searchString: String?) -> Bool {
        event.keyCode != 49 // Space is play/pause
    }

    // MARK: Actions

    private func tracks(at indexes: IndexSet) -> [QTTrack] {
        indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard rows.indices.contains(row) else { return }
        play(row: row)
    }

    private func play(row: Int, video: Bool = false) {
        guard let config else { return }
        QTTrackActions.play(rows, at: row, source: config.collection.queueSource, video: video)
    }

    private func returnPressed(option: Bool) {
        guard let t = page?.tableView else { return }
        let selected = t.selectedRowIndexes
        guard let first = selected.first else { return }
        if option {
            QTTrackActions.playNext(tracks(at: selected))
        } else if selected.count == 1 {
            play(row: first)
        } else {
            QTTrackActions.play(tracks(at: selected), at: 0, source: config?.collection.queueSource)
        }
    }

    func jump(to letter: String) {
        guard let page, let sort = config?.state.sort.key,
              let row = rows.firstIndex(where: { indexLetter($0, sort: sort) == letter }) else { return }
        page.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        page.scrollRowToTop(row, animated: true)
        page.window?.makeFirstResponder(page.tableView)
    }

    /// The A–Z strip is a jump aid for long lists only: more than `alphabetMinimumRows` rows, sorted by title (the
    /// letters then follow the visible order). Shorter lists, playlist order, album/time sorts rely on type-to-select
    /// and the column headers, like Finder and Music. Letters are script-aware (`QTTextFolding.indexLetter`: Latin
    /// initial, pinyin initial for Han via ICU, "#" for the rest), so a zh-CN library gets useful jump points.
    static let alphabetMinimumRows = 60

    static func wantsAlphabet(rowCount: Int, sort: QTTrackSort.Key) -> Bool {
        rowCount > alphabetMinimumRows && sort == .title
    }

    /// Index letters present in the rows — cached per row set + sort (ICU transliteration per row is not free, and
    /// `update` runs on every SwiftUI pass).
    private var letterCache: (ids: [String], sort: QTTrackSort.Key, letters: Set<String>)?

    private func availableLetters(_ rows: [QTTrack], sort: QTTrackSort.Key) -> Set<String> {
        let ids = rows.map(\.videoId)
        if let c = letterCache, c.sort == sort, c.ids == ids { return c.letters }
        let letters = Set(rows.map { indexLetter($0, sort: sort) })
        letterCache = (ids, sort, letters)
        return letters
    }

    private func indexLetter(_ t: QTTrack, sort: QTTrackSort.Key) -> String {
        switch sort {
        case .album: QTTextFolding.indexLetter(t.album?.title ?? "")
        case .artist: QTTextFolding.indexLetter(t.artists.first?.name ?? "")
        default: QTTextFolding.indexLetter(t.title)
        }
    }

    // MARK: Context menu (NSMenu, built for the clicked row or the selection it belongs to)

    private var menuTargets: [QTTrack] = []

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let t = page?.tableView else { return }
        let clicked = t.clickedRow
        guard rows.indices.contains(clicked) else { menuTargets = []; return }
        let indexes = t.selectedRowIndexes.contains(clicked) ? t.selectedRowIndexes : IndexSet(integer: clicked)
        menuTargets = tracks(at: indexes)
        let first = rows[clicked]
        let anyPlayable = menuTargets.contains { $0.availability.isPlayable }
        let single = menuTargets.count == 1

        func item(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [], enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            i.isEnabled = enabled
            return i
        }

        menu.addItem(item(QTLoc.tr("Play"), #selector(menuPlay), key: "\r", enabled: first.availability.isPlayable))
        menu.addItem(item(QTLoc.tr("Play Next"), #selector(menuPlayNext), key: "\r", mods: .option, enabled: anyPlayable))
        menu.addItem(item(QTLoc.tr("Add to Queue"), #selector(menuAddToQueue), enabled: anyPlayable))
        menu.addItem(.separator())
        if first.hasVideo {
            menu.addItem(item(QTLoc.tr("Play Music Video"), #selector(menuPlayVideo), key: "v", mods: [.command, .shift],
                              enabled: first.availability.isPlayable))
        } else {
            menu.addItem(item(QTLoc.tr("No Music Video"), nil, enabled: false))
        }
        if let album = first.album?.title, config?.collection.kind != .album {
            menu.addItem(item(QTLoc.tr("Go to Album · %@", album), #selector(menuGoToAlbum), enabled: single))
        }
        if let artist = first.artists.first?.name, config?.collection.title != artist || config?.collection.kind != .artist {
            menu.addItem(item(QTLoc.tr("Go to Artist · %@", artist), #selector(menuGoToArtist), enabled: single))
        }
        menu.addItem(.separator())
        let add = item(QTLoc.tr("Add to Playlist"), nil, enabled: anyPlayable)
        let sub = NSMenu()
        for p in model.catalog.playlists where p.id != config?.collection.playlistID {
            let pi = item(p.title.resolved, #selector(menuAddToPlaylist(_:)))
            pi.representedObject = p.id
            pi.image = NSImage(systemSymbolName: QTIcon.playlist.systemName, accessibilityDescription: nil)
            sub.addItem(pi)
        }
        add.submenu = sub
        add.action = #selector(menuNoop)
        menu.addItem(add)
        let allLiked = menuTargets.allSatisfy { model.player.isLiked($0) }
        menu.addItem(item(QTLoc.tr(allLiked ? "Remove from Liked Songs" : "Like"), #selector(menuToggleLike), key: "l", mods: .command))
        menu.addItem(.separator())
        menu.addItem(item(QTLoc.tr("Copy Link"), #selector(menuCopyLink), key: "c", mods: .command))
    }

    @objc private func menuNoop() {}

    @objc private func menuPlay() {
        guard let t = page?.tableView, rows.indices.contains(t.clickedRow) else { return }
        if menuTargets.count > 1 {
            QTTrackActions.play(menuTargets, at: 0, source: config?.collection.queueSource)
        } else {
            play(row: t.clickedRow)
        }
    }

    @objc private func menuPlayNext() { QTTrackActions.playNext(menuTargets) }
    @objc private func menuAddToQueue() { QTTrackActions.addToQueue(menuTargets) }

    @objc private func menuPlayVideo() {
        guard let t = page?.tableView, rows.indices.contains(t.clickedRow) else { return }
        play(row: t.clickedRow, video: true)
    }

    @objc private func menuGoToAlbum() {
        guard let album = menuTargets.first?.album else { return }
        QTNavigator.shared.go(.album(album))
    }

    @objc private func menuGoToArtist() {
        guard let artist = menuTargets.first?.artists.first else { return }
        QTNavigator.shared.go(.artist(artist))
    }

    @objc private func menuAddToPlaylist(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let p = model.catalog.playlists.first(where: { $0.id == id }) else { return }
        QTTrackActions.add(menuTargets, to: p)
    }

    @objc private func menuToggleLike() { QTTrackActions.toggleLike(menuTargets) }
    @objc private func menuCopyLink() { QTTrackActions.copyLinks(menuTargets) }
}

/// A–Z jump strip (prototype `.az`): available letters are bold; click or drag along it to jump.
struct QTAlphabetStrip: View {
    var available: Set<String>
    var onJump: (String) -> Void
    @State private var lastLetter: String?

    var body: some View {
        let letters = QTTextFolding.indexLetters
        VStack(spacing: 0) {
            ForEach(letters, id: \.self) { l in
                Text(verbatim: l)
                    .font(.system(size: 10, weight: available.contains(l) ? .semibold : .regular))
                    .foregroundStyle(available.contains(l) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: QTTrackTablePageView.alphabetWidth, height: QTTrackTablePageView.alphabetLetterHeight)
                    .accessibilityHidden(!available.contains(l))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onJump(l) }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let i = Int(g.location.y / QTTrackTablePageView.alphabetLetterHeight)
            guard letters.indices.contains(i) else { return }
            let l = letters[i]
            guard l != lastLetter, available.contains(l) else { return }
            lastLetter = l
            onJump(l)
        }.onEnded { _ in lastLetter = nil })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QTLoc.tr("Jump to letter"))
        .accessibilityIdentifier("qt.library.alphabet")
        .help(QTLoc.tr("Jump to letter"))
    }
}
