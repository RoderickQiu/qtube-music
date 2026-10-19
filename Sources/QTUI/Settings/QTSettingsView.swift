import QTCore
import SwiftUI

// Owner: builder "desktop". Native Settings window: toolbar tabs + grouped Forms (General, Playback, Lyrics,
// Account, Advanced). Every control writes through `QTSettingsStore`, so changes apply live (language too).

public enum QTSettingsTab: String, CaseIterable, Hashable, Sendable {
    case general, playback, lyrics, account, advanced
}

public struct QTSettingsView: View {
    @Environment(QTAppModel.self) private var model
    @State private var tab: QTSettingsTab = .general

    public init() {}

    public var body: some View {
        // Each tab has its own content height, so the window resizes to fit it instead of scrolling or
        // leaving dead space.
        TabView(selection: $tab) {
            Tab(QTLoc.tr("General"), systemImage: "gearshape", value: QTSettingsTab.general) { QTGeneralSettings().qtSettingsFitsContent(maxHeight: 340) }
            Tab(QTLoc.tr("Playback", table: .desktop), systemImage: "play.circle", value: QTSettingsTab.playback) { QTPlaybackSettings().qtSettingsFitsContent(maxHeight: 350) }
            Tab(QTLoc.tr("Lyrics"), systemImage: QTIcon.lyrics.systemName, value: QTSettingsTab.lyrics) { QTLyricsSettings().qtSettingsFitsContent(maxHeight: 650) }
            Tab(QTLoc.tr("Account"), systemImage: "person.crop.circle", value: QTSettingsTab.account) { QTAccountSettings().qtSettingsFitsContent(maxHeight: 220) }
            Tab(QTLoc.tr("Advanced", table: .desktop), systemImage: "gearshape.2", value: QTSettingsTab.advanced) { QTAdvancedSettings().qtSettingsFitsContent(maxHeight: 310) }
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

/// `Binding` into the settings store.
@MainActor
private func setting<T>(_ store: QTSettingsStore, _ keyPath: WritableKeyPath<QTSettings, T>) -> Binding<T> {
    Binding(get: { store.settings[keyPath: keyPath] }, set: { v in store.update { $0[keyPath: keyPath] = v } })
}

// MARK: - General

struct QTGeneralSettings: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        let store = model.settings
        Form {
            Section {
                Picker(QTLoc.tr("Interface language"), selection: setting(store, \.interfaceLanguage)) {
                    Text(QTLoc.tr("Auto")).tag(QTInterfaceLanguage.automatic)
                    Divider()
                    Text(verbatim: "English").tag(QTInterfaceLanguage.enUS)
                    Text(verbatim: "简体中文").tag(QTInterfaceLanguage.zhCN)
                }
                .accessibilityIdentifier("qt.settings.interfaceLanguage")
                Picker(QTLoc.tr("Theme"), selection: Binding(get: { model.theme }, set: { model.theme = $0 })) {
                    Text(QTLoc.tr("Auto")).tag(QTThemePreference.automatic)
                    Text(QTLoc.tr("Light")).tag(QTThemePreference.light)
                    Text(QTLoc.tr("Dark")).tag(QTThemePreference.dark)
                }
                .pickerStyle(.segmented)
            }
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
        let isFree = model.account == .free
        Form {
            Section {
                Toggle(QTLoc.tr("Prefer videos when available"), isOn: setting(store, \.preferVideos))
            }
            Section {
                Toggle(QTLoc.tr("Gapless playback", table: .desktop), isOn: setting(store, \.playbackEffects.gapless))
                LabeledContent(QTLoc.tr("Crossfade", table: .desktop)) {
                    HStack(spacing: QTTheme.Spacing.s) {
                        Slider(value: setting(store, \.playbackEffects.crossfadeSeconds), in: 0...12, step: 1)
                            .frame(width: 200)
                            .accessibilityValue(crossfadeLabel(store.settings.playbackEffects.crossfadeSeconds))
                        Text(crossfadeLabel(store.settings.playbackEffects.crossfadeSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                }
                Picker(QTLoc.tr("Equalizer", table: .desktop), selection: setting(store, \.playbackEffects.equalizer)) {
                    ForEach(QTEqualizerPreset.allCases, id: \.self) { p in
                        Text(Self.name(p)).tag(p)
                        if p == .off { Divider() }
                    }
                }
            } header: {
                Text(QTLoc.tr("Premium engine"))
            } footer: {
                if isFree {
                    Text(QTLoc.tr("Free accounts play through YouTube’s own player, which doesn’t support these.", table: .desktop))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isFree)
        }
        .formStyle(.grouped)
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
                Text(QTLoc.tr("NetEase, Kugou and QQ Music — unofficial, may stop working"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

// MARK: - Account

struct QTAccountSettings: View {
    @Environment(QTAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                HStack(spacing: QTTheme.Spacing.s) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 36))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(QTLoc.tr("Not signed in", table: .desktop)).font(.headline)
                        Text(verbatim: "YouTube Music").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Google sign-in lands with QTAuth (M3).
                    Button(QTLoc.tr("Sign In…", table: .desktop)) {}
                        .disabled(true)
                }
                .padding(.vertical, 4)
            }
            Section {
                #if DEBUG
                Picker(QTLoc.tr("Playback engine", table: .desktop), selection: Binding(get: { model.account }, set: { model.account = $0 })) {
                    Text(QTLoc.tr("Premium engine")).tag(QTAccountKind.premium)
                    Text(QTLoc.tr("Free (ads)")).tag(QTAccountKind.free)
                }
                #else
                LabeledContent(QTLoc.tr("Playback engine", table: .desktop)) {
                    Text(model.account == .premium ? QTLoc.tr("Premium engine") : QTLoc.tr("Free (ads)"))
                }
                #endif
            }
        }
        .formStyle(.grouped)
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

// MARK: - Content-sized tabs

/// Sizes a grouped Form tab to its content (up to `maxHeight`, then it scrolls), so the Settings window grows and
/// shrinks per tab like System Settings panes instead of leaving empty space under short forms.
private struct QTSettingsContentHeight: ViewModifier {
    let maxHeight: CGFloat
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, h in
                if h > 0, abs((contentHeight ?? 0) - h - 8) > 0.5 { contentHeight = h + 8 }
            }
            .frame(height: min(maxHeight, contentHeight ?? maxHeight))
            // The tab area can be a few points taller than the form; let the window background show through
            // so there's no seam between them.
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func qtSettingsFitsContent(maxHeight: CGFloat) -> some View {
        modifier(QTSettingsContentHeight(maxHeight: maxHeight))
    }
}
