import AppKit
import Testing
@testable import QTUI

@MainActor
@Suite struct QTAboutPanelTests {
    /// About credits name the maker, link r-q.name, the website and the source.
    @Test func creditsLinkTheMakerWebsiteAndSource() {
        let credits = QTAboutPanel.credits()
        #expect(credits.string.contains("Tianrun Qiu"))
        #expect(credits.string.contains("r-q.name"))
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.contains(URL(string: "https://r-q.name")!))
        #expect(links.contains(URL(string: "https://qtube.r-q.name")!))
        #expect(links.contains(URL(string: "https://github.com/RoderickQiu/qtube-music")!))
    }
}
