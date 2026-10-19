import QTCore
import QTPlayback
import SwiftUI

// Owner: builder "desktop". Native Settings window: toolbar tabs + grouped Forms (General, Playback, Lyrics,
// Account, Integrations, Advanced). Every control writes through `QTSettingsStore`, so changes apply live (language too).

public enum QTSettingsTab: String, CaseIterable, Hashable, Sendable {
    case general, playback, lyrics, account, integrations, advanced
}

public struct QTSettingsView: View {
    @Environment(QTAppModel.self) private var model
    @State private var tab: QTSettingsTab = .general

    public init() {}

    public var body: some View {
        // Each tab has its own content height, so the window resizes to fit it instead of scrolling or
        // leaving dead space.
        TabView(selection: $tab) {
            Tab(QTLoc.tr("General"), systemImage: "gearshape", value: QTSettingsTab.general) { QTGeneralSettings().qtSettingsPane() }
            Tab(QTLoc.tr("Playback", table: .desktop), systemImage: "play.circle", value: QTSettingsTab.playback) { QTPlaybackSettings().qtSettingsPane() }
            Tab(QTLoc.tr("Lyrics"), systemImage: QTIcon.lyrics.systemName, value: QTSettingsTab.lyrics) { QTLyricsSettings().qtSettingsPane() }
            Tab(QTLoc.tr("Account"), systemImage: "person.crop.circle", value: QTSettingsTab.account) { QTAccountSettings().qtSettingsPane() }
            Tab(QTLoc.tr("Integrations", table: .desktop), systemImage: "puzzlepiece.extension", value: QTSettingsTab.integrations) { QTIntegrationsSettingsPane().qtSettingsPane() }
            Tab(QTLoc.tr("Advanced", table: .desktop), systemImage: "gearshape.2", value: QTSettingsTab.advanced) { QTAdvancedSettings().qtSettingsPane() }
        }
        .frame(width: 560)
        .scrollContentBackground(.visible)
        .onAppear {
            if let t = model.launch.string(QTDesktopLaunchKey.settingsTab).flatMap(QTSettingsTab.init(rawValue:)) { tab = t }
        }
        .background(QTWindowAccessor { [model] window in
            window.identifier = QTWindowID.settings.identifier
            if model.launch.screen != nil {
                // Screenshot/dev launches: open on the requested display, without the zoom-in animation.
                window.animationBehavior = .none
                let hold = QTReadiness.shared.hold("settings placement")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150)) // let SwiftUI size the window to its content first
                    QTWindowPlacement.center(window, screenName: model.launch.effectiveScreenName)
                    QTReadiness.shared.release(hold)
                }
            }
        })
        .accessibilityIdentifier("qt.settings")
    }
}

