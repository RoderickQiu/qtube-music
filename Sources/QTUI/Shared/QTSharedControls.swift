import QTCore
import SwiftUI

/// Song | Video segmented switch (draft §5). Disabled with an explanatory tooltip when there's no linked video.
/// Final signature — shared by the docked panel and the Stage.
public struct QTSongVideoToggle: View {
    @Binding private var isVideo: Bool
    private let hasVideo: Bool

    public init(isVideo: Binding<Bool>, hasVideo: Bool) {
        _isVideo = isVideo
        self.hasVideo = hasVideo
    }

    public var body: some View {
        // On macOS 26 the segmented control sends its action on every frame while the thumb slides (one click
        // logged ~18 actions); only a real change may reach the binding, or each one re-asks for a switch.
        Picker(selection: Binding(get: { isVideo && hasVideo }, set: { if $0 != (isVideo && hasVideo) { isVideo = $0 } })) {
            Text(QTLoc.tr("Song")).tag(false)
            Text(QTLoc.tr("Video")).tag(true)
        } label: {
            Text(QTLoc.tr("Song ⇄ Music Video"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!hasVideo)
        .help(hasVideo ? "\(QTLoc.tr("Song ⇄ Music Video"))  ⇧⌘V" : QTLoc.tr("No official music video for this song"))
        .accessibilityIdentifier("qt.songVideoToggle")
    }
}

/// HUD toast at the top of the main window ("Added to Up Next" · Undo).
public struct QTToastOverlay: View {
    @Environment(QTAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: QTTheme.Spacing.s) {
                    Text(toast.message)
                        .font(QTTheme.Typography.secondary)
                    if let undo = toast.undo {
                        Button(QTLoc.tr("Undo")) {
                            undo()
                            model.dismissToast()
                        }
                        .buttonStyle(.link)
                        .font(QTTheme.Typography.secondary.weight(.semibold))
                    }
                }
                .padding(.horizontal, QTTheme.Spacing.m)
                .padding(.vertical, QTTheme.Spacing.xs)
                .qtGlass(.chrome, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .id(toast.id)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(.top, QTTheme.Spacing.s)
        .animation(QTTheme.Motion.animation(QTTheme.Motion.ui, reduceMotion: reduceMotion), value: model.toast?.id)
    }
}
