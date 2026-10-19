import Foundation
import QTCore
import Testing
@testable import QTLyrics

@Suite struct MockProviderTests {
    @Test func servesDocumentsByVideoId() async throws {
        let doc = QTLyricsDocument(lines: [QTLyricsLine(start: 1, text: "x")], syncKind: .line, source: .lrclib)
        let p = QTMockLyricsProvider(documents: ["v": doc])
        let t = QTTrack(videoId: "v", title: "T", artists: [], duration: 10)
        #expect(try await p.lyrics(for: t) == doc)
        var other = t
        other.videoId = "w"
        #expect(try await p.lyrics(for: other) == nil)
    }

    @Test func fixturesFolderIsBundled() {
        #expect(Bundle.module.url(forResource: "Fixtures", withExtension: nil) != nil)
    }
}
