import QTCore
import SwiftUI

// Owner: builder "window". On macOS 26 pages use system glass buttons through `qtGlassButton` (Theme/QTGlass.swift);
// these filled capsules are its macOS 15 / Reduce Transparency fallback. Capsule controls for content pages (Home mood chips, Play / Shuffle / More on
// collection headers, Explore destinations). macOS's bordered styles ignore `.buttonBorderShape(.capsule)` and
// render grey when the window is inactive, which flattens the one primary action on a page. These styles are
// built from system fills (`.fill.tertiary` / `.fill.secondary`), the artwork accent as a tint, semantic label
// colours, and keep the system's press, hover, disabled and keyboard-focus behaviour.

/// How prominent a capsule control is.
enum QTPillProminence {
    /// Filled with the artwork accent, white label — the page's primary action (Play).
    case primary
    /// Subtle system fill, primary label — secondary actions (Shuffle, More), unselected chips.
    case secondary
}

/// Capsule button: `.primary` (accent fill) or `.secondary` (system fill). `iconOnly` makes it a circle.
struct QTPillButtonStyle: ButtonStyle {
    var prominence: QTPillProminence = .secondary
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        QTPillBody(label: configuration.label, isPressed: configuration.isPressed, prominence: prominence,
                   isOn: false, iconOnly: iconOnly)
    }
}

/// Mood / genre chip: a roomy capsule toggle. On = accent fill with a white label (`.glassProminent` on macOS 26,
/// `.glass` when off — see `qtGlassButton`).
struct QTChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .qtGlassButton(configuration.isOn ? .primary : .secondary)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

/// Shared body: sizes follow `controlSize` (regular 28 pt, large 32 pt, like system push buttons).
private struct QTPillBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let prominence: QTPillProminence
    let isOn: Bool
    let iconOnly: Bool
    @Environment(QTAppModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var height: CGFloat {
        switch controlSize {
        case .mini, .small: 24
        case .regular: 28
        default: 32
        }
    }

    var body: some View {
        // White label on the accent needs the deeper (light-appearance) variant in both appearances.
        let accent = QTTheme.Colors.accent(model.palette, scheme: .light, increaseContrast: contrast == .increased)
        label
            .font(controlSize == .large ? .body.weight(.medium) : .callout.weight(.medium))
            .labelStyle(QTPillLabelStyle(iconOnly: iconOnly))
            .lineLimit(1)
            .foregroundStyle(prominence == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, iconOnly ? 0 : (controlSize == .large ? 16 : 12))
            .frame(minWidth: iconOnly ? height : nil, minHeight: height)
            .background {
                Capsule(style: .continuous).fill(fill(accent: accent))
            }
            .overlay {
                // Pressed: darken like a system push button.
                Capsule(style: .continuous).fill(.black.opacity(isPressed ? (prominence == .primary ? 0.18 : 0.08) : 0))
            }
            .overlay {
                if contrast == .increased {
                    Capsule(style: .continuous).strokeBorder(.primary.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18), reduceMotion: reduceMotion), value: isPressed)
            .animation(QTTheme.Motion.animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.18), reduceMotion: reduceMotion), value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }

    private func fill(accent: Color) -> AnyShapeStyle {
        switch prominence {
        case .primary:
            AnyShapeStyle(isHovered ? accent.mix(with: .white, by: 0.08) : accent)
        case .secondary:
            isHovered ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary)
        }
    }
}

/// Icon + title with the system's spacing; icon-only keeps the title for VoiceOver.
private struct QTPillLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
                .imageScale(.medium)
        } else {
            HStack(spacing: 6) {
                configuration.icon
                    .imageScale(.small)
                configuration.title
            }
        }
    }
}

/// Wrapping row for chips (CSS `flex-wrap`): lays children left to right, wrapping to a new line when full.
struct QTChipFlow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, s) in subviews.enumerated() {
            let size = s.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(i)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
