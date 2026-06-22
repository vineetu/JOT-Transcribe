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

    // Experimental Qwen3-ASR languages (zh / yue / vi). These are NOT
    // Parakeet v3 languages — v3's script filter is Latin/Cyrillic only — so
    // they route to the separate `.qwen3_multilingual` engine. macOS 15+
    // only (the Qwen3 manager is `@available(macOS 15, *)`; the deployment
    // target is already 15). Mandarin + Cantonese are spaceless CJK;
    // Vietnamese is space-separated Latin-with-diacritics.
    case mandarin
    case cantonese
    case vietnamese
    // Additional Qwen3-ASR languages not covered by Parakeet v3 / the JA
    // model. Arabic + Persian are RTL (Arabic script); Korean is Hangul
    // (space-separated, NOT spaceless); Thai is spaceless (no inter-word
    // spaces); Turkish / Indonesian / Malay / Filipino are Latin;
    // Hindi is Devanagari; Macedonian is Cyrillic. All space-separated
    // except Thai. Filipino uses Qwen3 code "fil" (locale may report "tl").
    case arabic
    case persian
    case korean
    case thai
    case turkish
    case hindi
    case indonesian
    case malay
    case filipino
    case macedonian

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

    public var id: String { rawValue }

    /// Localized, human-readable language name for the picker rows. **No model
    /// name, no footprint, no badge** (design §5.2/§5.3 — model identity is
    /// surfaced only in About).
    public var displayName: String {
        switch self {
        case .english:    return "English"
        case .japanese:   return "日本語 (Japanese)"
        case .mandarin:   return "中文 (Mandarin) — Experimental"
        case .cantonese:  return "粵語 (Cantonese) — Experimental"
        case .vietnamese: return "Tiếng Việt (Vietnamese) — Experimental"
        case .arabic:      return "العربية (Arabic) — Experimental"
        case .persian:     return "فارسی (Persian) — Experimental"
        case .korean:      return "한국어 (Korean) — Experimental"
        case .thai:        return "ไทย (Thai) — Experimental"
        case .turkish:     return "Türkçe (Turkish) — Experimental"
        case .hindi:       return "हिन्दी (Hindi) — Experimental"
        case .indonesian:  return "Bahasa Indonesia (Indonesian) — Experimental"
        case .malay:       return "Bahasa Melayu (Malay) — Experimental"
        case .filipino:    return "Filipino — Experimental"
        case .macedonian:  return "Македонски (Macedonian) — Experimental"
        case .spanish:    return "Español (Spanish)"
        case .french:     return "Français (French)"
        case .german:     return "Deutsch (German)"
        case .italian:    return "Italiano (Italian)"
        case .portuguese: return "Português (Portuguese)"
        case .romanian:   return "Română (Romanian)"
        case .polish:     return "Polski (Polish)"
        case .czech:      return "Čeština (Czech)"
        case .slovak:     return "Slovenčina (Slovak)"
        case .slovenian:  return "Slovenščina (Slovenian)"
        case .croatian:   return "Hrvatski (Croatian)"
        case .bosnian:    return "Bosanski (Bosnian)"
        case .russian:    return "Русский (Russian)"
        case .ukrainian:  return "Українська (Ukrainian)"
        case .belarusian: return "Беларуская (Belarusian)"
        case .bulgarian:  return "Български (Bulgarian)"
        case .serbian:    return "Српски (Serbian)"
        case .danish:     return "Dansk (Danish)"
        case .dutch:      return "Nederlands (Dutch)"
        case .finnish:    return "Suomi (Finnish)"
        case .greek:      return "Ελληνικά (Greek)"
        case .hungarian:  return "Magyar (Hungarian)"
        case .swedish:    return "Svenska (Swedish)"
        }
    }

    /// The model the language picker resolves to. **English is tier-aware**:
    /// Nemotron on eligible hardware (≥ M2 Pro AND ≥ 16 GB), else v2. Japanese
    /// → JA, every European language → v3 (all tier-independent). Nemotron is
    /// never returned for a non-English language.
    public func modelID(tier: HardwareTier.Type = HardwareTier.self) -> ParakeetModelID {
        switch self {
        case .english:
            // Best English model the hardware can run: Nemotron on capable
            // Macs (≥ M2 Pro AND ≥ 16 GB — premium true-streaming), else the
            // English-optimized v2 batch model. v3 is never the English pick.
            return tier.nemotronEligible ? .nemotron_en : .tdt_0_6b_v2_en_streaming
        case .japanese:
            return .tdt_0_6b_ja
        case .mandarin, .cantonese, .vietnamese,
             .arabic, .persian, .korean, .thai, .turkish, .hindi,
             .indonesian, .malay, .filipino, .macedonian:
            // The experimental Qwen3-ASR languages share one on-disk
            // bundle; the language is a per-call prompt hint, not a separate
            // model. Tier-independent (runs on every Apple Silicon Mac with
            // macOS 15+).
            return .qwen3_multilingual
        case .spanish, .french, .german, .italian, .portuguese, .romanian,
             .polish, .czech, .slovak, .slovenian, .croatian, .bosnian,
             .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
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
        // Qwen3 languages don't use v3's `Language` script filter — they pass
        // their own ISO string via `qwen3Language`. Return `nil` here so the
        // v3 `AsrManager` hint path is never engaged for them.
        case .mandarin, .cantonese, .vietnamese,
             .arabic, .persian, .korean, .thai, .turkish, .hindi,
             .indonesian, .malay, .filipino, .macedonian: return nil
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
        case .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
            return nil
        }
    }

    /// The Qwen3-ASR language hint (ISO code: `"zh"` / `"yue"` / `"vi"`) for
    /// the three experimental languages, threaded through to `Qwen3Transcriber`
    /// at `transcribe(...)` time. `nil` for every non-Qwen3 language — those
    /// run on Parakeet (v2/v3/JA) and never touch the Qwen3 manager. This is a
    /// separate property from `fluidAudioLanguage` because the two engines take
    /// different language types (v3 uses the `Language` script-filter enum;
    /// Qwen3 takes a plain ISO string mapped to a chat-template task prompt).
    public var qwen3Language: String? {
        switch self {
        case .mandarin:   return "zh"
        case .cantonese:  return "yue"
        case .vietnamese: return "vi"
        case .arabic:     return "ar"
        case .persian:    return "fa"
        case .korean:     return "ko"
        case .thai:       return "th"
        case .turkish:    return "tr"
        case .hindi:      return "hi"
        case .indonesian: return "id"
        case .malay:      return "ms"
        case .filipino:   return "fil"
        case .macedonian: return "mk"
        case .english, .japanese, .spanish, .french, .german, .italian,
             .portuguese, .romanian, .polish, .czech, .slovak, .slovenian,
             .croatian, .bosnian, .russian, .ukrainian, .belarusian,
             .bulgarian, .serbian, .danish, .dutch, .finnish, .greek,
             .hungarian, .swedish:
            return nil
        }
    }

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
        case .japanese, .mandarin, .cantonese, .thai:
            // Spaceless scripts: CJK + Thai are written without inter-word
            // spaces.
            return true
        case .vietnamese:
            // Vietnamese is space-separated Latin-with-diacritics.
            return false
        case .arabic, .persian, .korean, .turkish, .hindi, .indonesian,
             .malay, .filipino, .macedonian:
            // Space-separated scripts: Arabic/Persian (RTL, but spaced),
            // Korean Hangul (modern Korean uses inter-word spaces),
            // Turkish/Indonesian/Malay/Filipino (Latin), Hindi (Devanagari),
            // Macedonian (Cyrillic).
            return false
        case .english, .spanish, .french, .german, .italian, .portuguese,
             .romanian, .polish, .czech, .slovak, .slovenian, .croatian,
             .bosnian, .russian, .ukrainian, .belarusian, .bulgarian, .serbian,
             .danish, .dutch, .finnish, .greek, .hungarian, .swedish:
            return false
        }
    }

    /// Picker presentation order: English and Japanese first (the two model
    /// forks), then the European languages alphabetically by display name.
    public static var presentationOrder: [LanguageChoice] {
        // English and Japanese first (the two original model forks), then the
        // experimental Qwen3 languages grouped together, then the European
        // languages alphabetically by display name.
        let leading: [LanguageChoice] = [
            .english, .japanese, .mandarin, .cantonese, .vietnamese,
            .arabic, .persian, .korean, .thai, .turkish, .hindi,
            .indonesian, .malay, .filipino, .macedonian,
        ]
        let european = LanguageChoice.allCases
            .filter { !leading.contains($0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return leading + european
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
        case "yue": return .cantonese
        case "vi": return .vietnamese
        case "ar": return .arabic
        case "fa": return .persian
        case "ko": return .korean
        case "th": return .thai
        case "tr": return .turkish
        case "hi": return .hindi
        case "id": return .indonesian
        case "ms": return .malay
        case "fil", "tl": return .filipino
        case "mk": return .macedonian
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
        case .qwen3_multilingual:
            // The Qwen3 bundle backs three languages; the stored model alone
            // can't disambiguate which one, so seed the most common (Mandarin).
            // The stored language key is authoritative when present; this is
            // only a fallback for a model-id-only migration.
            return .mandarin
        case .nemotron_en,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            // A stored v3 (multilingual) user is grandfathered onto English at
            // the language level while keeping their v3 model (design §6.4
            // case (b)); the precedence rule in TranscriberHolder keeps the
            // stored model authoritative, so no surprise download occurs.
            return .english
        }
    }
}
