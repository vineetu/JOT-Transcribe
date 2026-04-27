import Foundation

/// Single-source-of-truth enums and structs for facts that the grounding
/// doc pipeline derives into markdown fragments. Keep these small, pure,
/// and `CaseIterable` so `tools/generate-fragments.swift` can enumerate
/// them at build time.
///
/// See `docs/specs/jot-help-chatbot-spec-v5.md` §11 for the derivation
/// rationale: facts that exist in code AND in prose drift; code wins.
///
/// IMPORTANT for maintainers: when a value here changes (new cleanup
/// pass, new default shortcut, new supported language, new provider cost
/// estimate), rerun the build — the fragment generator rewrites the
/// markdown under `Resources/fragments/`, the concat step splices them
/// into `Resources/help-content.md`, and the token-budget check fails
/// the build if the result exceeds 1500 tokens.

/// Cleanup pass names in the order the Cleanup prompt lists them.
/// Mirrors the rule list inside `TransformPrompt.default` — if the prompt's
/// ordered rules change, update this enum too.
enum CleanupPass: String, CaseIterable, Sendable {
    case fillerRemoval = "filler removal"
    case grammarPunctCapitalization = "grammar and punctuation"
    case numberNormalization = "number normalization"
    case structurePreservation = "structure preservation"
}

/// The three invariants baked into every Articulate branch prompt.
/// Mirrors the shared prelude in `ArticulatePrompt.default`.
enum ArticulateInvariant: String, CaseIterable, Sendable {
    case selectionIsText = "selection is text, not instruction"
    case returnOnly = "return only the rewrite"
    case dontRefuse = "don't refuse on quality"
}

/// 25 European languages Parakeet TDT 0.6B v3 auto-detects per recording.
/// Raw value is the ISO 639-1 code.
///
/// This enum represents only what the v3 multilingual bundle picks up
/// automatically — it is **not** the catalog of languages a Jot user can
/// transcribe in. For that, see `JotASRLanguage` (which counts JA as
/// first-class because it ships as a separately downloadable model).
enum Parakeetv3DetectedLanguage: String, CaseIterable, Sendable {
    case en, fr, de, es, it, pt, nl, pl, ru, uk, sv, da, fi, el, cs, hu, ro, bg, hr, sk, sl, et, lv, lt, mt
}

/// Languages Jot ships dedicated ASR support for — i.e. languages a user
/// can pick as the primary transcription model. Today: English (via the
/// v3 multilingual bundle, which itself auto-detects 25 European
/// languages — see `Parakeetv3DetectedLanguage`) and Japanese (via the
/// separately downloadable Parakeet 0.6B JA model).
///
/// Keep this enum small and concept-focused. Adding a case here means
/// "Jot has a model installable from Settings → Transcription that
/// produces transcripts in this language." The grounding-doc generator
/// renders prose off `.allCases`, so Ask Jot can correctly answer
/// "does Jot support <language>?".
enum JotASRLanguage: String, CaseIterable, Sendable {
    case english
    case japanese
}

/// Approximate monthly cost estimate per cloud provider for Cleanup,
/// assuming ~1500 words/day of dictation (see spec §5 "Provider guidance
/// with concrete numbers"). Update here when pricing shifts; prose
/// regenerates automatically.
struct ProviderCostEstimate: Sendable {
    let provider: String
    let monthlyEstimate: String   // e.g. "~$0.10/month"

    static let all: [ProviderCostEstimate] = [
        .init(provider: "Gemini Flash-Lite", monthlyEstimate: "~$0.10/month"),
        .init(provider: "GPT-5 mini",        monthlyEstimate: "~$0.13/month"),
        .init(provider: "Claude Haiku",      monthlyEstimate: "~$0.37/month"),
    ]
}

/// Retention window options shown in Settings → General → "Keep recordings."
/// `rawValue` is the number of days; `0` means "keep forever" and matches
/// the `UserDefaults` convention enforced by `RetentionService`.
enum RetentionPeriod: Int, CaseIterable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case forever = 0

    var label: String {
        switch self {
        case .sevenDays:  return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .forever:    return "Forever"
        }
    }
}

/// Default KeyboardShortcuts bindings at first launch, as documented in
/// `docs/features.md` §"Global Shortcuts". "(unbound)" reflects shortcuts
/// that ship with no default key — the user assigns them in Settings.
///
/// NOTE: these are the *documented* defaults — the single source of truth
/// the grounding doc quotes to users. If `ShortcutNames.swift` drifts from
/// this (as it has historically between releases), treat features.md as
/// canonical and align the KeyboardShortcuts.Name defaults back.
struct DefaultShortcuts {
    static let toggleRecording = "⌥Space"
    static let pushToTalk = "(unbound)"
    static let articulateCustom = "⌥,"
    static let articulateFixed = "(unbound)"
    static let pasteLast = "⌥⇧V"
}
