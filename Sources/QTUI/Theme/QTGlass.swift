import AppKit
import QTCore
import SwiftUI

// Owner: shared (Theme). The app's glass primitives — the ONE place that decides how a floating surface looks:
//
//   macOS 26+                     Liquid Glass (`glassEffect`, `GlassEffectContainer`, `.glass` button styles,
//                                 `NSGlassEffectView` for window-level glass)
//   macOS 15                      system materials (`.regularMaterial`, `.ultraThinMaterial`, `.popover` vibrancy)
//   Reduce Transparency (any OS)  solid surfaces (window background; a deep neutral over artwork)
//
// Native chrome (sidebar, toolbar, search field, popovers, menus, the MenuBarExtra window, segmented pickers)
// gets the system's glass by itself — don't paint over it. Use these only for the app's own floating pieces.
// Never call `glassEffect` / `.material` backgrounds directly in feature code.

/// Where a glass surface sits, which picks its fallbacks (and legibility) — not its shape.
enum QTGlassRole {
    /// Floating chrome over the app's own content (player bar, toasts, lyrics "Current" pill).
    case chrome
    /// Over artwork, MV stills or video (Stage chrome, mini player art mode, art badges). Always a dark context.
    case overArt
    /// A large bar carrying text over arbitrary, often vivid content (the player bar): glass with a neutral wash of
    /// the window colour so titles stay legible over album art scrolling underneath.
    case bar

    fileprivate var fallbackMaterial: Material {
        switch self {
        case .chrome, .bar: .regularMaterial
        case .overArt: .ultraThinMaterial
        }
    }

    fileprivate var solid: Color {
        switch self {
        case .chrome, .bar: QTTheme.Colors.windowBackground
        case .overArt: Color(white: 0.11)
        }
    }

    /// The glass tint when the caller gives none.
    fileprivate var defaultTint: Color? {
        switch self {
        case .bar: QTTheme.Colors.windowBackground.opacity(0.62)
        case .chrome, .overArt: nil
        }
    }
}

extension View {
    /// A floating glass surface behind this view, in `shape`.
    /// - Parameters:
    ///   - tint: optional colour wash (the artwork accent, sparingly — ~0.15–0.25 opacity). Glass only.
    ///   - interactive: the glass reacts to press/hover (for surfaces that are themselves a control).
    func qtGlass<S: Shape>(_ role: QTGlassRole = .chrome, in shape: S, tint: Color? = nil,
                           interactive: Bool = false) -> some View {
        modifier(QTGlassSurface(role: role, shape: shape, tint: tint, interactive: interactive))
    }

    /// Capsule (or circular, `iconOnly`) page button: `.glassProminent` / `.glass` on macOS 26 (the artwork
    /// accent comes from `.tint`), the app's filled capsule (`QTPillButtonStyle`) on macOS 15 and under
    /// Reduce Transparency.
    func qtGlassButton(_ prominence: QTPillProminence = .secondary, iconOnly: Bool = false) -> some View {
        modifier(QTGlassButtonModifier(prominence: prominence, iconOnly: iconOnly))
    }
}

/// Groups neighbouring glass shapes so they blend and morph together (`GlassEffectContainer` on macOS 26;
/// a plain container before).
struct QTGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Implementation

enum QTGlassDebug {
    /// DEBUG `-qt.reduceTransparency YES`: every glass primitive renders its Reduce Transparency fallback, for
    /// screenshots (native chrome still follows the real system setting).
    static let forcesSolid: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "qt.reduceTransparency")
        #else
        false
        #endif
    }()
}

private struct QTGlassSurface<S: Shape>: ViewModifier {
    let role: QTGlassRole
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || QTGlassDebug.forcesSolid {
            content
                .background(role.solid, in: shape)
                .overlay { if contrast == .increased { shape.stroke(.primary.opacity(0.45), lineWidth: 1) } }
        } else if #available(macOS 26, *) {
            content.glassEffect(Glass.regular.tint(contrast == .increased ? role.defaultTint : tint ?? role.defaultTint)
                .interactive(interactive), in: shape)
        } else {
            content
                .background(role.fallbackMaterial, in: shape)
                .overlay { shape.stroke(.primary.opacity(contrast == .increased ? 0.45 : 0.08), lineWidth: 1) }
        }
    }
}

private struct QTGlassButtonModifier: ViewModifier {
    let prominence: QTPillProminence
    let iconOnly: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency, !QTGlassDebug.forcesSolid {
            Group {
                switch prominence {
                case .primary: content.buttonStyle(.glassProminent)
                case .secondary: content.buttonStyle(.glass)
                }
            }
            .buttonBorderShape(iconOnly ? .circle : .capsule)
            .labelStyle(QTGlassButtonLabelStyle(iconOnly: iconOnly))
        } else {
            content.buttonStyle(QTPillButtonStyle(prominence: prominence, iconOnly: iconOnly))
        }
    }
}

/// Icon-only buttons keep their title for VoiceOver; titled ones show icon + title.
private struct QTGlassButtonLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack(spacing: 6) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

// MARK: - Window-level glass (clear, borderless panels)

/// Window-level glass for floating panels (mini player strip, desktop lyrics controls): `NSGlassEffectView` on
/// macOS 26+, behind-window vibrancy before, the solid window colour with Reduce Transparency. (SwiftUI's
/// `glassEffect` can't sample the desktop behind a clear panel, so panels use the AppKit views.)
struct QTPanelGlassBackground: View {
    var cornerRadius: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency || QTGlassDebug.forcesSolid {
            QTTheme.Colors.windowBackground
        } else if #available(macOS 26, *) {
            QTGlassEffectBackground(cornerRadius: cornerRadius)
        } else {
            QTVisualEffectBackground(material: .popover)
        }
    }
}

@available(macOS 26, *)
struct QTGlassEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.cornerRadius = cornerRadius
        return v
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        nsView.cornerRadius = cornerRadius
    }
}

/// Behind-window vibrancy (NSVisualEffectView) as a SwiftUI background — the macOS 15 fallback.
struct QTVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Floating bars

extension View {
    /// A bar floating over the bottom of a scrolling region (the player bar): on macOS 26 a `safeAreaBar`, so the
    /// scroll view draws its edge effect under the glass and content stays legible through it; a plain safe-area
    /// inset before.
    @ViewBuilder
    func qtFloatingBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }
}
