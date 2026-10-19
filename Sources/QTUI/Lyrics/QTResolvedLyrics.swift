import Foundation
import QTCore
import SwiftUI

// Owner: builder "lyrics-ui". The one answer to "which lyrics and which translation line does every surface show".
// Panel, Stage (rail, Art only line, video overlay), mini player, menu bar popover and desktop lyrics all read
// `QTAppModel.resolvedLyrics`; none of them looks at `QTLyricsLine.translation` directly, so a provider lane in
// another language (NetEase's Chinese under an English target) can never leak onto one surface only.
//
// Today the document is `QTPlayerModel.lyrics` and the lane comes from `QTLyricsTranslationCenter.resolve` (the
// provider's lane when it matches the target, else on-device translation). When the lyrics service grows its own
// session object, only the body of `resolvedLyrics` changes.

/// Lyrics as shown: the document plus the translation lane resolved for the current target language.
public struct QTResolvedLyrics: Equatable, Sendable {
    public var document: QTLyricsDocument?
    /// One entry per line (nil = no translation for that line); nil = no translation lane at all.
    public var translations: [String?]?
    /// BCP-47 language of `translations`.
    public var translationLanguage: String?
    /// What the options popover reports about the lane.
    public var translationStatus: QTLyricsTranslationStatus

    public static let none = QTResolvedLyrics(document: nil, translations: nil, translationLanguage: nil, translationStatus: .noLyrics)

    /// The resolved translation of line `index`, if any.
    public func translation(forLine index: Int) -> String? {
        guard let translations, translations.indices.contains(index), let t = translations[index], !t.isEmpty else { return nil }
        return t
    }

    /// The line being sung at a playback time, with its resolved translation.
    public func currentLine(atPlaybackTime t: TimeInterval) -> (index: Int, line: QTLyricsLine, translation: String?)? {
        guard let document, let i = document.lineIndex(atPlaybackTime: t), document.lines.indices.contains(i) else { return nil }
        return (i, document.lines[i], translation(forLine: i))
    }

    /// True before the first synced line (the intro) and for documents that are only an "instrumental" marker.
    public func isInstrumental(atPlaybackTime t: TimeInterval) -> Bool {
        guard let document, !document.lines.isEmpty else { return false }
        if QTLyricsRowBuilder.isInstrumental(document) { return true }
        guard document.syncKind != .plain else { return false }
        return document.lineIndex(atPlaybackTime: t) == nil
    }

    var lanes: QTLyricsLanes { QTLyricsLanes(translations: translations, translationLanguage: translationLanguage) }
}

extension QTResolvedLyrics {
    init(document: QTLyricsDocument?, resolution: QTLyricsTranslationResolution) {
        self.init(document: document, translations: resolution.lanes.translations,
                  translationLanguage: resolution.lanes.translationLanguage, translationStatus: resolution.status)
    }
}

public extension QTAppModel {
    /// The lyrics every surface shows (document + translation lane for `resolvedTranslationLanguage`). Pure read,
    /// safe from view bodies; observation tracks the document, the target and on-device translation progress.
    var resolvedLyrics: QTResolvedLyrics {
        let doc = player.lyrics
        return QTResolvedLyrics(document: doc, resolution: QTLyricsTranslationCenter.shared.resolve(doc, target: resolvedTranslationLanguage))
    }
}

public extension View {
    /// Hosts the on-device translation session for the current lyrics, for surfaces that show a translation line
    /// without a `QTLyricsView` (Stage Art only / video overlay, menu bar popover). Several hosts are fine: the
    /// translation center runs one job per document and language.
    func qtHostsLyricsTranslation(_ isEnabled: Bool = true) -> some View {
        modifier(QTResolvedLyricsTranslationHost(isEnabled: isEnabled))
    }
}

private struct QTResolvedLyricsTranslationHost: ViewModifier {
    let isEnabled: Bool
    @Environment(QTAppModel.self) private var model: QTAppModel?

    func body(content: Content) -> some View {
        let doc = model?.player.lyrics
        return content.modifier(QTLyricsTranslationHost(document: doc, key: key(doc)))
    }

    private func key(_ doc: QTLyricsDocument?) -> QTLyricsTranslationCenter.Key? {
        guard isEnabled, let model, let target = model.resolvedTranslationLanguage else { return nil }
        return QTLyricsTranslationCenter.shared.resolve(doc, target: target).machineKey
    }
}
