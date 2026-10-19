import Foundation
@testable import QTCore

enum Fixture {
    static func track(_ id: String, duration: TimeInterval = 180, playable: Bool = true) -> QTTrack {
        QTTrack(videoId: id, title: "Title \(id)", artists: [QTArtistRef(name: "Artist")], duration: duration,
                availability: playable ? .playable : .regionLocked)
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
