import QTCore
import QTPlayback
import SwiftUI

/// The calm ad state in the art slot: the song's own art, blurred and dimmed, with an "Ad · 0:11" pill and Skip
/// once YouTube allows it. No explanatory copy — the countdown says everything.
struct QTStageAdCard: View {
    let track: QTTrack?
    let size: CGFloat
    @Environment(QTPlayerModel.self) private var player

    var body: some View {
        ZStack {
            QTStageProcessedImage(images: track?.artwork ?? [], look: .adCard) { image in
                QTStageLayerImage(image: image, overscan: 20, crossfade: 0)
            }
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                if let ad = player.ad {
                    content(ad)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: QTTheme.Radius.artworkLarge, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.stage.adCard")
    }

    @ViewBuilder
    private func content(_ ad: QTAdState) -> some View {
        let remaining = player.engine.state.ad?.remaining ?? ad.remaining
        VStack(spacing: QTTheme.Spacing.s) {
            Text(QTLoc.tr("Ad · %@", table: .stage, QTFormat.duration(remaining.rounded(.up))))
                .font(QTTheme.Typography.secondary.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, QTTheme.Spacing.s)
                .frame(height: 26)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("qt.stage.adCountdown")
            if ad.canSkip {
                Button(QTLoc.tr("Skip")) { player.skipAd() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityIdentifier("qt.stage.adSkip")
            } else if let wait = ad.skippableIn {
                Text(QTLoc.tr("Skip in %lld", Int(wait.rounded(.up))))
                    .font(QTTheme.Typography.secondary)
                    .monospacedDigit()
                    .foregroundStyle(QTTheme.Colors.onArtSecondary)
            }
        }
        .foregroundStyle(QTTheme.Colors.onArt)
    }
}
