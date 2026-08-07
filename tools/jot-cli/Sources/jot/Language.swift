import FluidAudio
import Foundation

/// CLI-side language resolution. The tables MIRROR the app's
/// `LanguageChoice.nemotronLanguageCode` / `.fluidAudioLanguage`
/// (`Sources/Transcription/LanguageChoice.swift`) so both binaries resolve a
/// user-facing code to the same engine inputs. Data-only mirror, kept small
/// on purpose; if the app's tables change, change these to match.
struct CLILanguage {
    /// Normalized base subtag: "en", "es", … ("de-DE" / "pt_BR" ⇒ "de" / "pt").
    let base: String

    init(_ raw: String) {
        let lowered = raw.lowercased()
        base = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init) ?? lowered
    }

    var isEnglish: Bool { base == "en" }

    /// Languages written without inter-word spaces. Stream mode's final
    /// derivation falls back to CJK-punctuation / length-threshold commit
    /// boundaries for these (whitespace boundaries never arrive).
    var usesSpacelessScript: Bool {
        ["zh", "ja", "th", "km", "lo", "my"].contains(base)
    }

    /// Which Nemotron 3.5 Multilingual on-disk ship serves this language.
    /// Must match FluidAudio's `languageDirectory(for:)`: en/es/fr/it/pt/de →
    /// the vocab-pruned "latin" variant, everything else → "multilingual".
    var usesLatinNemotronVariant: Bool {
        ["en", "es", "fr", "it", "pt", "de"].contains(base)
    }

    /// BCP-47-ish code handed to
    /// `StreamingNemotronMultilingualAsrManager.setLanguage(_:)`. Mirrors
    /// `LanguageChoice.nemotronLanguageCode`; unknown codes pass through
    /// unchanged (the model auto-detects when the prompt hint is unknown).
    var nemotronCode: String {
        switch base {
        case "en": return "en-US"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "it": return "it-IT"
        case "pt": return "pt-PT"
        case "de": return "de-DE"
        case "zh": return "zh-CN"
        case "vi": return "vi-VN"
        case "ko": return "ko-KR"
        case "tr": return "tr-TR"
        case "hi": return "hi-IN"
        default: return base
        }
    }

    /// FluidAudio batch-v3 script hint for `AsrManager.transcribe(language:)`.
    /// Mirrors `LanguageChoice.fluidAudioLanguage`: only the European v3 hint
    /// cases return a value; everything else (including English) is `nil` →
    /// auto-detect, exactly as in the app.
    var batchHint: Language? {
        switch base {
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
        default: return nil
        }
    }
}
