import FluidAudio
import Foundation

/// The user-facing transcription **language** — the single control that
/// replaces the model picker in the Setup Wizard and Settings → Transcription
/// (`docs/language-based-model-selection/design.md`). The user picks a
/// language; Jot resolves the model + the FluidAudio script hint automatically.
///
/// ## Mapping (design §3)
/// - **English → Parakeet v2** (`.tdt_0_6b_v2_en_streaming`). v2 is the
///   product-owner-chosen best-English-accuracy default. It is monolingual,
///   so it takes **no** language hint.
/// - **European languages → Parakeet v3** (`.tdt_0_6b_v3_eou_streaming`) plus
///   the FluidAudio `Language` hint where one exists. The hint is the v3-only
///   Latin/Cyrillic *script* filter (design §2.2) — it is NOT per-language
///   precision (Polish vs Czech are indistinguishable at the filter level).
/// - **Japanese → Parakeet JA** (`.tdt_0_6b_ja`). A separate model with no
///   live preview (`supportsStreaming == false`); the hint is ignored.
///
/// ## English is hardware-tiered; other languages are not
/// `modelID(tier:)` returns **Nemotron for English on capable hardware**
/// (≥ M2 Pro AND ≥ 16 GB — premium true-streaming), and **v2 for English**
/// elsewhere. European (v3) and Japanese (JA) are 0.6B batch models that run on
/// every Apple Silicon Mac, so they are tier-independent. Nemotron is reachable
/// ONLY for English on eligible Macs — never for any other language.
///
/// ## Surfaced language set (design §2.3)
/// We surface the union the v3 model supports. For each language we pass the
/// FluidAudio `Language` case **if one exists**, else `nil` (which falls back
/// to v3 auto-detect — today's behavior). FluidAudio 0.14.7's `Language` enum
/// exposes 19 cases; languages the model supports without a hint case (Danish,
/// Dutch, Finnish, Greek, Hungarian, Swedish, …) still transcribe — they just
/// don't get the script filter.
public enum LanguageChoice: String, CaseIterable, Sendable, Identifiable {
    // English — routed to Parakeet v2 (monolingual, no hint).
    case english

    // Japanese — separate model, no live preview.
    case japanese

    // Languages not covered by Parakeet v3 / the JA model, routed to the
    // Nemotron 3.5 Multilingual "multilingual" ship on ≥24 GB hardware (no
    // backend below the bar — `requiresNemotronMultilingual`). Mandarin is
    // spaceless CJK; Vietnamese is space-separated Latin-with-diacritics;
    // Arabic is RTL (Arabic script, but spaced); Korean is Hangul (spaced);
    // Turkish is Latin; Hindi is Devanagari.
    case mandarin
    case vietnamese
    case arabic
    case korean
    case turkish
    case hindi

    // European languages WITH a FluidAudio `Language` (script-filter) hint.
    // Latin script:
    case spanish
    case french
    case german
    case italian
    case portuguese
    case romanian
    case polish
    case czech
    case slovak
    case slovenian
    case croatian
    case bosnian
    // Cyrillic script:
    case russian
    case ukrainian
    case belarusian
    case bulgarian
    case serbian

    // European languages the v3 model supports but for which FluidAudio
    // 0.14.7 exposes NO `Language` hint case (design §2.3). They transcribe
    // via v3 auto-detect with no script filter.
    case danish
    case dutch
    case finnish
    case greek
    case hungarian
    case swedish
    // Latvian: v3-supported but the model's weakest European language
    // (~23% WER) and Nemotron's beta tier — surfaced as EXPERIMENTAL
    // (`isExperimental`). No FluidAudio hint case, so it auto-detects on v3.
    case latvian

    public var id: String { rawValue }

