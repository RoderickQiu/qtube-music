import Foundation
import QTCore
import QTPlayback
#if canImport(FoundationModels)
import FoundationModels
#endif

// Owner: builder "desktop". Whether "Translate lyrics with Apple Intelligence" can be offered, and why not.
// Foundation Models is macOS 26+; Swift weak-links the framework (LC_LOAD_WEAK_DYLIB, checked with otool) so macOS 15 still launches.

enum QTAppleIntelligence {
    enum Status: Equatable {
        case available
        case requiresNewerMacOS
        case deviceNotEligible
        case notEnabled
        case modelNotReady
        case languageUnsupported(String)
        case unavailable

        var isAvailable: Bool { self == .available }

        /// One line shown under the disabled toggle.
        var reason: String? {
            switch self {
            case .available: nil
            case .requiresNewerMacOS: QTLoc.tr("Requires macOS 26 or later", table: .desktop)
            case .deviceNotEligible: QTLoc.tr("This Mac doesn’t support Apple Intelligence", table: .desktop)
            case .notEnabled: QTLoc.tr("Turn on Apple Intelligence in System Settings", table: .desktop)
            case .modelNotReady: QTLoc.tr("Apple Intelligence is still getting ready", table: .desktop)
            case .languageUnsupported(let code):
                QTLoc.tr("Apple Intelligence can’t translate into %@", table: .desktop, QTLyricsTranslationTarget.nativeName(for: code))
            case .unavailable: QTLoc.tr("Apple Intelligence isn’t available right now", table: .desktop)
            }
        }
    }

    /// - Parameter language: the translation target (BCP-47), nil when translation is off.
    @MainActor
    static func status(for language: String?) -> Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                if let language, !model.supportsLocale(Locale(identifier: language)) { return .languageUnsupported(language) }
                return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .unavailable
            }
        }
        return .requiresNewerMacOS
        #else
        return .requiresNewerMacOS
        #endif
    }
}

extension QTPlayerModel {
    /// Debug: start the simulated engine's ad (Settings › Advanced › Developer).
    var canSimulateAd: Bool { engine is QTSimulatedPlaybackEngine }

    func playSimulatedAd() {
        (engine as? QTSimulatedPlaybackEngine)?.playAd()
    }
}
