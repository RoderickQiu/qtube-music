import QTCore
import SwiftUI

/// The Queue drawer that slides in from the right without leaving the Stage, and closes from its own header.
/// Floating glass (Liquid Glass on macOS 26, dark material before, solid with Reduce Transparency).
struct QTStageQueueDrawer: View {
    let onClose: () -> Void
    @Environment(\.qtAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(QTLoc.tr("Queue"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: onClose) {
                    Label(QTLoc.tr("Close queue"), systemImage: QTIcon.close.systemName)
                }
                .buttonStyle(QTStageChromeButtonStyle(glyph: 12))
                .help(QTLoc.tr("Close queue"))
                .accessibilityIdentifier("qt.stage.queueDrawer.close")
            }
            .padding(.leading, 20)
            .padding(.trailing, 10)
            .frame(height: 52)
            Divider()
            QTQueueList(style: .stageDrawer)
        }
        .frame(width: QTTheme.Metrics.stageQueueWidth)
        .qtGlass(.overArt, in: RoundedRectangle(cornerRadius: QTTheme.Radius.drawer, style: .continuous), tint: accent.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: QTTheme.Radius.drawer, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(QTLoc.tr("Queue"))
        .accessibilityIdentifier("qt.stage.queueDrawer")
    }
}