    /// English name + native endonym. Native == English where there is no
    /// distinct endonym in another script/spelling (English).
    private var names: (english: String, native: String) {
        switch self {
        case .english:    return ("English", "English")
        case .japanese:   return ("Japanese", "日本語")
        case .mandarin:   return ("Mandarin", "中文")
        case .vietnamese: return ("Vietnamese", "Tiếng Việt")
        case .arabic:     return ("Arabic", "العربية")
        case .korean:     return ("Korean", "한국어")
        case .turkish:    return ("Turkish", "Türkçe")
        case .hindi:      return ("Hindi", "हिन्दी")
        case .spanish:    return ("Spanish", "Español")
        case .french:     return ("French", "Français")
        case .german:     return ("German", "Deutsch")
        case .italian:    return ("Italian", "Italiano")
        case .portuguese: return ("Portuguese", "Português")
        case .romanian:   return ("Romanian", "Română")
        case .polish:     return ("Polish", "Polski")
        case .czech:      return ("Czech", "Čeština")
        case .slovak:     return ("Slovak", "Slovenčina")
        case .slovenian:  return ("Slovenian", "Slovenščina")
        case .croatian:   return ("Croatian", "Hrvatski")
        case .bosnian:    return ("Bosnian", "Bosanski")
        case .russian:    return ("Russian", "Русский")
        case .ukrainian:  return ("Ukrainian", "Українська")
        case .belarusian: return ("Belarusian", "Беларуская")
        case .bulgarian:  return ("Bulgarian", "Български")
        case .serbian:    return ("Serbian", "Српски")
        case .danish:     return ("Danish", "Dansk")
        case .dutch:      return ("Dutch", "Nederlands")
        case .finnish:    return ("Finnish", "Suomi")
        case .greek:      return ("Greek", "Ελληνικά")
        case .hungarian:  return ("Hungarian", "Magyar")
        case .swedish:    return ("Swedish", "Svenska")
        case .latvian:    return ("Latvian", "Latviešu")
        }
    }

    /// English name — the stable sort key and the leading half of `displayName`.
    public var englishName: String { names.english }

    /// Native endonym (may be in a non-Latin / RTL script).
    public var nativeName: String { names.native }

    /// Picker row label. Uniform left-to-right **"English — native"** (just the
    /// English name when the endonym is identical, e.g. English / Filipino). RTL
    /// scripts (Arabic, Persian) render within the LTR row — we deliberately do
    /// NOT flip the row direction, so every language reads the same way. The
    /// "Experimental" marker is NOT in this string — it's a separate badge in the
    /// picker row (see `isExperimental`).
    public var displayName: String {
        let n = names
        return n.native == n.english ? n.english : "\(n.english) — \(n.native)"
    }

    /// Experimental languages — surfaced with a small badge in the picker
    /// rather than a text suffix. Covers the Nemotron-multilingual-only
    /// languages (no proven Parakeet fallback) PLUS Latvian, which runs on v3
    /// but is the model's weakest-accuracy European language (~23% WER) and
    /// Nemotron's beta tier, so it's flagged honestly.
    public var isExperimental: Bool { requiresNemotronMultilingual || self == .latvian }

    /// The model the language picker resolves to. **English is tier-aware**:
    /// Nemotron on eligible hardware (≥ M2 Pro AND ≥ 16 GB), else v2. Japanese
    /// → JA, every European language → v3 (all tier-independent). Nemotron is
    /// never returned for a non-English language.
    public func modelID(tier: HardwareTier.Type = HardwareTier.self) -> ParakeetModelID {
        switch self {
        case .english:
            // ≥24 GB folds English into the Nemotron multilingual "latin" ship
            // (one model across en + Latin Europe). 16–24 GB keeps the English
            // Nemotron; <16 GB the English-optimized v2 batch. v3 is never the
            // English pick.
            if tier.nemotronMultilingualEligible { return .nemotron_multilingual_latin }
            return tier.nemotronEligible ? .nemotron_en : .tdt_0_6b_v2_en_streaming
        case .japanese:
            return .tdt_0_6b_ja
        case .spanish, .french, .german, .italian, .portuguese:
            // Latin-script Nemotron languages → the "latin" ship on ≥24 GB,
            // else today's Parakeet v3 (no regression below the bar).
            return tier.nemotronMultilingualEligible
                ? .nemotron_multilingual_latin : .tdt_0_6b_v3_eou_streaming
        case .mandarin, .arabic, .korean, .hindi, .vietnamese, .turkish:
            // Nemotron-only languages → the full "multilingual" ship on ≥24 GB.
            // Below the bar they have NO backend: the picker hides them
            // (`requiresNemotronMultilingual`) and the Qwen-retirement migration
            // moved any existing users to English, so the v3 fallback here is
            // defensive only (loads without crashing; never the intended path).
            return tier.nemotronMultilingualEligible
                ? .nemotron_multilingual : .tdt_0_6b_v3_eou_streaming
        case .romanian, .polish, .czech, .slovak, .slovenian, .croatian, .bosnian,
             .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish, .latvian:
            // Stay on Parakeet v3 — either Nemotron regressed on the eval
            // (cs/sk/sl/da/nb) or they're untested; v3 is the proven backend.
            // Latvian rides v3 too (no Nemotron latin-ship membership).
            return .tdt_0_6b_v3_eou_streaming
        }
    }

