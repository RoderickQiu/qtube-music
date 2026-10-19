import Foundation
import QTCore
import Testing
@testable import QTPlayback

@MainActor
@Suite struct PersistenceTests {
    func tempStore() -> QTQueueStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "qt-playback-tests-\(UUID().uuidString)")
        return QTQueueStore(fileURL: dir.appending(path: "Playback/Queue.json"))
    }

    @Test func queueSurvivesARelaunch() async throws {
        let store = tempStore()
        let first = Rig(store: store)
        var mv = PB.track("t3")
        mv.counterpart = QTCounterpart(videoId: "t3-mv", musicVideoType: .omv)
        var list = PB.tracks(6)
        list[2] = mv
        await first.controller.play(list, startingAt: 0, source: QTQueueSource(kind: .album, id: "MPREb_x", title: .verbatim("Album")))
        first.controller.addToQueue([PB.track("u1")])
        await first.controller.next()  // u1
        await first.controller.next()  // t2
        await first.controller.next()  // t3
        await first.controller.setMode(.video)
        first.controller.setShuffle(true)
        first.controller.repeatMode = .all
        first.advanceClock(42)
        await first.controller.flush()
        let saved = first.controller.snapshot()

        let second = Rig(store: store)
        let restored = await second.controller.restore()
        #expect(restored)
        #expect(second.controller.queue == saved.queue)
        #expect(second.nowID == "t3")
        #expect(second.historyIDs == ["t1", "u1", "t2"])
        #expect(Set(second.autoplayIDs) == ["t4", "t5", "t6"])
        #expect(second.controller.isShuffleOn)
        #expect(second.controller.repeatMode == .all)
        #expect(second.controller.mode == .video)
        #expect(second.controller.queue.autoplaySource?.id == "MPREb_x")
        // Cued at the saved position, paused: a relaunch never starts playback by itself.
        #expect(second.engine.state.status == .paused)
        #expect(abs((second.engine.state.item?.startTime ?? 0) - 42) < 0.01)
        #expect(second.engine.state.item?.mode == .video)

        // Context and origins came back too: un-shuffle resumes album order, Previous returns items home.
        second.controller.setShuffle(false)
        #expect(second.autoplayIDs == ["t4", "t5", "t6"])
        await second.controller.previous()  // 42 s in → restart
        await second.controller.previous()
        #expect(second.nowID == "t2")
        #expect(second.autoplayIDs.first == "t3")
    }

    @Test func editsAreSavedDebounced() async throws {
        let store = tempStore()
        let rig = Rig(store: store)
        await rig.controller.play(PB.tracks(3))
        rig.controller.addToQueue([PB.track("later")])
        try await Task.sleep(for: .milliseconds(900))
        let snapshot = await store.load()
        #expect(snapshot?.queue.upNext.map(\.track.videoId) == ["later"])
    }

    @Test func missingCorruptOrNewerFilesRestoreNothing() async throws {
        let store = tempStore()
        #expect(await store.load() == nil)
        let rig = Rig(store: store)
        #expect(await rig.controller.restore() == false)

        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(await store.load() == nil)

        var future = QTQueueSnapshot(queue: QTQueue(nowPlaying: QTQueueItem(track: PB.track("x"))))
        future.version = QTQueueSnapshot.currentVersion + 1
        try await store.save(future)
        #expect(await store.load() == nil)

        try await store.save(QTQueueSnapshot(queue: QTQueue(nowPlaying: QTQueueItem(track: PB.track("x")))))
        #expect(await store.load()?.queue.nowPlaying?.track.videoId == "x")
        await store.remove()
        #expect(await store.load() == nil)
    }

    @Test func applicationSupportLocationIsPerBundle() async {
        let store = QTQueueStore.applicationSupport(bundleIdentifier: "com.roderickqiu.qtube.dev-playback")
        let path = store.fileURL.path
        #expect(path.hasSuffix("Application Support/com.roderickqiu.qtube.dev-playback/Playback/Queue.json"))
    }
}
