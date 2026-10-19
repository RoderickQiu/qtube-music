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
            // Over art (the Stage is always dark) the popover stays dark even under a light app theme.
            QTLyricsOptionsPopover()
                .preferredColorScheme(overArt ? .dark : nil)
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

/// Lyrics options: source + timing kind of what's showing, translation target (+ engine / download consent /
/// same-language state), one "Unofficial sources" switch (per-provider switches live in Settings › Lyrics), timing
/// offset, "Wrong lyrics? / Other versions (n)".
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
        let resolved = model.resolvedLyrics
        let doc = resolved.document
        let status = resolved.translationStatus
        VStack(alignment: .leading, spacing: 0) {
            header(doc)
            Form {
                translationSection(status)
                lyricsSection(doc)
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
            // Opening the options looks again at what may have changed meanwhile: a language model installed,
            // Apple Intelligence ready, the sources reachable again.
            center.recheck(center.resolve(player.lyrics, target: model.resolvedTranslationLanguage).machineKey)
            model.lyricsSession?.retryIfUnreachable()
        }
        .accessibilityIdentifier("qt.lyrics.optionsPopover")
    }

    // MARK: Header — source + timing kind

    private func header(_ doc: QTLyricsDocument?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(doc.map { QTLoc.tr($0.source.name) } ?? emptyTitle)
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

    /// "No lyrics", or "Offline" while the sources can't be reached (the lookup retries on reconnect).
    private var emptyTitle: String {
        guard let session = model.lyricsSession, session.phase == .unreachable else { return QTLoc.tr("No lyrics") }
        return session.isNetworkAvailable ? QTLoc.tr("Can’t reach lyrics", table: .lyrics) : QTLoc.tr("Offline", table: .lyrics)
    }

    // MARK: Translation

    @ViewBuilder
    private func translationSection(_ status: QTLyricsTranslationStatus) -> some View {
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
            translationStatus(status)
        }
    }

    @ViewBuilder
    private func translationStatus(_ status: QTLyricsTranslationStatus) -> some View {
        Group {
            switch status {
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
                    if let key = center.resolve(player.lyrics, target: model.resolvedTranslationLanguage).machineKey {
                        center.requestDownload(key)
                    }
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

    // MARK: Sources, timing, versions

    private func lyricsSection(_ doc: QTLyricsDocument?) -> some View {
        Section {
            Toggle(QTLoc.tr("Unofficial sources"), isOn: unofficialSources)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(QTLoc.tr("NetEase, Kugou and QQ Music — unofficial, may stop working"))
                .accessibilityIdentifier("qt.lyrics.unofficialSources")
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

    /// One switch for NetEase, Kugou and QQ Music: on when any is enabled; turning it on enables all three (fine
    /// tuning lives in Settings › Lyrics), off disables all.
    private var unofficialSources: Binding<Bool> {
        Binding(
            get: { model.settings.settings.unofficialLyricsSources.anyEnabled },
            set: { on in
                model.settings.update {
                    $0.unofficialLyricsSources = on ? QTUnofficialLyricsSources(netease: true, kugou: true, qq: true) : QTUnofficialLyricsSources()
                }
            })
    }

    private func versionsMenu(_ doc: QTLyricsDocument?) -> some View {
        let id = player.nowPlaying?.videoId ?? ""
        let all = versions.versions[id] ?? []
        let others = versions.others(for: id)
        let pinned = isPinned(id)
        return Menu {
            if !all.isEmpty {
                // "Automatic" is the resolver's own pick; choosing it drops a pinned version for this track.
                Toggle(isOn: Binding(get: { !pinned }, set: { on in if on { unpin(id) } })) {
                    Text(QTLoc.tr("Automatic", table: .lyrics))
                }
                .accessibilityIdentifier("qt.lyrics.versionAutomatic")
                Divider()
                ForEach(all) { v in
                    Toggle(isOn: Binding(get: { pinned && versions.selected[id] == v.id }, set: { _ in versions.pin(v, for: id) })) {
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

    /// The user chose a version for this track (the session's persisted pin; the store's when there is no session).
    private func isPinned(_ videoId: String) -> Bool {
        if let session = model.lyricsSession, session.engine == .live, session.track?.videoId == videoId { return session.isPinned }
        return versions.pinned[videoId] != nil
    }

    private func unpin(_ videoId: String) {
        versions.unpin(videoId)
        if let session = model.lyricsSession, session.track?.videoId == videoId { session.unpin() }
    }

    private func versionTitle(_ v: QTLyricsVersion) -> String {
        var parts = [QTLoc.tr(v.source.name), QTLoc.tr(v.syncKind == .word ? "Word timing" : "Line timing")]
        if let tl = v.translationLanguage { parts.append(QTLyricsTranslationTarget.nativeName(for: tl)) }
        return parts.joined(separator: " · ")
    }
}