    /// The FluidAudio language hint to pass at `transcribe(...)` time. Only
    /// meaningful for the v3 European paths (the Latin/Cyrillic script filter,
    /// design §2.2). English runs on v2 (monolingual) and Japanese on JA —
    /// both ignore the hint, so both return `nil`. European languages without
    /// a hint case (Danish, Dutch, Finnish, Greek, Hungarian, Swedish) also
    /// return `nil` and fall back to v3 auto-detect (design §2.3).
    public var fluidAudioLanguage: Language? {
        switch self {
        case .english:    return nil  // v2 is English-only; no hint needed
        case .japanese:   return nil  // ignored by tdtJa anyway
        // Nemotron-multilingual languages don't use v3's `Language` script
        // filter — they pass `nemotronLanguageCode` to `setLanguage`. Return
        // `nil` here so the v3 `AsrManager` hint path is never engaged for them.
        case .mandarin, .vietnamese, .arabic, .korean, .turkish, .hindi:
            return nil
        case .spanish:    return .spanish
        case .french:     return .french
        case .german:     return .german
        case .italian:    return .italian
        case .portuguese: return .portuguese
        case .romanian:   return .romanian
        case .polish:     return .polish
        case .czech:      return .czech
        case .slovak:     return .slovak
        case .slovenian:  return .slovenian
        case .croatian:   return .croatian
        case .bosnian:    return .bosnian
        case .russian:    return .russian
        case .ukrainian:  return .ukrainian
        case .belarusian: return .belarusian
        case .bulgarian:  return .bulgarian
        case .serbian:    return .serbian
        // v3-supported but no FluidAudio hint case → auto-detect.
        case .danish, .dutch, .finnish, .greek, .hungarian, .swedish, .latvian:
            return nil
        }
    }

    /// BCP-47-ish language code handed to the Nemotron multilingual model:
    /// it both selects the `latin` vs `multilingual` on-disk variant (the
    /// prefix must match FluidAudio's `languageDirectory(for:)` — en/es/fr/it/
    /// pt/de → latin, else multilingual) and is the `setLanguage(_:)` prompt
    /// hint. Only languages routed to Nemotron (Phase 4, ≥24 GB) are exercised
    /// at runtime; the rest return a best-effort code.
    public var nemotronLanguageCode: String {
        switch self {
        case .english:    return "en-US"
        case .spanish:    return "es-ES"
        case .french:     return "fr-FR"
        case .italian:    return "it-IT"
        case .portuguese: return "pt-PT"
        case .german:     return "de-DE"
        case .mandarin:   return "zh-CN"
        case .vietnamese: return "vi-VN"
        case .arabic:     return "ar"
        case .korean:     return "ko-KR"
        case .turkish:    return "tr-TR"
        case .hindi:      return "hi-IN"
        case .japanese:   return "ja"
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
        case .latvian:    return "lv"
        }
    }

    /// True only for English. Gates the English-word-driven deterministic
    /// cleanup stages: `NumberNormalizer`'s spelled-cardinal rules would
    /// mis-convert Romance/other Latin scripts (e.g. French "six cents" = 600
    /// → "6¢"), and `FillerWordCleaner`'s filler + abbreviation lists are
    /// English-hardcoded. Pause-based paragraph segmentation and
    /// `PostProcessing` are language-agnostic and NOT gated on this.
    /// Per-language rules are future work (jot-shared
    /// docs/multilingual-itn-options.md).
    public var isEnglish: Bool { self == .english }

