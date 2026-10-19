import QTCore
import SwiftUI

// Owner: builder "lyrics-ui". Signatures are the shared contract (docked panel header + Stage top bar).

/// The quiet lyrics-options icon button; opens `QTLyricsOptionsPopover` in a system popover.
public struct QTLyricsOptionsButton: View {
    private let overArt: Bool
    @Environment(QTAppModel.self) private var model: QTAppModel?
    @State private var isPresented = false
    @State private var didApplyLaunchOption = false

    /// - Parameter overArt: true on the Stage (white glyph over artwork).
    public init(overArt: Bool = false) {
        self.overArt = overArt
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(QTLoc.tr("Lyrics options"), systemImage: isPresented ? "quote.bubble.fill" : QTIcon.lyrics.systemName)
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(overArt ? QTTheme.Colors.onArtSecondary : QTTheme.Colors.secondaryLabel)
        .help(QTLoc.tr("Lyrics options"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            QTLyricsOptionsPopover()
        }
        .accessibilityIdentifier(overArt ? "qt.lyrics.optionsButton.stage" : "qt.lyrics.optionsButton.panel")
        .task {
            // `-qt.lyrics.options YES` opens the popover of the surface on screen (screenshots).
            guard !didApplyLaunchOption, let model, model.launch.bool("qt.lyrics.options") == true else { return }
            didApplyLaunchOption = true
            guard (model.surface == .stage) == overArt else { return }
            let hold = QTReadiness.shared.hold("lyrics options popover")
            try? await Task.sleep(for: .milliseconds(700))
            isPresented = true
            try? await Task.sleep(for: .milliseconds(500))
            QTReadiness.shared.release(hold)
        }
    }
}

/// Lyrics options: source + timing kind, translation target (+ engine / download consent / same-language state),
/// unofficial sources, timing offset, "Wrong lyrics? / Other versions (n)".
/// Reads `QTAppModel` / `QTPlayerModel` from the environment.
public struct QTLyricsOptionsPopover: View {
    @Environment(QTAppModel.self) private var model
    @Environment(QTPlayerModel.self) private var player
    private var center: QTLyricsTranslationCenter { .shared }
    private var versions: QTLyricsVersionStore { .shared }
    /// Grouped forms scroll; inside a popover the form is sized to its content.
    @State private var formHeight: CGFloat = 360

    public init() {}

    public var body: some View {
        let doc = player.lyrics
        let resolution = center.resolve(doc, target: model.resolvedTranslationLanguage)
        VStack(alignment: .leading, spacing: 0) {
            header(doc)
            Form {
                translationSection(resolution)
                sourcesSection
                timingSection(doc)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, h in
                if h > 0, abs(h - formHeight) > 0.5 { formHeight = h }
            }
            .frame(height: formHeight)
        }
        .frame(width: 360)
        .task(id: player.nowPlaying?.videoId) {
            if model.launch.bool("qt.lyrics.demoVersions") == true, let t = player.nowPlaying, let doc = player.lyrics {
                versions.installDemoVersions(for: t, document: doc)
            }
        }
        .accessibilityIdentifier("qt.lyrics.optionsPopover")
    }

    // MARK: Header — source + timing kind

