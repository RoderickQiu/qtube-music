import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// Start Radio in the queue: a station replaces what plays the way a mix does (Up Next kept, Autoplay switched on,
/// the continuation asked with the station as the source), and on the song playing now it only replaces what follows.
@MainActor
@Suite struct RadioQueueTests {
    let station = QTQueueSource(kind: .radio, id: "RDAMVMs1", title: .verbatim("Title s1 Radio"))

    @Test func aStationReplacesTheContextAndKeepsUpNext() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(4), source: QTQueueSource(kind: .album, title: .verbatim("Album")))
        rig.controller.addToQueue([PB.track("mine")])
        await rig.controller.playRadio([PB.track("s1")] + PB.tracks(3, prefix: "r"), source: station)
        #expect(rig.nowID == "s1")
        #expect(rig.autoplayIDs == ["r1", "r2", "r3"])
        #expect(rig.upNextIDs == ["mine"], "Up Next stays, as when a mix plays")
        #expect(rig.controller.queue.autoplaySource == station)
        #expect(rig.engine.state.status == .playing)
        #expect(rig.historyIDs == ["t1"])
    }

    @Test func aStationSwitchesAutoplayOnAndCuesWhenAsked() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(2))
        rig.controller.setAutoplayEnabled(false)
        await rig.controller.playRadio([PB.track("s1"), PB.track("r1")], source: station, autoplay: false)
        #expect(rig.controller.queue.isAutoplayEnabled)
        #expect(rig.nowID == "s1")
        #expect(rig.engine.state.status != .playing, "cued, not playing")
        await rig.controller.next()
        #expect(rig.nowID == "r1", "the station is what plays next")
    }

    @Test func unplayableStationSongsAreLeftOutAndAnEmptyStationChangesNothing() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(2))
        await rig.controller.playRadio([PB.track("x", playable: false)], source: station)
        #expect(rig.nowID == "t1")
        #expect(rig.controller.queue.autoplaySource != station)
        await rig.controller.playRadio([PB.track("s1"), PB.track("x", playable: false), PB.track("r1")], source: station)
        #expect(rig.autoplayIDs == ["r1"])
    }

    @Test func theSongPlayingNowPlaysOnAndTheStationFollowsIt() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(4))
        rig.controller.addToQueue([PB.track("mine")])
        let loadsBefore = rig.engine.state.item?.queueID
        rig.controller.continueAsRadio([PB.track("t1"), PB.track("r1"), PB.track("r2"), PB.track("r1")], source: station)
        #expect(rig.nowID == "t1")
        #expect(rig.engine.state.item?.queueID == loadsBefore, "not reloaded")
        #expect(rig.engine.state.status == .playing)
        #expect(rig.autoplayIDs == ["r1", "r2"], "the playing song and repeats are left out")
        #expect(rig.upNextIDs == ["mine"])
        #expect(rig.controller.queue.autoplaySource == station)
        await rig.controller.next()
        await rig.controller.next()
        #expect(rig.nowID == "r1")
    }

    @Test func autoplayExtendsAStationWithTheStationAsItsSource() async {
        let rig = Rig()
        var requests: [QTAutoplayRequest] = []
        rig.controller.autoplayContinuation = { request in
            requests.append(request)
            return [PB.track("r2"), PB.track("more1"), PB.track("more2")]
        }
        await rig.controller.playRadio([PB.track("s1"), PB.track("r1"), PB.track("r2")], source: station)
        await rig.settle()
        #expect(requests.count == 1)
        let request = requests.first
        #expect(request?.source == station)
        #expect(request?.seed?.videoId == "r2")
        #expect(request?.excludingVideoIDs.isSuperset(of: ["s1", "r1", "r2"]) == true)
        #expect(rig.autoplayIDs == ["r1", "r2", "more1", "more2"], "what's queued already isn't added twice")
    }

    @Test func aStationOnTheSongPlayingNowAlsoGetsExtended() async {
        let rig = Rig()
        await rig.controller.play(PB.tracks(1))
        var sources: [QTQueueSource?] = []
        rig.controller.autoplayContinuation = { request in
            sources.append(request.source)
            return [PB.track("more1")]
        }
        rig.controller.continueAsRadio([PB.track("r1")], source: station)
        await rig.settle()
        #expect(sources.first == station)
        #expect(rig.autoplayIDs == ["r1", "more1"])
    }
}
