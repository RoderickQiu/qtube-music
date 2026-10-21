import AppKit
import Foundation
import QTCore
import QTLyrics
import QTPlayback
import Testing
@testable import QTUI

/// Desktop area, native-Mac review fixes: Space routing, Dock menu, engine-gated playback settings, menu order,
/// sidebar context menu targets, system-menu language sync.
@MainActor
@Suite struct QTDesktopMacTests {
    // MARK: Space

    /// A view that takes keyboard focus and either uses the key (like a focused control) or passes it on.
    final class FocusView: NSView {
        let usesKeys: Bool
        private(set) var received = 0
        init(usesKeys: Bool) {
            self.usesKeys = usesKeys
            super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            received += 1
            if !usesKeys { super.keyDown(with: event) }
        }
    }

    static func space(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
    }

    static func offscreenWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100), styleMask: [.titled],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    @Test func spaceGoesToPlaybackOnlyWhenNoControlHasFocus() {
        let window = Self.offscreenWindow()
        #expect(QTKeyRouting.spaceDecision(for: nil, in: window) == .playback)
        #expect(QTKeyRouting.spaceDecision(for: window, in: window) == .playback)
        #expect(QTKeyRouting.spaceDecision(for: NSTableView(), in: window) == .playback)
        #expect(QTKeyRouting.spaceDecision(for: NSOutlineView(), in: window) == .playback)
        #expect(QTKeyRouting.spaceDecision(for: NSScrollView(), in: window) == .playback)
        // Full Keyboard Access: every control (not just NSButton) and any other focused view gets Space first.
        #expect(QTKeyRouting.spaceDecision(for: NSButton(), in: window) == .responderChainFirst)
        #expect(QTKeyRouting.spaceDecision(for: NSSwitch(), in: window) == .responderChainFirst)
        #expect(QTKeyRouting.spaceDecision(for: NSStepper(), in: window) == .responderChainFirst)
        #expect(QTKeyRouting.spaceDecision(for: NSSegmentedControl(), in: window) == .responderChainFirst)
        #expect(QTKeyRouting.spaceDecision(for: NSTextView(), in: window) == .responderChainFirst)
        #expect(QTKeyRouting.spaceDecision(for: FocusView(usesKeys: true), in: window) == .responderChainFirst)
    }

    @Test func focusedViewThatUsesSpaceWinsAndOtherwiseItFallsThrough() throws {
        let window = Self.offscreenWindow()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = content

        let control = FocusView(usesKeys: true)
        content.addSubview(control)
        #expect(window.makeFirstResponder(control))
        #expect(QTKeyRouting.deliver(Self.space(in: window), to: window), "a focused control keeps Space")
        #expect(control.received == 1)

        let passive = FocusView(usesKeys: false)
        content.addSubview(passive)
        #expect(window.makeFirstResponder(passive))
        #expect(!QTKeyRouting.deliver(Self.space(in: window), to: window), "unused Space falls through to play/pause")
        #expect(passive.received == 1)
        // The temporary catcher is gone again.
        var r: NSResponder? = window.firstResponder
        while let next = r?.nextResponder { r = next }
        #expect(!(r is QTUnusedKeyCatcher))
        window.close()
    }

    @Test func onlyBareSpaceAndArrowChordsCollide() {
        let w = Self.offscreenWindow()
        func key(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                             context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)!
        }
        #expect(QTKeyRouting.collidesWithTextEditing(key(49, [])))
        #expect(!QTKeyRouting.collidesWithTextEditing(key(49, .shift)))
        #expect(QTKeyRouting.collidesWithTextEditing(key(124, .command)))
        #expect(QTKeyRouting.collidesWithTextEditing(key(126, .option)))
        #expect(!QTKeyRouting.collidesWithTextEditing(key(126, [.command, .shift])))
        #expect(QTKeyRouting.isBareSpace(key(49, [])))
    }

    // MARK: Dock menu

    static func model(tracks: [QTTrack] = []) -> QTAppModel {
        let catalog = QTMockCatalog(tracks: tracks, liked: QTPlaylist(id: "LM", title: .localized("Liked Songs"), kind: .liked, tracks: tracks))
        let engine = QTSimulatedPlaybackEngine(account: .premium, tickInterval: nil)
        let player = QTPlayerModel(engine: engine, lyricsProvider: QTMockLyricsProvider(catalog: catalog))
        let defaults = UserDefaults(suiteName: "qt.tests.desktopmac.\(UUID().uuidString)")!
        return QTAppModel(settings: QTSettingsStore(defaults: defaults), player: player, catalog: catalog,
                          launch: QTLaunchOptions(arguments: ["qt.catalog": "mock"]))
    }

    @Test func dockMenuHasNoTransportWithNothingLoadedAndOffersAllRepeatModes() async {
        let model = Self.model()
        let menu = QTDockMenuBuilder.menu(model: model)
        let play = menu.items.first { $0.title == QTLoc.tr("Play") }
        let next = menu.items.first { $0.title == QTLoc.tr("Next") }
        let previous = menu.items.first { $0.title == QTLoc.tr("Previous") }
        #expect(play?.isEnabled == false)
        #expect(next?.isEnabled == false)
        #expect(previous?.isEnabled == false)
        let repeatItem = menu.items.first { $0.title == QTLoc.tr("Repeat") }
        let modes = repeatItem?.submenu?.items ?? []
        #expect(modes.count == 3)
        #expect(modes.filter { $0.state == .on }.count == 1)
        // Choosing Repeat One keeps it (the old checkbox could only toggle Off ⇄ All).
        if let one = modes.last, let action = one.action { _ = (one.target as? NSObject)?.perform(action, with: one) }
        #expect(model.player.repeatMode == .one)

        let track = QTTrack(videoId: "dock-a", title: "A", artists: [QTArtistRef(name: "Artist")], duration: 200)
        await model.player.play([track], startingAt: 0, autoplay: false)
        let loaded = QTDockMenuBuilder.menu(model: model)
        #expect(loaded.items.first { $0.title == QTLoc.tr("Play") }?.isEnabled == true)
        #expect(loaded.items.first { $0.title == "A" } != nil)
    }

    // MARK: Settings › Playback

    @Test func playbackEffectsFollowTheEngineNotTheAccount() {
        func note(_ caps: QTPlaybackCapabilities, _ account: QTAccountKind, eligible: Bool = true, optedIn: Bool = false,
                  fallback: String? = nil) -> String? {
            QTPlaybackSettings.unsupportedNote(capabilities: caps, account: account, eligible: eligible, optedIn: optedIn,
                                               fallbackReason: fallback)
        }
        // Premium on the web engine, not opted in: says what would turn them on.
        #expect(note(.web, .premium)
            == QTLoc.tr("YouTube’s player doesn’t support these. Turn on the native engine to use them.", table: .desktop))
        #expect(note(.web, .free)
            == QTLoc.tr("Free accounts play through YouTube’s own player, which doesn’t support these.", table: .desktop))
        // Signed out (or demo data): the opt-in needs a Premium session.
        #expect(note(.web, .premium, eligible: false)
            == QTLoc.tr("Needs a signed-in YouTube Music Premium account.", table: .desktop))
        // Opted in, but the native engine fell back for this session: the truth, not a promise.
        #expect(note(.web, .premium, optedIn: true, fallback: "HTTP 403")
            == QTLoc.tr("The native engine isn’t working right now, so YouTube’s player is playing. It doesn’t support these.", table: .desktop))
        // The native engine plays (gapless + crossfade + EQ): no note.
        #expect(note(.premium, .premium, optedIn: true) == nil)
    }

    // MARK: Menus

    @Test func numberedSectionsFollowTheSidebar() {
        #expect(QTCommands.sidebarShortcutOrder == [.home, .explore, .songs, .albums, .artists, .liked, .history,
                                                    .uploads])
    }

    @Test func sidebarContextMenuTargetsLikedAndPlaylistsOnly() {
        #expect(QTSidebarPlaylistTarget(item: .home, playlist: nil) == nil)
        #expect(QTSidebarPlaylistTarget(item: .songs, playlist: nil) == nil)
        let liked = QTSidebarPlaylistTarget(item: .liked, playlist: nil)
        #expect(liked?.link == "https://music.youtube.com/playlist?list=LM")
        let p = QTPlaylist(id: "VLPL123", title: .verbatim("Road"), kind: .user, tracks: nil)
        let target = QTSidebarPlaylistTarget(item: .playlist(p.id), playlist: p)
        #expect(target?.link == "https://music.youtube.com/playlist?list=PL123")
        #expect(target?.title == "Road")
    }

    // MARK: System menus language

    @Test func interfaceLanguageIsWrittenForTheSystemMenus() throws {
        let suite = "qt.tests.applelanguages.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func saved() -> [String]? { defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] }
        QTInterfaceLanguageSync.write(.zhCN, to: defaults)
        #expect(saved() == ["zh-Hans"])
        QTInterfaceLanguageSync.write(.enUS, to: defaults)
        #expect(saved() == ["en"])
        QTInterfaceLanguageSync.write(.automatic, to: defaults)
        #expect(saved() == nil, "Auto removes the app's own value, so macOS's languages apply again")
        #expect(QTInterfaceLanguageSync.menuLanguage(for: ["zh-Hans"]) == .zhHans)
        #expect(QTInterfaceLanguageSync.menuLanguage(for: ["en"]) == .en)
        #expect(QTInterfaceLanguageSync.menuLanguage(for: []) == .en)
    }

    @Test func launchArgumentLanguagesAreSessionOnly() {
        // Screenshots / `-qt.lang` never offer Relaunch (and never write AppleLanguages at launch).
        let launch = QTLaunchOptions(arguments: ["qt.lang": "zh-CN"])
        #expect(QTInterfaceLanguageSync.isSessionOverride(launch))
        #expect(!QTInterfaceLanguageSync.menusAreStale(interface: .zhHans, launch: launch))
        #expect(QTInterfaceLanguageSync.appleLanguages(for: .automatic) == nil)
    }

    @Test func launchSyncWritesExplicitChoicesAndNeverClearsSystemSettingsLanguage() throws {
        let suite = "qt.tests.langsync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func saved() -> [String]? { defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] }
        func store(_ language: QTInterfaceLanguage) throws {
            var s = QTSettings()
            s.interfaceLanguage = language
            defaults.set(try JSONEncoder().encode(s), forKey: QTSettingsStore.defaultsKey)
        }
        let launch = QTLaunchOptions(arguments: [:])
        // Auto + a per-app language chosen in System Settings (same key): left alone.
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        try store(.automatic)
        QTInterfaceLanguageSync.syncAtLaunch(launch: launch, defaults: defaults, domain: suite)
        #expect(saved() == ["zh-Hans"])
        // An explicit in-app choice saved by an older build reaches the menus on the next launch.
        try store(.enUS)
        QTInterfaceLanguageSync.syncAtLaunch(launch: launch, defaults: defaults, domain: suite)
        #expect(saved() == ["en"])
        // Scripted / `-qt.lang` launches never touch it.
        try store(.zhCN)
        QTInterfaceLanguageSync.syncAtLaunch(launch: QTLaunchOptions(arguments: ["qt.readyFile": "/tmp/x.json"]),
                                             defaults: defaults, domain: suite)
        #expect(saved() == ["en"])
    }
}
