import Foundation
import os.log

/// The bundled high-frequency word set used by the vocabulary gate's
/// **common-word guard** (`VocabularyGate`). A custom vocabulary correction is
/// never allowed to silently overwrite a word in this set — that is what stops
/// "name" → "Jamy" and "cloud" → "Claude" on confident, correct words.
///
/// **Per-language (macOS, design §6 Q3).** The iPhone shipped a single
/// English-only `CommonWords` enum. On macOS the set is parameterized by the
/// resolved transcription language: `CommonWords(forLanguage: "en")` loads
/// `Resources/common-words-en.txt`. A language whose list is not bundled yet
/// resolves to `.empty`, and `isCommon(_:)` returns `false` for every word — the
/// gate then simply skips the common-word brake for that language (confidence +
/// plausibility + earned-override still protect). It **never crashes** on a
/// missing list.
///
/// Asset (English): `Resources/common-words-en.txt` — the top ~24k English words
/// by frequency, **with popular given names removed** so a name a user adds to
/// vocab (Jamie, John, Sarah…) is NOT treated as an untouchable common word and
/// can be learned/applied. This is a *universal* signal (works for every user,
/// no per-term computation).
///
/// Loaded lazily and cached per language code into a `Set` for O(1) membership.
struct CommonWords: Sendable {
    /// Lowercased high-frequency word set. Empty when the asset is missing for
    /// the requested language (the gate then degrades to confidence/margin/
    /// plausibility-only for that language — still safe).
    let set: Set<String>

    /// A set that treats nothing as common. Used for languages with no bundled
    /// list, so the gate's common-word guard is a clean no-op rather than a crash.
    static let empty = CommonWords(set: [])

    private init(set: Set<String>) {
        self.set = set
    }

    func isCommon(_ word: String) -> Bool {
        set.contains(word.lowercased())
    }

    // MARK: - Per-language loading + cache

    private static let log = Logger(subsystem: "com.jot.Jot", category: "VocabularyGate")
    private static let cacheLock = NSLock()
    private static var cache: [String: CommonWords] = [:]

    /// The common-word set for a resolved language code (e.g. `"en"`). Looks up
    /// `common-words-<code>.txt` in the app bundle. Cached after first load.
    /// A missing list returns `.empty` (guard no-ops for that language).
    static func forLanguage(_ code: String) -> CommonWords {
        let key = code.lowercased()
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let loaded = load(code: key)
        cacheLock.lock()
        cache[key] = loaded
        cacheLock.unlock()
        return loaded
    }

    /// Convenience for the `LanguageChoice`-driven call site. English maps to
    /// `"en"`; any other language whose list is not bundled yet falls through to
    /// `.empty`. `nil` (no language hint — tests / direct constructors) is
    /// treated as English, matching the pre-language-picker default.
    static func forLanguage(_ language: LanguageChoice?) -> CommonWords {
        guard let language else { return forLanguage("en") }
        return forLanguage(language.bcp47CommonWordsCode)
    }

    private static func load(code: String) -> CommonWords {
        guard
            let url = Bundle.main.url(forResource: "common-words-\(code)", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            log.error(
                "common-words-\(code, privacy: .public).txt NOT found in bundle — common-word guard DISABLED for this language"
            )
            return .empty
        }
        let set = Set(text.split(separator: "\n").map { String($0).lowercased() })
        log.info("common-words[\(code, privacy: .public)] loaded: \(set.count, privacy: .public) words")
        return CommonWords(set: set)
    }
}

extension LanguageChoice {
    /// The short code used to name this language's `common-words-<code>.txt`
    /// asset. Mirrors the ISO-639 code used elsewhere in `LanguageChoice`. Only
    /// English (`en`) ships a list today; the rest resolve to a missing list →
    /// `CommonWords.empty` (guard skipped) until per-language lists are bundled.
    var bcp47CommonWordsCode: String {
        switch self {
        case .english:    return "en"
        case .japanese:   return "ja"
        case .spanish:    return "es"
        case .french:     return "fr"
        case .german:     return "de"
        case .italian:    return "it"
        case .portuguese: return "pt"
        case .romanian:   return "ro"
        case .polish:     return "pl"
        case .czech:      return "cs"
        case .slovak:     return "sk"
        case .slovenian:  return "sl"
        case .croatian:   return "hr"
        case .bosnian:    return "bs"
        case .russian:    return "ru"
        case .ukrainian:  return "uk"
        case .belarusian: return "be"
        case .bulgarian:  return "bg"
        case .serbian:    return "sr"
        case .danish:     return "da"
        case .dutch:      return "nl"
        case .finnish:    return "fi"
        case .greek:      return "el"
        case .hungarian:  return "hu"
        case .swedish:    return "sv"
        }
    }
}