extension View {
    /// A grouped Form that is exactly as tall as its sections (no empty slab under the last one): scrolling off,
    /// ideal height. The Settings window then resizes per tab, like System Settings' panes in Music and Finder.
    func qtSettingsPane() -> some View {
        self
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `Binding` into the settings store.
@MainActor
private func setting<T>(_ store: QTSettingsStore, _ keyPath: WritableKeyPath<QTSettings, T>) -> Binding<T> {
    Binding(get: { store.settings[keyPath: keyPath] }, set: { v in store.update { $0[keyPath: keyPath] = v } })
}

// MARK: - General

struct QTGeneralSettings: View {
    @Environment(QTAppModel.self) private var model

    private var staleMenus: Bool {
        #if DEBUG
        if model.launch.bool(QTDesktopLaunchKey.staleMenus) == true { return true }
        #endif
        return QTInterfaceLanguageSync.menusAreStale(interface: QTLoc.language, launch: model.launch)
    }

    var body: some View {
        let store = model.settings
        Form {
            Section {
                LabeledContent(QTLoc.tr("Interface language")) {
                    HStack(spacing: QTTheme.Spacing.s) {
                        // The app switches at once; AppKit's own menu items follow the next launch.
                        if staleMenus {
                            Button(QTLoc.tr("Relaunch", table: .desktop)) { QTInterfaceLanguageSync.relaunch() }
                                .controlSize(.small)
                                .help(QTLoc.tr("Relaunch to switch the system menus too", table: .desktop))
                                .accessibilityIdentifier("qt.settings.relaunch")
                        }
                        Picker(QTLoc.tr("Interface language"),
                               selection: Binding(get: { store.settings.interfaceLanguage },
                                                  set: { QTInterfaceLanguageSync.choose($0, store: store) })) {
                            Text(QTLoc.tr("Auto")).tag(QTInterfaceLanguage.automatic)
                            Divider()
                            Text(verbatim: "English").tag(QTInterfaceLanguage.enUS)
                            Text(verbatim: "简体中文").tag(QTInterfaceLanguage.zhCN)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("qt.settings.interfaceLanguage")
                    }
                }
                Picker(QTLoc.tr("Theme"), selection: Binding(get: { model.theme }, set: { model.theme = $0 })) {
                    Text(QTLoc.tr("Auto")).tag(QTThemePreference.automatic)
                    Text(QTLoc.tr("Light")).tag(QTThemePreference.light)
                    Text(QTLoc.tr("Dark")).tag(QTThemePreference.dark)
                }
                .pickerStyle(.segmented)
            }
            QTNotificationsSettingsSection()
            Section(QTLoc.tr("Menu Bar", table: .desktop)) {
                Toggle(QTLoc.tr("Show song title", table: .desktop), isOn: setting(store, \.showsTitleInMenuBar))
                Toggle(QTLoc.tr("Scroll long titles", table: .desktop), isOn: setting(store, \.menuBarScrollsTitle))
                    .disabled(!store.settings.showsTitleInMenuBar)
            }
            Section {
                Picker(QTLoc.tr("When the main window closes", table: .desktop), selection: setting(store, \.closeWindowKeepsPlaying)) {
                    Text(QTLoc.tr("Keep playing", table: .desktop)).tag(true)
                    Text(QTLoc.tr("Quit QTube Music", table: .desktop)).tag(false)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Playback

struct QTPlaybackSettings: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = model.settings
        // Gated on what the engine playing right now can do, not on the account tier: Premium accounts also play
        // through YouTube's web player until the native engine ships (M5), and it supports none of these.
        let caps = model.player.capabilities
        let gapless = caps.contains(.gapless)
        let crossfades = caps.contains(.crossfade)
        let equalizes = caps.contains(.equalizer)
        let crossfade = crossfades ? store.settings.playbackEffects.crossfadeSeconds : 0
        Form {
            Section {
                Toggle(QTLoc.tr("Prefer videos when available"), isOn: setting(store, \.preferVideos))
            }
            Section {
                // Controls show what is in effect: an engine without a feature reads "off" (the saved choices
                // come back with an engine that has it).
                Toggle(QTLoc.tr("Gapless playback", table: .desktop),
                       isOn: Binding(get: { gapless && store.settings.playbackEffects.gapless },
                                     set: { v in store.update { $0.playbackEffects.gapless = v } }))
                    .disabled(!gapless)
                LabeledContent(QTLoc.tr("Crossfade", table: .desktop)) {
                    HStack(spacing: QTTheme.Spacing.s) {
                        Slider(value: Binding(get: { crossfades ? store.settings.playbackEffects.crossfadeSeconds : 0 },
                                              set: { v in store.update { $0.playbackEffects.crossfadeSeconds = v } }),
                               in: 0...12, step: 1)
                            .frame(width: 200)
                            .accessibilityValue(crossfadeLabel(crossfade))
                        Text(crossfadeLabel(crossfade))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                .disabled(!crossfades)
                Picker(QTLoc.tr("Equalizer", table: .desktop),
                       selection: Binding(get: { equalizes ? store.settings.playbackEffects.equalizer : .off },
                                          set: { v in store.update { $0.playbackEffects.equalizer = v } })) {
                    ForEach(QTEqualizerPreset.allCases, id: \.self) { p in
                        Text(Self.name(p)).tag(p)
                        if p == .off { Divider() }
                    }
                }
                .disabled(!equalizes)
            } header: {
                Text(QTLoc.tr("Premium engine"))
            } footer: {
                if let note = Self.unsupportedNote(capabilities: caps, account: model.account) {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Why the section is off, or nil when the playing engine supports all of it.
    static func unsupportedNote(capabilities: QTPlaybackCapabilities, account: QTAccountKind) -> String? {
        guard !capabilities.isSuperset(of: [.gapless, .crossfade, .equalizer]) else { return nil }
        return account == .free
            ? QTLoc.tr("Free accounts play through YouTube’s own player, which doesn’t support these.", table: .desktop)
            : QTLoc.tr("YouTube’s player, which plays your music for now, doesn’t support these.", table: .desktop)
    }

    private func crossfadeLabel(_ seconds: Double) -> String {
        seconds < 1 ? QTLoc.tr("Off") : Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .abbreviated).locale(QTLoc.locale))
    }

    static func name(_ preset: QTEqualizerPreset) -> String {
        switch preset {
        case .off: QTLoc.tr("Off")
        case .acoustic: QTLoc.tr("Acoustic", table: .desktop)
        case .bassBooster: QTLoc.tr("Bass Booster", table: .desktop)
        case .electronic: QTLoc.tr("Electronic", table: .desktop)
        case .loudness: QTLoc.tr("Loudness", table: .desktop)
        case .lounge: QTLoc.tr("Lounge", table: .desktop)
        case .piano: QTLoc.tr("Piano", table: .desktop)
        case .rnb: QTLoc.tr("R&B", table: .desktop)
        case .spokenWord: QTLoc.tr("Spoken Word", table: .desktop)
        case .trebleBooster: QTLoc.tr("Treble Booster", table: .desktop)
        case .vocalBooster: QTLoc.tr("Vocal Booster", table: .desktop)
        }
    }
}

// MARK: - Lyrics

struct QTLyricsSettings: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = model.settings
        let target = model.resolvedTranslationLanguage
        let ai = QTAppleIntelligence.status(for: target)
        Form {
            Section {
                Picker(QTLoc.tr("Lyrics translation"), selection: Binding(get: { model.lyricsTranslation }, set: { model.lyricsTranslation = $0 })) {
                    Text(QTLoc.tr("Interface language")).tag(QTLyricsTranslationTarget.interfaceLanguage)
                    Text(QTLoc.tr("Off")).tag(QTLyricsTranslationTarget.off)
                    Divider()
                    ForEach(QTLyricsTranslationTarget.languages, id: \.self) { t in
                        Text(verbatim: QTLyricsTranslationTarget.nativeName(for: t.rawValue)).tag(t)
                    }
                }
                Toggle(isOn: Binding(get: { ai.isAvailable && store.settings.translateWithAppleIntelligence },
                                     set: { v in store.update { $0.translateWithAppleIntelligence = v } })) {
                    Text(QTLoc.tr("Translate lyrics with Apple Intelligence"))
                    if let reason = ai.reason {
                        Text(reason)
                    }
                }
                .disabled(!ai.isAvailable || target == nil)
                .accessibilityIdentifier("qt.settings.appleIntelligence")
            }
            Section {
                Toggle(QTLoc.tr("NetEase"), isOn: setting(store, \.unofficialLyricsSources.netease))
                Toggle(QTLoc.tr("Kugou"), isOn: setting(store, \.unofficialLyricsSources.kugou))
                Toggle(QTLoc.tr("QQ Music"), isOn: setting(store, \.unofficialLyricsSources.qq))
            } header: {
                Text(QTLoc.tr("Unofficial sources"))
            } footer: {
                Text(QTLoc.tr("Unofficial, may stop working", table: .lyrics))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            QTDesktopLyricsSettingsSection()
        }
        .formStyle(.grouped)
    }
}

struct QTDesktopLyricsSettingsSection: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = model.settings
        let prefs = store.settings.desktopLyrics
        Section(QTLoc.tr("Desktop Lyrics")) {
            Toggle(QTLoc.tr("Show on desktop", table: .desktop), isOn: Binding(get: { model.isDesktopLyricsShown },
                                                                             set: { model.isDesktopLyricsShown = $0 }))
                .help("\(QTLoc.tr("Desktop Lyrics"))  ⇧⌘L")
            Picker(QTLoc.tr("Font", table: .desktop), selection: setting(store, \.desktopLyrics.fontDesign)) {
                Text(QTLoc.tr("System", table: .desktop)).font(.system(.body, design: .default)).tag(QTLyricsFontDesign.standard)
                Text(QTLoc.tr("Rounded", table: .desktop)).font(.system(.body, design: .rounded)).tag(QTLyricsFontDesign.rounded)
                Text(QTLoc.tr("Serif", table: .desktop)).font(.system(.body, design: .serif)).tag(QTLyricsFontDesign.serif)
            }
            LabeledContent(QTLoc.tr("Size", table: .desktop)) {
                HStack(spacing: QTTheme.Spacing.s) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { prefs.fontSize },
                                          set: { v in store.update { $0.desktopLyrics.fontSize = (v / 2).rounded() * 2 } }),
                           in: QTDesktopLyricsPanel.sizeRange)
                        .frame(width: 180)
                        .accessibilityValue(QTLoc.tr("%lld pt", table: .desktop, Int(prefs.fontSize)))
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                    Text(QTLoc.tr("%lld pt", table: .desktop, Int(prefs.fontSize)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            Picker(QTLoc.tr("Lines", table: .desktop), selection: setting(store, \.desktopLyrics.lineCount)) {
                Text(QTLoc.tr("One", table: .desktop)).tag(1)
                Text(QTLoc.tr("Two", table: .desktop)).tag(2)
            }
            .pickerStyle(.segmented)
            LabeledContent(QTLoc.tr("Position", table: .desktop)) {
                HStack {
                    Button(QTLoc.tr("Reset", table: .desktop)) { QTDesktopCoordinator.shared.resetDesktopLyricsPosition() }
                    Button(QTLoc.tr(prefs.isLocked ? "Unlock to Move" : "Lock", table: .desktop)) {
                        QTDesktopCoordinator.shared.setDesktopLyricsLocked(!prefs.isLocked)
                    }
                }
            }
        }
    }
}

// MARK: - Advanced

struct QTAdvancedSettings: View {
    @Environment(QTAppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent(QTLoc.tr("Version", table: .desktop)) {
                    Text(verbatim: Self.version).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            #if DEBUG
            Section(QTLoc.tr("Developer", table: .desktop)) {
                Button(QTLoc.tr("Play an ad now")) { model.player.playSimulatedAd() }
                    .disabled(!model.player.canSimulateAd)
            }
            #endif
            Section {
                LabeledContent(QTLoc.tr("Reset all settings", table: .desktop)) {
                    Button(QTLoc.tr("Reset…", table: .desktop), role: .destructive) { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(QTLoc.tr("Reset all settings?", table: .desktop), isPresented: $confirmReset) {
            Button(QTLoc.tr("Reset", table: .desktop), role: .destructive) {
                QTInterfaceLanguageSync.write(.automatic)
                model.settings.update { $0 = QTSettings() }
                model.applyAppearance()
            }
        } message: {
            Text(QTLoc.tr("Your library and likes are not affected.", table: .desktop))
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
