import Foundation
import QTCore
import Testing
@testable import QTPlayback

/// "Don't Play This Artist" in the queue: Autoplay's radio, radio/mix contexts and shuffle pass blocked artists over;
/// Up Next, what the listener picks and albums/playlists played in order still play them.
@MainActor
@Suite struct AutoPickSkipTests {
    let liked = QTQueueSource(kind: .playlist, id: "LM", title: .localized("Liked Songs"))
    let radio = QTQueueSource(kind: .radio, id: "mood-chill", title: .verbatim("Chill"))

    /// Blocks the artists of the given track ids (PB tracks are by "Artist <id>").
    @MainActor final class Rules {
        var list = QTArtistBlocklist()
        func block(_ ids: String...) { for id in ids { list.add(QTBlockedArtist(name: "Artist \(id)")) } }
    }

    func rig(_ rules: Rules, seed: UInt64 = 42) -> Rig {
        let rig = Rig(seed: seed)
        rig.controller.autoPickSkips = { rules.list.blocks($0) }
        return rig
    }

    @Test func aPlaylistPlayedInOrderStillPlaysBlockedSongs() async {
        let rules = Rules()
        rules.block("t2")
        let rig = rig(rules)
        await rig.controller.play(PB.tracks(3), source: liked)
        #expect(rig.autoplayIDs == ["t2", "t3"], "listed, not removed")
        await rig.finishTrack()
        #expect(rig.nowID == "t2")
    }

    @Test func shuffleNeverPicksABlockedArtist() async {
        let rules = Rules()
        rules.block("t3", "t5", "t8")
        for seed in UInt64(1)...20 {
            let rig = rig(rules, seed: seed)
            await rig.controller.shuffle(PB.tracks(10), source: liked)
            var played = [rig.nowID]
            #expect(Set(rig.autoplayIDs).isDisjoint(with: ["t3", "t5", "t8"]))
            for _ in 0..<10 {
                await rig.controller.next()
                played.append(rig.nowID)
            }
            #expect(Set(played.compactMap { $0 }).isDisjoint(with: ["t3", "t5", "t8"]), "seed \(seed): \(played)")
        }
    }

    @Test func shuffleOnAPlayingListDropsBlockedSongsAndOffBringsTheListBack() async {
        let rules = Rules()
        rules.block("t4")
        let rig = rig(rules)
        await rig.controller.play(PB.tracks(5), source: liked)
        rig.controller.setShuffle(true)
        #expect(!rig.autoplayIDs.contains("t4"))
        rig.controller.setShuffle(false)
        #expect(rig.autoplayIDs == ["t2", "t3", "t4", "t5"], "in order, the playlist plays all of it")
    }

    @Test func theRadioContinuationLeavesBlockedArtistsOut() async {
        let rules = Rules()
        rules.block("r1", "r3")
        let rig = rig(rules)
        rig.controller.autoplayContinuation = { _ in [PB.track("r1"), PB.track("r2"), PB.track("r3"), PB.track("r4")] }
        await rig.controller.play(PB.tracks(1), source: liked)
        await rig.settle()
        #expect(rig.autoplayIDs == ["r2", "r4"])
    }

    @Test func aRadioOrMixContextSkipsBlockedSongsButPlaysThePickedOne() async {
        let rules = Rules()
        rules.block("t1", "t3")
        let rig = rig(rules)
        // The listener picked t1 on a mood page: it plays; the rest of the radio passes t3 over.
        await rig.controller.play(PB.tracks(4), startingAt: 0, source: radio)
        #expect(rig.nowID == "t1")
        #expect(rig.autoplayIDs == ["t2", "t4"])

        let mix = QTQueueSource(kind: .playlist, id: "VLRDTMAK5uy_mix", title: .verbatim("My Supermix"))
        await rig.controller.play(PB.tracks(4), startingAt: 1, source: mix)
        #expect(rig.autoplayIDs == ["t4"])
    }

