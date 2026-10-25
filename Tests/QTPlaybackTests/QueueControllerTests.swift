import Foundation
import QTCore
import Testing
@testable import QTPlayback

@MainActor
@Suite struct QueueControllerTests {
    let liked = QTQueueSource(kind: .playlist, id: "LM", title: .localized("Liked Songs"))

    // MARK: Starting and editing

    @Test func playingAContextQueuesTheRestAsAutoplayAndSkipsUnplayable() async {
        let rig = Rig()
        var list = PB.tracks(5)
        list[3] = PB.track("locked", playable: false)
        await rig.controller.play(list, startingAt: 1, source: liked)
        #expect(rig.nowID == "t2")
        #expect(rig.autoplayIDs == ["t3", "t5"])
        #expect(rig.controller.queue.autoplaySource?.id == "LM")
        #expect(rig.engine.state.item?.track.videoId == "t2")
        #expect(rig.engine.state.status == .playing)

        await rig.controller.play(list, startingAt: 3)
        #expect(rig.nowID == "t2", "an unplayable start is ignored")
    }

    @Test func upNextPlaysBeforeAutoplayInUserOrder() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(3))
        rig.controller.addToQueue([PB.track("x")])
        rig.controller.playNext([PB.track("y")])
        rig.controller.addToQueue([PB.track("nope", playable: false)])
        #expect(rig.upNextIDs == ["y", "x"])
        await rig.controller.next()
        #expect(rig.nowID == "y")
        await rig.controller.next()
        #expect(rig.nowID == "x")
        await rig.controller.next()
        #expect(rig.nowID == "t2")
        #expect(rig.historyIDs == ["t1", "y", "x"])
    }

    @Test func editsMoveRemoveAndClearWithUndo() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(5))
        rig.controller.addToQueue([PB.track("a"), PB.track("b"), PB.track("c")])
        rig.controller.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, in: .upNext)
        #expect(rig.upNextIDs == ["c", "a", "b"])
        let t4 = rig.controller.queue.autoplay[2]
        rig.controller.move(itemID: t4.id, to: .upNext, at: 1)
        #expect(rig.upNextIDs == ["c", "t4", "a", "b"])
        #expect(rig.autoplayIDs == ["t2", "t3", "t5"])
        rig.controller.remove([rig.controller.queue.upNext[0].id, rig.controller.queue.autoplay[0].id])
        #expect(rig.upNextIDs == ["t4", "a", "b"])
        #expect(rig.autoplayIDs == ["t3", "t5"])
        let token = rig.controller.clearUpNext()
        #expect(rig.upNextIDs.isEmpty)
        rig.controller.addToQueue([PB.track("d")])
        rig.controller.undoClearUpNext(token)
        #expect(rig.upNextIDs == ["t4", "a", "b", "d"])
    }

    @Test func jumpingIntoAutoplayKeepsUpNext() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(5))
        rig.controller.addToQueue([PB.track("u")])
        await rig.controller.jump(to: rig.controller.queue.autoplay[2])
        #expect(rig.nowID == "t4")
        #expect(rig.autoplayIDs == ["t5"])
        #expect(rig.upNextIDs == ["u"])
        await rig.controller.jump(to: rig.controller.queue.upNext[0])
        #expect(rig.nowID == "u")
        #expect(rig.upNextIDs.isEmpty)
    }

    // MARK: Advancing

    @Test func naturalEndAdvancesThroughTheWholeQueueWithoutStalling() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(10))
        for i in 2...10 {
            await rig.finishTrack()
            #expect(rig.nowID == "t\(i)")
            #expect(rig.engine.state.status == .playing)
        }
        await rig.finishTrack()
        #expect(rig.nowID == "t10", "end of queue stays on the last item")
        #expect(rig.engine.state.status == .ended)
        #expect(rig.historyIDs.count == 9)
    }

    @Test func repeatOneReplaysOnEndButNextMovesOn() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(3))
        rig.controller.repeatMode = .one
        await rig.finishTrack()
        #expect(rig.nowID == "t1")
        #expect(rig.engine.state.status == .playing)
        #expect(rig.engine.state.timeline.time(atUptime: rig.clock.now) < 1)
        #expect(rig.historyIDs.isEmpty)
        await rig.controller.next()
        #expect(rig.nowID == "t2")
    }

    /// Scrobblers key a listen on (video id, playSerial): Repeat One and replays start a new listen, a Song⇄Video
    /// switch of the same track doesn't.
    @Test func playSerialCountsListensNotReloads() async {
        let rig = Rig()
        var list = PB.tracks(3)
        list[0].counterpart = QTCounterpart(videoId: "v1", musicVideoType: .omv)
        await rig.controller.play(list)
        let first = rig.controller.playSerial
        rig.controller.repeatMode = .one
        await rig.finishTrack()
        #expect(rig.nowID == "t1")
        #expect(rig.controller.playSerial == first + 1)
        await rig.controller.setMode(.video)
        #expect(rig.controller.playSerial == first + 1)
        await rig.controller.play(list) // the same song again
        #expect(rig.controller.playSerial == first + 2)
        await rig.controller.next()
        #expect(rig.controller.playSerial == first + 3)
    }

    @Test func repeatAllLoopsTheContext() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(3))
        rig.controller.repeatMode = .all
        await rig.finishTrack()
        await rig.finishTrack()
        #expect(rig.nowID == "t3")
        await rig.finishTrack()
        #expect(rig.nowID == "t1")
        #expect(rig.autoplayIDs == ["t2", "t3"])
    }

    @Test func cycleRepeatGoesOffAllOne() {
        let rig = Rig()
        rig.controller.cycleRepeatMode()
        #expect(rig.controller.repeatMode == .all)
        rig.controller.cycleRepeatMode()
        #expect(rig.controller.repeatMode == .one)
        rig.controller.cycleRepeatMode()
        #expect(rig.controller.repeatMode == .off)
    }

    // MARK: Previous

    @Test func previousRestartsAfterThreeSecondsElseGoesBack() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(4))
        rig.controller.addToQueue([PB.track("u")])
        await rig.controller.next()  // u (from Up Next)
        await rig.controller.next()  // t2 (from Autoplay)
        #expect(rig.nowID == "t2")

        rig.advanceClock(10)
        await rig.controller.previous()
        #expect(rig.nowID == "t2", "past 3 s restarts")
        #expect(rig.engine.state.timeline.time(atUptime: rig.clock.now) < 0.5)

        await rig.controller.previous()
        #expect(rig.nowID == "u")
        #expect(rig.autoplayIDs.first == "t2", "the current item returns to its own section")
        await rig.controller.previous()
        #expect(rig.nowID == "t1")
        #expect(rig.upNextIDs == ["u"])
        await rig.controller.previous()
        #expect(rig.nowID == "t1", "no history: restart")
    }

    // MARK: Shuffle

    @Test func shuffleReordersAutoplayOnlyAndUnshuffleResumesContextOrder() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(8))
        rig.controller.addToQueue([PB.track("u1"), PB.track("u2")])
        await rig.controller.next()  // u1
        await rig.controller.next()  // u2
        await rig.controller.next()  // t2
        rig.controller.setShuffle(true)
        #expect(rig.controller.isShuffleOn)
        #expect(Set(rig.autoplayIDs) == Set(["t3", "t4", "t5", "t6", "t7", "t8"]))
        #expect(rig.autoplayIDs != ["t3", "t4", "t5", "t6", "t7", "t8"])
        rig.controller.addToQueue([PB.track("u3"), PB.track("u4")])
        #expect(rig.upNextIDs == ["u3", "u4"], "Up Next is never shuffled")

        rig.controller.setShuffle(false)
        #expect(rig.autoplayIDs == ["t3", "t4", "t5", "t6", "t7", "t8"])
    }

    @Test func shuffleEntireLibraryIsATrueShuffleAcrossCycles() async {
        let rig = Rig(seed: 7)
        let library = PB.tracks(6, prefix: "L")
        await rig.controller.shuffle(library, source: QTQueueSource(kind: .home, title: .verbatim("Library")))
        rig.controller.repeatMode = .all
        #expect(rig.controller.isShuffleOn)
        var played = [rig.nowID!]
        for _ in 0..<17 {
            await rig.finishTrack()
            played.append(rig.nowID!)
        }
        for cycle in 0..<3 {
            let slice = played[(cycle * 6)..<(cycle * 6 + 6)]
            #expect(Set(slice).count == 6, "every track once per cycle")
        }
        for (a, b) in zip(played, played.dropFirst()) {
            #expect(a != b, "never the same track twice in a row")
        }
        #expect(played[0..<6] != played[6..<12], "each cycle is reshuffled")
        #expect(rig.historyIDs == Array(played.dropLast()), "history records what actually played")
    }

    // MARK: Autoplay continuation

    @Test func autoplayContinuationFetchesMoreAndDropsDuplicates() async {
        let rig = Rig()
        var requests: [QTAutoplayRequest] = []
        rig.controller.autoplayContinuation = { request in
            requests.append(request)
            return [PB.track("t2"), PB.track("r1"), PB.track("r1"), PB.track("r2"), PB.track("rx", playable: false)]
        }
        await rig.controller.play(PB.tracks(2), source: liked)
        await rig.settle()
        #expect(requests.count == 1)
        #expect(requests.first?.excludingVideoIDs.isSuperset(of: ["t1", "t2"]) == true)
        #expect(requests.first?.seed?.videoId == "t2")
        #expect(rig.autoplayIDs == ["t2", "r1", "r2"])

        rig.controller.autoplayContinuation = nil
        rig.controller.setAutoplayEnabled(false)
        await rig.controller.next()
        #expect(rig.nowID == "t1", "Autoplay off: nothing after Up Next")
    }

    @Test func aLoadingRemainderJoinsTheContextAheadOfTheRadio() async {
        let rig = Rig()
        rig.controller.autoplayContinuation = { _ in [PB.track("r1"), PB.track("r2")] }
        let (arrived, arrive) = AsyncStream<Void>.makeStream()
        let artist = QTQueueSource(kind: .artist, id: "UC1", title: .verbatim("Artist"))
        await rig.controller.play(PB.tracks(2), source: artist, remainder: {
            for await _ in arrived { break }
            return [PB.track("t2"), PB.track("t3"), PB.track("locked", playable: false), PB.track("t4")]
        })
        await rig.settle()
        #expect(rig.autoplayIDs == ["t2", "r1", "r2"], "the radio came first")
        arrive.yield()
        await rig.settle()
        #expect(rig.autoplayIDs == ["t2", "t3", "t4", "r1", "r2"], "the rest of the list plays before the radio")

        rig.controller.setShuffle(true)
        rig.controller.setShuffle(false)
        #expect(rig.autoplayIDs == ["t2", "t3", "t4", "r1", "r2"], "the context keeps the list's order")
    }

    @Test func aRemainderForAReplacedContextIsDropped() async {
        let rig = Rig()
        let (arrived, arrive) = AsyncStream<Void>.makeStream()
        await rig.controller.play(PB.tracks(5), remainder: {
            for await _ in arrived { break }
            return [PB.track("late")]
        })
        await rig.controller.play(PB.tracks(5, prefix: "a"))
        arrive.yield()
        await rig.settle()
        #expect(rig.autoplayIDs == ["a2", "a3", "a4", "a5"])
    }

    @Test func aShuffledRemainderIsScatteredAmongTheTracksToCome() async {
        let rig = Rig()
        await rig.controller.shuffle(PB.tracks(5), remainder: { PB.tracks(40, prefix: "m") })
        await rig.settle()
        let ids = rig.autoplayIDs
        #expect(ids.count == 44)
        #expect(Set(ids).isSuperset(of: PB.tracks(40, prefix: "m").map(\.videoId)))
        #expect(!ids.prefix(4).allSatisfy { $0.hasPrefix("t") }, "scattered, not appended")
    }

    @Test func endOfQueueWaitsForTheContinuation() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(1))
        rig.controller.autoplayContinuation = { _ in [PB.track("radio")] }
        await rig.finishTrack()
        #expect(rig.nowID == "radio")
        #expect(rig.engine.state.status == .playing)
    }

    // MARK: Failures

    @Test func unplayableItemsAreSkippedButNotForever() async {
        let engine = FailingEngine(failing: ["t2", "t3"])
        let controller = QTQueueController(engine: engine)
        await controller.play(PB.tracks(5))
        await controller.next()
        #expect(controller.nowPlayingTrack?.videoId == "t4")
        #expect(engine.loads == ["t1", "t2", "t3", "t4"])
        #expect(controller.lastFailure == nil)

        engine.failing = ["t5", "a", "b", "c"]
        controller.addToQueue([PB.track("a"), PB.track("b"), PB.track("c")])
        await controller.next()
        #expect(controller.nowPlayingTrack?.videoId == "c", "stops after \(QTQueueController.maxConsecutiveFailures) failures in a row")
        #expect(controller.lastFailure == .unavailable(.removed))
    }

    @Test func aBotCheckStopsTheQueueInsteadOfSkipping() async {
        let engine = FailingEngine(failing: ["t2", "t3", "t4"])
        engine.error = .botCheck
        let controller = QTQueueController(engine: engine)
        var events: [QTPlaybackFailureEvent] = []
        controller.onFailure = { events.append($0) }
        await controller.play(PB.tracks(5))
        await controller.next()
        #expect(engine.loads == ["t1", "t2"], "the next item would land on the same check")
        #expect(controller.lastFailure == .botCheck)
        #expect(events.map(\.skipped) == [false])
    }

    @Test func aPlayerPageOnGooglesSorryPageIsABotCheck() {
        #expect(QTWebPlaybackErrorMapper.isBotCheckPage(URL(string: "https://www.google.com/sorry/index?continue=https://music.youtube.com/watch%3Fv%3DFAKE")))
        #expect(!QTWebPlaybackErrorMapper.isBotCheckPage(URL(string: "https://music.youtube.com/watch?v=dQw4w9WgXcQ")))
        #expect(!QTWebPlaybackErrorMapper.isBotCheckPage(nil))
    }

    // MARK: Song/Video and engines

    @Test func songVideoSwitchKeepsPosition() async {
        let rig = Rig()
        var t = PB.track("song")
        t.counterpart = QTCounterpart(videoId: "mv", musicVideoType: .omv)
        await rig.controller.play([t], startTime: 40)
        rig.advanceClock(5)
        await rig.controller.setMode(.video)
        #expect(rig.controller.mode == .video)
        #expect(abs((rig.engine.state.item?.startTime ?? 0) - 45) < 0.01)
        #expect(QTWebPlaybackEngine.videoID(for: rig.engine.state.item!) == "mv")

        await rig.controller.play([PB.track("novideo")])
        await rig.controller.setMode(.video)
        #expect(rig.controller.mode == .song)
    }

    /// "Prefer videos" / the Song | Video choice carries over: the next track with a video starts as the video,
    /// one without plays as the song without forgetting the choice, and the queue never changes on a switch.
    @Test func preferredModeCarriesAcrossTracks() async {
        let rig = Rig()
        var a = PB.track("a")
        a.counterpart = QTCounterpart(videoId: "a-mv", musicVideoType: .omv)
        var c = PB.track("c")
        c.counterpart = QTCounterpart(videoId: "c-mv", musicVideoType: .omv)
        await rig.controller.play([a, PB.track("b"), c])
        let autoplayBefore = rig.autoplayIDs
        await rig.controller.setMode(.video)
        #expect(rig.controller.preferredMode == .video)
        #expect(rig.autoplayIDs == autoplayBefore, "a switch leaves the queue alone")
        await rig.controller.next()
        #expect(rig.controller.mode == .song, "no video: the song")
        #expect(rig.controller.preferredMode == .video, "…without forgetting the choice")
        await rig.controller.next()
        #expect(rig.nowID == "c")
        #expect(rig.controller.mode == .video)
        #expect(QTWebPlaybackEngine.videoID(for: rig.engine.state.item!) == "c-mv")
    }

    /// Counterparts the track doesn't carry are looked up for the current and the next track, written into the
    /// queue items (same order, same ids), and a prefetched one makes the next track start as its video.
    @Test func resolvedCounterpartsPatchTheQueue() async {
        let rig = Rig()
        var asked: [String] = []
        rig.controller.counterpartResolver = { track in
            asked.append(track.videoId)
            return QTCounterpart(videoId: track.videoId + "-mv", musicVideoType: .omv)
        }
        rig.controller.preferredMode = .video
        await rig.controller.play(PB.tracks(3))
        for _ in 0..<20 { await Task.yield() }
        #expect(Set(asked) == ["t1", "t2"])
        #expect(rig.controller.queue.nowPlaying?.track.counterpart?.videoId == "t1-mv")
        #expect(rig.controller.queue.autoplay.first?.track.counterpart?.videoId == "t2-mv")
        #expect(rig.autoplayIDs == ["t2", "t3"])
        await rig.controller.next()
        #expect(rig.controller.mode == .video, "prefetched: starts as the video")
    }

    @Test func replacingTheEngineKeepsTheItemAndPosition() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(2), startTime: 30)
        rig.advanceClock(2)
        let other = QTSimulatedPlaybackEngine(account: .free, clock: { 5000 }, tickInterval: nil)
        await rig.controller.replaceEngine(other)
        #expect(rig.controller.engine === other)
        #expect(other.state.item?.track.videoId == "t1")
        #expect(abs((other.state.item?.startTime ?? 0) - 32) < 0.01)
        #expect(rig.controller.capabilities == .web)
    }

    @Test func engineSelectionFollowsTierAndData() {
        #expect(QTPlaybackEngineSelector.kind(tier: .free, usesMockData: false) == .web)
        #expect(QTPlaybackEngineSelector.kind(tier: .premium, usesMockData: false, nativeAvailable: false) == .web)
        #expect(QTPlaybackEngineSelector.kind(tier: .premium, usesMockData: false, nativeAvailable: true) == .web)
        #expect(QTPlaybackEngineSelector.kind(tier: .premium, usesMockData: false, nativeOptIn: true, nativeAvailable: true) == .native)
        #expect(QTPlaybackEngineSelector.kind(tier: .free, usesMockData: true) == .simulated)
        #expect(QTPlaybackEngineSelector.capabilities(of: .web, tier: .premium) == .web)
        #expect(QTPlaybackEngineSelector.capabilities(of: .native, tier: .premium).contains(.gapless))
        #expect(QTPlaybackEngineSelector.capabilities(of: .web, tier: .free).contains(.visualizerData))
        #expect(!QTPlaybackEngineSelector.capabilities(of: .web, tier: .free).contains(.equalizer))
    }
}