    private func header(_ doc: QTLyricsDocument?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(doc.map { QTLoc.tr($0.source.name) } ?? QTLoc.tr("No lyrics"))
                .font(.headline)
            if let doc, doc.confidence < 0.8 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .imageScale(.small)
                    .help(QTLoc.tr("Possible mismatch", table: .lyrics))
                    .accessibilityLabel(QTLoc.tr("Possible mismatch", table: .lyrics))
            }
            Spacer(minLength: 8)
            if let doc {
                Text(QTLoc.tr(doc.syncKind == .word ? "Word timing" : "Line timing"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Translation

    @ViewBuilder
    private func translationSection(_ resolution: QTLyricsTranslationResolution) -> some View {
        @Bindable var model = model
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
            .pickerStyle(.menu)
            .accessibilityIdentifier("qt.lyrics.translationPicker")
        } footer: {
            translationStatus(resolution)
        }
    }

    @ViewBuilder
    private func translationStatus(_ resolution: QTLyricsTranslationResolution) -> some View {
        Group {
            switch resolution.status {
            case .noLyrics, .off:
                EmptyView()
            case .sameLanguage(let code):
                Text(QTLoc.tr("Song is already in %@", QTLyricsTranslationTarget.nativeName(for: code)))
            case .provider(let name):
                Text(QTLoc.tr("Translation by %@", QTLoc.tr(name)))
            case .translating:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(QTLoc.tr("Translating…"))
                }
            case .needsDownload(let code):
                Button {
                    if let key = resolution.machineKey { center.requestDownload(key) }
                } label: {
                    Label(QTLoc.tr("Download %@ for offline translation", QTLyricsTranslationTarget.nativeName(for: code)),
                          systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
                .accessibilityIdentifier("qt.lyrics.downloadTranslation")
            case .unavailable:
                Text(QTLoc.tr("Translation unavailable on this device"))
            case .onDevice:
                Label(QTLoc.tr("On-device translation"), systemImage: "lock.laptopcomputer")
            case .appleIntelligence:
                Label(QTLoc.tr("Apple Intelligence", table: .lyrics), systemImage: "apple.intelligence")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("qt.lyrics.translationStatus")
    }

    // MARK: Unofficial sources

    private var sourcesSection: some View {
        Section {
            sourceToggle(QTLoc.tr("NetEase"), \.netease)
            sourceToggle(QTLoc.tr("Kugou"), \.kugou)
            sourceToggle(QTLoc.tr("QQ Music"), \.qq)
        } header: {
            Text(QTLoc.tr("Unofficial sources"))
        } footer: {
            Text(QTLoc.tr("Unofficial, may stop working", table: .lyrics))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func sourceToggle(_ title: String, _ keyPath: WritableKeyPath<QTUnofficialLyricsSources, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.settings.settings.unofficialLyricsSources[keyPath: keyPath] },
            set: { on in model.settings.update { $0.unofficialLyricsSources[keyPath: keyPath] = on } }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(QTLoc.tr("NetEase, Kugou and QQ Music — unofficial, may stop working"))
    }

    // MARK: Timing + versions

    private func timingSection(_ doc: QTLyricsDocument?) -> some View {
        Section {
            LabeledContent(QTLoc.tr("Timing")) {
                HStack(spacing: 6) {
                    Text(QTLoc.tr("%@ s", table: .lyrics, QTFormat.signedOffset(doc?.offset ?? 0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Stepper {
                        Text(QTLoc.tr("Timing"))
                    } onIncrement: {
                        QTLyricsTiming.nudge(model, by: QTLyricsTiming.step)
                    } onDecrement: {
                        QTLyricsTiming.nudge(model, by: -QTLyricsTiming.step)
                    }
                    .labelsHidden()
                }
                .disabled(doc == nil)
            }
            .help("\(QTLoc.tr("Lyrics Earlier"))  ⌥↑   ·   \(QTLoc.tr("Lyrics Later"))  ⌥↓")
            .accessibilityIdentifier("qt.lyrics.timingStepper")
            LabeledContent(QTLoc.tr("Wrong lyrics?", table: .lyrics)) {
                versionsMenu(doc)
            }
        }
    }

    private func versionsMenu(_ doc: QTLyricsDocument?) -> some View {
        let id = player.nowPlaying?.videoId ?? ""
        let all = versions.versions[id] ?? []
        let others = versions.others(for: id)
        return Menu {
            if !all.isEmpty {
                ForEach(all) { v in
                    Toggle(isOn: Binding(get: { versions.selected[id] == v.id }, set: { _ in versions.pin(v, for: id) })) {
                        Text(verbatim: versionTitle(v))
                    }
                }
                Divider()
            }
            Button(QTLoc.tr("Report Wrong Lyrics", table: .lyrics)) {
                versions.reportWrong(id)
                model.showToast(QTLoc.tr("Reported"))
            }
            .disabled(doc == nil)
        } label: {
            Text(others.isEmpty ? QTLoc.tr("Other versions") : QTLoc.tr("Other versions (%lld)", table: .lyrics, others.count))
        }
        .fixedSize()
        .accessibilityIdentifier("qt.lyrics.versionsMenu")
    }

    private func versionTitle(_ v: QTLyricsVersion) -> String {
        var parts = [QTLoc.tr(v.source.name), QTLoc.tr(v.syncKind == .word ? "Word timing" : "Line timing")]
        if let tl = v.translationLanguage { parts.append(QTLyricsTranslationTarget.nativeName(for: tl)) }
        return parts.joined(separator: " · ")
    }
}
