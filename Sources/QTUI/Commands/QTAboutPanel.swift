import AppKit
import QTCore

/// The standard About panel, with credits: who made the app (linked to r-q.name), the website and the source, and
/// the same "unofficial" line as the website's footer.
@MainActor
enum QTAboutPanel {
    static let authorName = "Tianrun Qiu"
    static let authorURL = URL(string: "https://r-q.name")!
    static let websiteURL = URL(string: "https://qtube.r-q.name")!
    static let sourceURL = URL(string: "https://github.com/RoderickQiu/qtube-music")!

    /// The bundle's name, so variants read "About QTube Music mine".
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "QTube Music"
    }

    static func show() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    /// "Made by Tianrun Qiu" / "r-q.name · qtube.r-q.name · GitHub" / the unofficial line, centred.
    static func credits() -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ]
        let note: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ]
        func link(_ text: String, _ url: URL) -> NSAttributedString {
            var attributes = body
            attributes[.link] = url
            return NSAttributedString(string: text, attributes: attributes)
        }

        let out = NSMutableAttributedString()
        // "Made by %@": the name is the link, wherever the translation puts it.
        let made = QTLoc.tr("Made by %@", table: .desktop, authorName)
        if let range = made.range(of: authorName) {
            out.append(NSAttributedString(string: String(made[..<range.lowerBound]), attributes: body))
            out.append(link(authorName, authorURL))
            out.append(NSAttributedString(string: String(made[range.upperBound...]), attributes: body))
        } else {
            out.append(NSAttributedString(string: made, attributes: body))
        }
        out.append(NSAttributedString(string: "\n", attributes: body))
        out.append(link("r-q.name", authorURL))
        out.append(NSAttributedString(string: " · ", attributes: body))
        out.append(link("qtube.r-q.name", websiteURL))
        out.append(NSAttributedString(string: " · ", attributes: body))
        out.append(link("GitHub", sourceURL))
        out.append(NSAttributedString(string: "\n", attributes: body))
        out.append(NSAttributedString(
            string: QTLoc.tr("Unofficial, not made or endorsed by Google or YouTube. Open source under MPL-2.0.",
                             table: .desktop),
            attributes: note))
        return out
    }
}
