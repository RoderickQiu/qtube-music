import Foundation
import QTCore

/// Turns what YouTube's player reports into a `QTPlaybackError` the queue and UI understand.
///
/// Two sources: the player's `onError` codes (IFrame API numbering), and the item's
/// `playabilityStatus` (`status` + human `reason`, in the page's language) for cases that never raise `onError`
/// — age gates, region locks, removed or private videos.
enum QTWebPlaybackErrorMapper {
    static func error(code: Int, status: String, reason: String, ageGate: Bool = false) -> QTPlaybackError {
        if ageGate { return .ageRestricted }
        switch status {
        case "":
            break
        case "AGE_CHECK_REQUIRED", "AGE_VERIFICATION_REQUIRED", "CONTENT_CHECK_REQUIRED":
            return .ageRestricted
        case "LOGIN_REQUIRED":
            // Private videos and age gates both say LOGIN_REQUIRED; the age flag (above) separates them.
            return reason.range(of: "age", options: .caseInsensitive) != nil ? .ageRestricted : .unavailable(.removed)
        case "UNPLAYABLE":
            if reason.range(of: "country", options: .caseInsensitive) != nil || reason.contains("国家") || reason.contains("地区") {
                return .unavailable(.regionLocked)
            }
            if reason.range(of: "premium", options: .caseInsensitive) != nil { return .unavailable(.premiumOnly) }
            return .unavailable(.removed)
        case "ERROR", "LIVE_STREAM_OFFLINE":
            return .unavailable(.removed)
        default:
            return .engine("playability \(status)")
        }
        switch code {
        // 2 invalid id · 100 not found / private · 101, 150, 152 owner disallows playback here
        case 2, 100, 101, 150, 152: return .unavailable(.removed)
        default: return .engine("player error \(code)")
        }
    }
}