    /// Whether this language's script is written **without inter-word spaces**
    /// (CJK / space-free scripts). Drives preview-only string assembly in
    /// `PreviewScheduler.join` — a spaceless language must glue the committed
    /// tail to the volatile tail with no separator, otherwise the live preview
    /// shows a spurious space at every window boundary.
    ///
    /// `true` for Japanese today. Future Chinese / Korean would also be `true`
    /// when added; every Latin / Cyrillic / Greek language is `false`.
    ///
    /// This is **preview-only**: the final batch transcript is produced by the
    /// model itself and is unaffected by this flag.
    public var isSpaceless: Bool {
        switch self {
        case .japanese, .mandarin:
            // Spaceless scripts: CJK written without inter-word spaces.
            return true
        case .vietnamese:
            // Vietnamese is space-separated Latin-with-diacritics.
            return false
        case .arabic, .korean, .turkish, .hindi:
            // Space-separated scripts: Arabic (RTL, but spaced), Korean Hangul
            // (modern Korean uses inter-word spaces), Turkish (Latin), Hindi
            // (Devanagari).
            return false
        case .english, .spanish, .french, .german, .italian, .portuguese,
             .romanian, .polish, .czech, .slovak, .slovenian, .croatian,
             .bosnian, .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish, .latvian:
            return false
        }
    }

    /// The **selectable** presentation set: every language sorted alphabetically
    /// by its ENGLISH name, with the Nemotron-only languages dropped on hardware
    /// that can't run them. Use this where you must never offer a language the
    /// user can't actually pick (e.g. the MRU/recents eligible set). Pickers that
    /// want to *show* gated languages as disabled use `presentationEntries`
    /// instead. Derived from `presentationEntries` so the ordering stays in sync.
    public static var presentationOrder: [LanguageChoice] {
        presentationEntries().filter { !$0.isHardwareGated }.map(\.language)
    }

    /// One picker entry: a language plus whether the *current* Mac can run it.
    /// Gated entries are the Nemotron-multilingual-only languages on a Mac below
    /// the 24 GB / M2-Pro bar — surfaced (greyed, disabled) rather than hidden so
    /// a user searching for e.g. Arabic learns *why* it's unavailable instead of
    /// getting an empty result.
    public struct MenuEntry: Identifiable, Sendable, Equatable {
        public let language: LanguageChoice
        public let isHardwareGated: Bool
        public var id: String { language.id }
    }

    /// Short, self-explanatory reason a gated language can't be selected here.
    ///
    /// Two honest variants, because a Mac can miss the ≥24 GB **and**
    /// M2-Pro-class-chip bar for either reason independently: a base-M2 32 GB
    /// Mac is *chip*-gated, not RAM-gated, and the old flat "24 GB memory" line
    /// misdescribed it. Chip failure leads (it's the harder wall — no RAM
    /// upgrade fixes an old chip), so a machine that fails the chip check gets
    /// the chip note regardless of its RAM; only chip-passing-but-RAM-short Macs
    /// see the memory note. `chipClearsTier` is injectable for the DEBUG harness.
    public static func hardwareGateNote(
        chipClearsTier: Bool = HardwareTier.chipClearsNemotronTier(HardwareTier.chipBrandString)
    ) -> String {
        chipClearsTier
            ? "Needs a Mac with 16 GB memory or more"
            : "Needs a newer Apple Silicon chip (M2 Pro or M4 and later)"
    }

    /// Whether `lang` is present in the picker but not selectable on this Mac —
    /// a Nemotron-only language with no backend below the measured 16 GB / chip-tier bar. Pure
    /// presentation gating; routing/eligibility/models are unchanged. The
    /// eligibility is injectable for the DEBUG harness.
    public static func isHardwareGated(
        _ lang: LanguageChoice,
        multilingualEligible: Bool = HardwareTier.nemotronMultilingualEligible
    ) -> Bool {
        lang.requiresNemotronMultilingual && !multilingualEligible
    }

