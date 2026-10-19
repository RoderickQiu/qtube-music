import QTCore
import SwiftUI

// Owner: builder "desktop". Native Settings window (tabs + grouped Forms).

public struct QTSettingsView: View {
    @Environment(QTAppModel.self) private var model

    public init() {}

    public var body: some View {
        TabView {
            Tab(QTLoc.tr("General"), systemImage: "gearshape") { general }
            Tab(QTLoc.tr("Lyrics"), systemImage: QTIcon.lyrics.systemName) { lyrics }
        }
        .frame(width: 520)
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

    private var general: some View {
        let store = model.settings
        return Form {
            Picker(QTLoc.tr("Interface language"), selection: Binding(get: { store.settings.interfaceLanguage },
                                                                         set: { v in store.update { $0.interfaceLanguage = v } })) {
                Text(QTLoc.tr("Auto")).tag(QTInterfaceLanguage.automatic)
                Text(verbatim: "English").tag(QTInterfaceLanguage.enUS)
                Text(verbatim: "简体中文").tag(QTInterfaceLanguage.zhCN)
            }
            Picker(QTLoc.tr("Theme"), selection: Binding(get: { model.theme }, set: { model.theme = $0 })) {
                Text(QTLoc.tr("Auto")).tag(QTThemePreference.automatic)
                Text(QTLoc.tr("Light")).tag(QTThemePreference.light)
                Text(QTLoc.tr("Dark")).tag(QTThemePreference.dark)
            }
            Toggle(QTLoc.tr("Prefer videos when available"), isOn: Binding(get: { store.settings.preferVideos },
                                                                           set: { v in store.update { $0.preferVideos = v } }))
            Toggle(QTLoc.tr("Keep playing when the window is closed"), isOn: Binding(get: { store.settings.closeWindowKeepsPlaying },
                                                                                    set: { v in store.update { $0.closeWindowKeepsPlaying = v } }))
        }
        .formStyle(.grouped)
    }

    private var lyrics: some View {
        let store = model.settings
        return Form {
            Section {
                Picker(QTLoc.tr("Lyrics translation"), selection: Binding(get: { model.lyricsTranslation }, set: { model.lyricsTranslation = $0 })) {
                    Text(QTLoc.tr("Interface language")).tag(QTLyricsTranslationTarget.interfaceLanguage)
                    Text(QTLoc.tr("Off")).tag(QTLyricsTranslationTarget.off)
                    Divider()
                    ForEach(QTLyricsTranslationTarget.languages, id: \.self) { t in
                        Text(verbatim: QTLyricsTranslationTarget.nativeName(for: t.rawValue)).tag(t)
                    }
                }
                Toggle(QTLoc.tr("Translate lyrics with Apple Intelligence"),
                       isOn: Binding(get: { store.settings.translateWithAppleIntelligence },
                                     set: { v in store.update { $0.translateWithAppleIntelligence = v } }))
            }
            Section {
                Toggle(QTLoc.tr("NetEase"), isOn: Binding(get: { store.settings.unofficialLyricsSources.netease },
                                                          set: { v in store.update { $0.unofficialLyricsSources.netease = v } }))
                Toggle(QTLoc.tr("Kugou"), isOn: Binding(get: { store.settings.unofficialLyricsSources.kugou },
                                                        set: { v in store.update { $0.unofficialLyricsSources.kugou = v } }))
                Toggle(QTLoc.tr("QQ Music"), isOn: Binding(get: { store.settings.unofficialLyricsSources.qq },
                                                           set: { v in store.update { $0.unofficialLyricsSources.qq = v } }))
            } header: {
                Text(QTLoc.tr("Unofficial sources"))
            } footer: {
                Text(QTLoc.tr("NetEase, Kugou and QQ Music — unofficial, may stop working"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
