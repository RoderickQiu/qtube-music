import Foundation
import Testing
@testable import QTCore

@Suite struct QueueTests {
    let tracks = (1...5).map { Fixture.track("t\($0)") }

    @Test func playingAContextFillsAutoplayAndSkipsUnplayable() {
        var q = QTQueue()
        var list = tracks
        list[3] = Fixture.track("locked", playable: false)
        q.play(list, startingAt: 1, source: QTQueueSource(kind: .playlist, id: "LM", title: .localized("Liked Songs")))
        #expect(q.nowPlaying?.track.videoId == "t2")
        #expect(q.autoplay.map(\.track.videoId) == ["t3", "t5"])
        #expect(q.autoplaySource?.id == "LM")
    }

    @Test func upNextBeatsAutoplayAndHistoryAllowsGoingBack() {
        var q = QTQueue()
        q.play(tracks, startingAt: 0)
        q.addToQueue([Fixture.track("x")])
        q.playNext([Fixture.track("y")])
        #expect(q.upNext.map(\.track.videoId) == ["y", "x"])
        #expect(q.advance()?.track.videoId == "y")
        #expect(q.advance()?.track.videoId == "x")
        #expect(q.advance()?.track.videoId == "t2")
        #expect(q.history.map(\.track.videoId) == ["t1", "y", "x"])
        #expect(q.goBack()?.track.videoId == "x")
        #expect(q.upNext.first?.track.videoId == "t2")
    }

    @Test func autoplayCanBeTurnedOff() {
        var q = QTQueue()
        q.play(tracks, startingAt: 0)
        q.isAutoplayEnabled = false
        #expect(q.nextItem == nil)
        #expect(q.advance() == nil)
        #expect(q.nowPlaying?.track.videoId == "t1")
    }

    @Test func moveInsertRemove() {
        var q = QTQueue()
        q.addToQueue(tracks)
        q.move(fromOffsets: IndexSet([0]), toOffset: 3, in: .upNext)
        #expect(q.upNext.map(\.track.videoId) == ["t2", "t3", "t1", "t4", "t5"])
        q.move(fromOffsets: IndexSet([4]), toOffset: 0, in: .upNext)
        #expect(q.upNext.map(\.track.videoId) == ["t5", "t2", "t3", "t1", "t4"])
        q.insert([Fixture.track("z")], at: 99, in: .upNext)
        #expect(q.upNext.last?.track.videoId == "z")
        q.remove(ids: [q.upNext[0].id, q.upNext[1].id])
        #expect(q.upNext.map(\.track.videoId) == ["t3", "t1", "t4", "z"])
    }

    @Test func moveBetweenSections() {
        var q = QTQueue()
        q.play(tracks, startingAt: 0)
        let item = q.autoplay[2]
        q.move(itemID: item.id, to: .upNext, at: 0)
        #expect(q.upNext == [item])
        #expect(!q.autoplay.contains(item))
    }

    @Test func clearUpNextIsUndoable() {
        var q = QTQueue()
        q.addToQueue(Array(tracks.prefix(3)))
        let token = q.clearUpNext()
        #expect(q.upNext.isEmpty)
        q.addToQueue([Fixture.track("new")])
        q.undoClearUpNext(token)
        #expect(q.upNext.map(\.track.videoId) == ["t1", "t2", "t3", "new"])
        q.undoClearUpNext(token) // idempotent
        #expect(q.upNext.count == 4)
    }

    @Test func duplicatesHaveDistinctIDsAndQueueIsCodable() throws {
        var q = QTQueue()
        q.play(tracks, startingAt: 0, source: QTQueueSource(kind: .album, id: "a", title: .verbatim("A")))
        q.addToQueue([tracks[0], tracks[0]])
        #expect(Set(q.upNext.map(\.id)).count == 2)
        _ = q.advance()
        let back = try JSONDecoder().decode(QTQueue.self, from: JSONEncoder().encode(q))
        #expect(back == q)
    }
}