    /// Every surfaced language in alphabetical (English-name) order, each tagged
    /// with whether the current hardware can run it. Unlike `presentationOrder`
    /// this NEVER drops a language — gated ones come back with
    /// `isHardwareGated == true` so pickers can render them disabled + explained.
    /// Type-to-search over this set still finds gated languages (that's the
    /// point: the explanation replaces an empty result).
    public static func presentationEntries(
        multilingualEligible: Bool = HardwareTier.nemotronMultilingualEligible
    ) -> [MenuEntry] {
        LanguageChoice.allCases
            .sorted {
                $0.englishName.localizedCaseInsensitiveCompare($1.englishName) == .orderedAscending
            }
            .map { MenuEntry(language: $0, isHardwareGated: isHardwareGated($0, multilingualEligible: multilingualEligible)) }
    }

    /// Languages that ONLY the Nemotron multilingual ship can transcribe (no
    /// Parakeet fallback) — so they require ≥24 GB hardware.
    public var requiresNemotronMultilingual: Bool {
        switch self {
        case .mandarin, .arabic, .korean, .hindi, .vietnamese, .turkish:
            return true
        default:
            return false
        }
    }

    // MARK: - System-locale resolution (design §5.1)

    /// Resolve the default language from the system locale's primary language
    /// code, falling back to `.english` when the locale isn't a supported
    /// transcription language.
    public static func fromSystemLocale(_ locale: Locale = .current) -> LanguageChoice {
        guard let code = locale.language.languageCode?.identifier.lowercased() else {
            return .english
        }
        return fromLanguageCode(code) ?? .english
    }

    /// Map an ISO-639 language code (e.g. `"de"`, `"ja"`) to a `LanguageChoice`.
    /// Returns `nil` for unsupported codes so callers can apply their own
    /// fallback.
    public static func fromLanguageCode(_ code: String) -> LanguageChoice? {
        switch code.lowercased() {
        case "en": return .english
        case "ja": return .japanese
        case "zh": return .mandarin
        case "vi": return .vietnamese
        case "ar": return .arabic
        case "ko": return .korean
        case "tr": return .turkish
        case "hi": return .hindi
        case "es": return .spanish
        case "fr": return .french
        case "de": return .german
        case "it": return .italian
        case "pt": return .portuguese
        case "ro": return .romanian
        case "pl": return .polish
        case "cs": return .czech
        case "sk": return .slovak
        case "sl": return .slovenian
        case "hr": return .croatian
        case "bs": return .bosnian
        case "ru": return .russian
        case "uk": return .ukrainian
        case "be": return .belarusian
        case "bg": return .bulgarian
        case "sr": return .serbian
        case "da": return .danish
        case "nl": return .dutch
        case "fi": return .finnish
        case "el": return .greek
        case "hu": return .hungarian
        case "sv": return .swedish
        case "lv": return .latvian
        default:   return nil
        }
    }

    /// Derive the initial language from a stored `jot.defaultModelID` value
    /// (migration entry point, design §6.4). English-only models (v2, Nemotron)
    /// and the v3 family all map to `.english`; the JA model maps to
    /// `.japanese`. The stored model itself is preserved by the caller — this
    /// only seeds the *language* key.
    public static func fromStoredModelID(_ modelID: ParakeetModelID) -> LanguageChoice {
        switch modelID {
        case .tdt_0_6b_ja:
            return .japanese
        case .nemotron_en,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             // Nemotron multilingual ships back many languages; the model id
             // alone can't disambiguate, so seed English (the stored language
             // key is authoritative when present — see TranscriberHolder
             // precedence). The latin ship in particular IS English's home.
             .nemotron_multilingual,
             .nemotron_multilingual_latin:
            // A stored v3 (multilingual) user is grandfathered onto English at
            // the language level while keeping their v3 model (design §6.4
            // case (b)); the precedence rule in TranscriberHolder keeps the
            // stored model authoritative, so no surprise download occurs.
            return .english
        }
    }
}