    @Test func upNextAlwaysPlays() async {
        let rules = Rules()
        rules.block("x")
        let rig = rig(rules)
        await rig.controller.shuffle(PB.tracks(3), source: liked)
        rig.controller.addToQueue([PB.track("x")])
        await rig.controller.next()
        #expect(rig.nowID == "x", "added by the listener")
    }

    @Test func gaplessPreparesTheSongThatWillPlay() async {
        let rules = Rules()
        rules.block("t2")
        let rig = rig(rules)
        await rig.controller.play(PB.tracks(3), source: radio)
        #expect(rig.controller.naturalNext()?.track.videoId == "t3")
    }

    @Test func blockingTheArtistOfAnAutoPickedSongMovesOnButAPickedOneKeepsPlaying() async {
        let rules = Rules()
        let rig = rig(rules)
        rig.controller.autoplayContinuation = { _ in [PB.track("r1"), PB.track("r2"), PB.track("r3")] }
        await rig.controller.play(PB.tracks(1), source: liked)
        await rig.settle()

        // The listener's own pick: blocking its artist leaves it playing.
        rules.block("t1")
        rig.controller.autoPickRulesDidChange()
        await rig.settle()
        #expect(rig.nowID == "t1")

        await rig.finishTrack()
        #expect(rig.nowID == "r1", "Autoplay's radio picked it")
        rules.block("r1", "r2")
        rig.controller.autoPickRulesDidChange()
        await rig.settle()
        #expect(rig.nowID == "r3", "moved on at once, past the other blocked song")
        #expect(rig.historyIDs.contains("r1") && !rig.historyIDs.contains("r2"))
    }

    @Test func blockingWhilePausedDoesNotStartPlayback() async {
        let rules = Rules()
        let rig = rig(rules)
        rig.controller.autoplayContinuation = { _ in [PB.track("r1"), PB.track("r2")] }
        await rig.controller.play(PB.tracks(1), source: liked)
        await rig.finishTrack()
        #expect(rig.nowID == "r1")
        rig.controller.pause()
        rules.block("r1", "r2")
        rig.controller.autoPickRulesDidChange()
        await rig.settle()
        #expect(rig.nowID == "r1")
        #expect(rig.autoplayIDs.isEmpty, "the queue no longer lists r2")
        #expect(rig.engine.state.status != .playing)
    }

    @Test func radioItemsSurviveARelaunchAndOldQueuesStillDecode() async throws {
        let rules = Rules()
        let rig = rig(rules)
        rig.controller.autoplayContinuation = { _ in [PB.track("r1"), PB.track("r2")] }
        await rig.controller.play(PB.tracks(2), source: liked)
        await rig.settle()
        let snapshot = rig.controller.snapshot()
        #expect(snapshot.radioIDs?.count == 2)

        let data = try JSONEncoder().encode(snapshot)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "radioIDs")
        let old = try JSONDecoder().decode(QTQueueSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.radioIDs == nil)

        let restored = self.rig(rules)
        restored.controller.apply(snapshot)
        rules.block("r1")
        restored.controller.autoPickRulesDidChange()
        #expect(restored.autoplayIDs == ["t2", "r2"], "the radio's r1 goes; the playlist's t2 stays")
    }

    @Test func queueSourcesThatPickByThemselves() {
        func source(_ kind: QTQueueSource.Kind, _ id: String?) -> QTQueueSource { QTQueueSource(kind: kind, id: id, title: .verbatim("")) }
        #expect(source(.radio, nil).isAutomatic)
        #expect(source(.playlist, "RDAMVMabc").isAutomatic)
        #expect(source(.playlist, "VLRDTMAK5uy_x").isAutomatic)
        #expect(!source(.playlist, "VLRDCLAK5uy_curated").isAutomatic, "YouTube's curated playlists are playlists")
        #expect(!source(.playlist, "LM").isAutomatic)
        #expect(!source(.playlist, "VLPL123").isAutomatic)
        #expect(!source(.album, "MPREb_x").isAutomatic)
        #expect(!source(.artist, "UC1").isAutomatic)
    }
}
