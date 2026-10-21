import Foundation

/// The user agent the app presents to Google and YouTube: Safari's, with the version of the Safari installed on this
/// Mac. Google's sign-in turns away embedded browsers that don't look like a current Safari ("This browser or app may
/// not be secure"), so a hard-coded version goes stale with every macOS release. Everything but `Version/x` is what
/// every Safari sends today: `Intel Mac OS X 10_15_7` and `605.1.15` are frozen, on Apple silicon too.
public enum QTSafariUserAgent {
    /// WebKit's frozen engine token.
    static let webKitToken = "605.1.15"
    static let platformPrefix = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
    /// When neither Safari's Info.plist nor the OS version says better: macOS 15 ships Safari 18.
    public static let fallbackVersion = "18.0"
    /// Where Safari lives (a link into the Safari cryptex since macOS 13).
    public static let safariInfoPlist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")

    /// `Version/26.0 Safari/605.1.15`: a `WKWebViewConfiguration.applicationNameForUserAgent` that makes a web view's
    /// own user agent Safari's.
    public static func applicationName(version: String) -> String {
        "Version/\(version) Safari/\(webKitToken)"
    }

    /// The full user agent for URLSession requests (the API client, stream requests).
    public static func userAgent(version: String) -> String {
        "\(platformPrefix) \(applicationName(version: version))"
    }

    /// Safari's `CFBundleShortVersionString` when it's a plain `major.minor[.patch]` (Safari 13 or later); nil for
    /// anything else, so a damaged or unexpected plist can't put junk into the user agent.
    static func version(fromInfo info: [String: Any]?) -> String? {
        guard let raw = info?["CFBundleShortVersionString"] as? String else { return nil }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCIIDigit) }),
              let major = Int(parts[0]), (13...99).contains(major) else { return nil }
        return parts.count == 1 ? "\(major).0" : parts.joined(separator: ".")
    }

    /// The Safari a macOS version ships when Safari's plist can't be read: macOS 26 and later share Safari's number.
    static func version(forOSMajor major: Int) -> String {
        major >= 26 ? "\(major).0" : fallbackVersion
    }

    /// The installed Safari's version, else the one the OS ships, else `fallbackVersion`.
    public static func installedVersion(infoPlist: URL = safariInfoPlist,
                                        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        let info = NSDictionary(contentsOf: infoPlist) as? [String: Any]
        return version(fromInfo: info) ?? version(forOSMajor: osVersion.majorVersion)
    }

    /// This Mac's Safari version, read once per process.
    public static let current: String = installedVersion()
}
