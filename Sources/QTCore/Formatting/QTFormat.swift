import Foundation

/// Locale-aware formatting. Always formats in the *interface* language (`QTLoc.locale`), never hand-built strings.
public enum QTFormat {
    /// "4:17", "1:02:05" — track positions and durations.
    public static func duration(_ seconds: TimeInterval, locale: Locale = QTLoc.locale) -> String {
        let s = max(0, seconds.isFinite ? seconds.rounded(.down) : 0)
        let pattern: Duration.TimeFormatStyle.Pattern = s >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(s).formatted(.time(pattern: pattern).locale(locale))
    }

    /// "-3:42" — remaining time on scrubbers.
    public static func remaining(_ seconds: TimeInterval, locale: Locale = QTLoc.locale) -> String {
        "-" + duration(seconds, locale: locale)
    }

    /// Whole minutes for "12 songs · 50 min".
    public static func totalMinutes(_ seconds: TimeInterval) -> Int {
        Int((seconds / 60).rounded())
    }

    /// "12 songs · 50 min" / "12 首 · 50 分钟" via the catalog's plural variations.
    public static func songCountAndMinutes(count: Int, seconds: TimeInterval) -> String {
        QTLoc.tr("%lld songs · %lld min", count, totalMinutes(seconds))
    }

    /// Lyrics offset "+0.1 s"-style number: "+0.1", "-0.3", "0.0".
    public static func signedOffset(_ seconds: TimeInterval, locale: Locale = QTLoc.locale) -> String {
        let v = (seconds * 10).rounded() / 10
        return v.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false)).locale(locale))
    }

    /// Menu-bar style clock: "Sun 18 Oct 9:41" / "10月18日 周日 9:41".
    public static func clock(_ date: Date, locale: Locale = QTLoc.locale) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
