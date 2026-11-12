import AppKit
import QTCore
import SwiftUI

/// The docked panel (Now Playing / Queue) beside the content column, inside the split view's detail column.
///
/// Why not SwiftUI's `.inspector`: showing or hiding an inspector makes SwiftUI rebuild the window toolbar (every
/// item fades out and back in, the sidebar button drops into the overflow menu for a moment) and re-lay out the
/// whole split view. On macOS 26 that pass laid the split view out wider than the window for a few frames, so the
/// sidebar slid off the window's left edge and back each time the panel opened or closed (GitHub #1). The same
/// happens with a stock NavigationSplitView + inspector and no app code at all. Here the panel is part of the detail
/// column's own layout: the split view (sidebar | detail) and the toolbar never change when it comes or goes.
///
/// Two things make macOS 27 dim or flash the toolbar's glass buttons for about 0.2 s (a stock NavigationSplitView
/// does both too; measured per frame on screen recordings, see docs/architecture.md):
/// - An AppKit-backed view (a List, a table) added to the window, removed from it, or changing frame beside the
///   toolbar. So the panel is always mounted, at a fixed frame at the detail column's trailing edge; hiding it only
///   makes it invisible (opacity 0, no hit testing, hidden from accessibility) and gives its width back to the
///   content. No slide for the same reason.
/// - A SwiftUI ScrollView that extends under the toolbar re-laying out its content, which every scrolling page does
///   when the panel takes or returns its width. So the content starts 1 pt below the toolbar: pages no longer scroll
///   under it, and resizing them leaves the toolbar alone. (Scroll-edge effect styles make no difference.)
///
/// Only this view and `QTPanelToggleButton` read `isPanelShown`. Were the window's root view to read it, every toggle
/// would re-render the whole NavigationSplitView, sidebar included, and on macOS 27 the glass sidebar button over the
/// sidebar list flickers whenever that list updates under it.
struct QTDockedPanel<Content: View, Panel: View>: View {
    @Environment(QTAppModel.self) private var model
    @Environment(\.qtPausesTimeDrivenViews) private var pausesTimeDrivenViews
    /// Save the width the user drags to (off for dev / screenshot launches, which always use the design width).
    let persists: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var panel: Panel

    @State private var width: CGFloat
    @State private var dragStartWidth: CGFloat?
    @State private var available: CGFloat = 0

    init(persists: Bool, @ViewBuilder content: () -> Content, @ViewBuilder panel: () -> Panel) {
        self.persists = persists
        self.content = content()
        self.panel = panel()
        _width = State(initialValue: QTDockedPanelWidth.clamped(persists ? UserDefaults.standard.double(forKey: QTDockedPanelWidth.defaultsKey) : 0))
    }

    var body: some View {
        let panelWidth = QTDockedPanelWidth.fitted(width, in: available)
        let shown = model.isPanelShown
        ZStack(alignment: .trailing) {
            content
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, shown ? panelWidth : 0)
                // Pages start 1 pt below the toolbar instead of scrolling under it (see above).
                .padding(.top, 1)
            panel
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) { edge }
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
                // Lyrics and the scrubber clock don't redraw while nobody can see them.
                .environment(\.qtPausesTimeDrivenViews, pausesTimeDrivenViews || !shown)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    /// The panel's leading edge: a hairline, and a strip to drag the panel wider or narrower.
    private var edge: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .leading))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStartWidth ?? QTDockedPanelWidth.fitted(width, in: available)
                                dragStartWidth = start
                                width = QTDockedPanelWidth.clamped(Double(start - drag.translation.width))
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                                if persists { UserDefaults.standard.set(Double(width), forKey: QTDockedPanelWidth.defaultsKey) }
                            }
                    )
                    .accessibilityHidden(true)
            }
    }
}

/// Show / Hide Panel, at the toolbar's trailing edge whether the panel is open or not (adding or removing toolbar
/// items as the panel comes and goes makes SwiftUI rebuild the whole toolbar: every item fades out and back in).
struct QTPanelToggleButton: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let title = QTLoc.tr(model.isPanelShown ? "Hide Panel" : "Show Panel", table: .desktop)
        Button {
            model.setPanelShown(!model.isPanelShown)
        } label: {
            Label(title, systemImage: QTIcon.sidebar.systemName)
        }
        .help("\(title)  ⌥⌘N")
        .accessibilityIdentifier("qt.window.panelToggle")
    }
}

enum QTDockedPanelWidth {
    /// The width the user last dragged the panel to (UserDefaults).
    static let defaultsKey = "qt.window.panelWidth"
    /// What the content column always keeps beside the panel, unless that would push the panel under its minimum.
    static let contentMinWidth: CGFloat = 320

    /// 0 / missing → the design width; anything else within the panel's min…max.
    static func clamped(_ stored: Double) -> CGFloat {
        guard stored > 0 else { return QTTheme.Metrics.panelWidth }
        return min(max(CGFloat(stored), QTTheme.Metrics.panelMinWidth), QTTheme.Metrics.panelMaxWidth)
    }

    /// The panel's width in a detail column `available` points wide: the user's width, narrowed in a small window so
    /// the content keeps `contentMinWidth`, never below the panel's minimum.
    static func fitted(_ width: CGFloat, in available: CGFloat) -> CGFloat {
        guard available > 0 else { return width }
        return min(width, max(QTTheme.Metrics.panelMinWidth, available - contentMinWidth))
    }
}

extension QTAppModel {
    /// Shows or hides the docked panel (optionally on `tab`), at once (see QTDockedPanel for why it doesn't slide).
    func setPanelShown(_ shown: Bool, tab: QTPanelTab? = nil) {
        if let tab { panelTab = tab }
        guard shown != isPanelShown else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPanelShown = shown }
    }
}
