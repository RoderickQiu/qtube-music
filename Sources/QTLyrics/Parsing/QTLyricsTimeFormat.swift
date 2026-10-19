import Foundation

/// Clock-string parsing shared by the LRC and TTML parsers.
enum QTLyricsTimeFormat {
    /// Parses `mm:ss`, `mm:ss.xx`, `h:mm:ss.fff`, `ss.fff`, `12.5s`, `1500ms`.
    /// With `lrcLegacy`, three colon-separated parts without a dot mean `mm:ss:xx` (centiseconds), as some
    /// old LRC files write them; TTML reads the same shape as `hh:mm:ss`.
    static func seconds(_ raw: Substring, lrcLegacy: Bool = false) -> TimeInterval? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("ms") { return Double(s.dropLast(2)).map { $0 / 1000 } }
        if s.hasSuffix("s"), !s.contains(":") { return Double(s.dropLast()) }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.map { Double($0) }
        guard !numbers.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        let n = numbers.map { $0! }
        switch n.count {
        case 1: return n[0]
        case 2: return n[0] * 60 + n[1]
        case 3:
            if lrcLegacy, !parts[2].contains("."), !parts[1].contains(".") {
                return n[0] * 60 + n[1] + n[2] / pow(10, Double(parts[2].count))
            }
            return n[0] * 3600 + n[1] * 60 + n[2]
        default: return nil
        }
    }

    static func seconds(_ raw: String, lrcLegacy: Bool = false) -> TimeInterval? {
        seconds(Substring(raw), lrcLegacy: lrcLegacy)
    }

    /// Milliseconds string (`"35695"`) to seconds.
    static func milliseconds(_ raw: Substring) -> TimeInterval? {
        Double(raw.trimmingCharacters(in: .whitespaces)).map { $0 / 1000 }
    }
}
