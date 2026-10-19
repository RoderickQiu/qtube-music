import Foundation
import QTCore
import QTPlayback

extension QTAdState {
    /// The ad's media has run out but the page hasn't handed back yet (between ads of a pod, content loading).
    /// Shown as plain "Ad" — never "Ad · 0:00", which reads as stuck.
    var qtIsHandingBack: Bool { remaining <= 0.05 }

    /// Remaining time for the countdown ("0:11"), nil while handing back.
    var qtRemainingText: String? {
        qtIsHandingBack ? nil : QTFormat.duration(remaining.rounded(.up))
    }

    /// "Ad · 0:11", or "Ad" while handing back.
    func qtBadgeText(onStage: Bool) -> String {
        guard let remaining = qtRemainingText else { return QTLoc.tr("Ad") }
        return onStage ? QTLoc.tr("Ad · %@", table: .stage, remaining) : QTLoc.tr("Ad · %@", table: .player, remaining)
    }
}
