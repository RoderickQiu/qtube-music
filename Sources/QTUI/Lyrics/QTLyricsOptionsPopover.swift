import QTCore
import SwiftUI

// Owner: builder "lyrics-ui". Signatures are the shared contract (docked panel header + Stage top bar).

/// The quiet lyrics-options icon button; opens `QTLyricsOptionsPopover` in a system popover.
public struct QTLyricsOptionsButton: View {
    private let overArt: Bool
    @State private var isPresented = false

    /// - Parameter overArt: true on the Stage (white glyph over artwork).
    public init(overArt: Bool = false) {
        self.overArt = overArt
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(QTLoc.tr("Lyrics options"), systemImage: QTIcon.lyrics.systemName)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(overArt ? QTTheme.Colors.onArtSecondary : QTTheme.Colors.secondaryLabel)
        .help(QTLoc.tr("Lyrics"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            QTLyricsOptionsPopover()
        }
        .accessibilityIdentifier("qt.lyricsOptionsButton")
    }
}

/// Lyrics options: source + timing kind, translation target, unofficial sources, timing offset, wrong lyrics.
/// Reads `QTAppModel` / `QTPlayerModel` from the environment.
public struct QTLyricsOptionsPopover: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player

    public init() {}

    public var body: some View {
        @Bindable var model = model
        let doc = player.lyrics
        Form {
            Section {
                Picker(QTLoc.tr("Translate to"), selection: $model.lyricsTranslation) {
                    Text(verbatim: "\(QTLoc.tr("Interface language")) · \(QTLyricsTranslationTarget.nativeName(for: QTLyricsTranslationTarget.interfaceLanguage.resolvedLanguage(interface: QTLoc.language) ?? "en"))")
                        .tag(QTLyricsTranslationTarget.interfaceLanguage)
                    Text(QTLoc.tr("Off")).tag(QTLyricsTranslationTarget.off)
                    Divider()
                    ForEach(QTLyricsTranslationTarget.languages, id: \.self) { t in
                        Text(verbatim: QTLyricsTranslationTarget.nativeName(for: t.rawValue)).tag(t)
                    }
                }
                Toggle(QTLoc.tr("Unofficial sources"), isOn: Binding(
                    get: { model.settings.settings.unofficialLyricsSources.anyEnabled },
                    set: { on in model.settings.update { $0.unofficialLyricsSources = .init(netease: on, kugou: on, qq: on) } }
                ))
                .help(QTLoc.tr("NetEase, Kugou and QQ Music — unofficial, may stop working"))
                LabeledContent(QTLoc.tr("Timing")) {
                    Stepper {
                        Text(verbatim: "\(QTFormat.signedOffset(doc?.offset ?? 0))s").monospacedDigit()
                    } onIncrement: {
                        player.nudgeLyricsOffset(by: 0.1)
                    } onDecrement: {
                        player.nudgeLyricsOffset(by: -0.1)
                    }
                    .disabled(doc == nil)
                }
            } header: {
                HStack {
                    Text(doc.map { QTLoc.tr($0.source.name) } ?? QTLoc.tr("No lyrics"))
                    Spacer()
                    if let doc {
                        Text(QTLoc.tr(doc.syncKind == .word ? "Word timing" : "Line timing"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
