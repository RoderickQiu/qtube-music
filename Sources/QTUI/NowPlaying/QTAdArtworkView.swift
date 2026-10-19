import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "player". Free accounts: YouTube's ad plays; we show the song's own art, blurred and dimmed,
// with a quiet "Ad · 0:11" countdown (draft §11). Reusable by the Stage (large, with Skip) and the panel (compact).

/// The calm ad state drawn over the upcoming song's artwork.
public struct QTAdArtworkView: View {
    private let track: QTTrack?
    private let showsSkip: Bool
    private let cornerRadius: CGFloat
    @Environment(QTPlayerModel.self) private var player

    /// - Parameters:
    ///   - showsSkip: large sizes (Stage) show Skip / "Skip in 4" under the countdown; compact sizes only the pill.
    public init(track: QTTrack?, showsSkip: Bool = false, cornerRadius: CGFloat = QTTheme.Radius.artwork) {
        self.track = track
        self.showsSkip = showsSkip
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: player.isPlaying ? 0.5 : 3600)) { _ in
            ZStack {
                QTArtworkView(track: track, cornerRadius: 0)
                    .scaleEffect(1.25)
                    .blur(radius: showsSkip ? 24 : 8)
                    .brightness(-0.38)
                    .saturation(1.2)
                    .accessibilityHidden(true)
                if let ad = player.ad {
                    VStack(spacing: showsSkip ? QTTheme.Spacing.s : 0) {
                        QTAdCountdownPill(ad: ad, compact: !showsSkip)
                        if showsSkip {
                            QTAdSkipControl(ad: ad, overArt: true)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("qt.player.ad.artwork")
    }
}

/// "Ad · 0:11" in a small vibrant capsule (tabular figures).
public struct QTAdCountdownPill: View {
    private let ad: QTAdState
    private let compact: Bool

    public init(ad: QTAdState, compact: Bool = false) {
        self.ad = ad
        self.compact = compact
    }

    public var body: some View {
        Text(QTLoc.tr("Ad · %@", table: .player, QTFormat.duration(ad.remaining.rounded(.up))))
            .font(compact ? .caption2.weight(.semibold) : .callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 7 : 12)
            .padding(.vertical, compact ? 3 : 5)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .fixedSize()
            .accessibilityIdentifier("qt.player.ad.countdown")
    }
}
