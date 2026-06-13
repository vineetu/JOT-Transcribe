import Foundation

/// One-shot, additive migration that seeds the new
/// `jot.transcriptionLanguage` key (design §6.4) from the user's existing
/// stored `jot.defaultModelID`.
///
/// **No silent downgrade.** This migration NEVER writes `jot.defaultModelID`.
/// It only derives the *language* key from whatever model the user is already
/// on, leaving the model authoritative (`TranscriberHolder.activeModelID`
/// honors the stored model over the language→model default when they disagree,
/// design §5.4.1). Concretely:
///
/// ```
/// stored jot.defaultModelID        →  initial jot.transcriptionLanguage
///   .tdt_0_6b_ja                          → .japanese
///   .nemotron_en                          → .english   (GRANDFATHER: keep Nemotron, no downgrade/re-download)
///   .tdt_0_6b_v2_en_streaming             → .english   (already on v2 = the new English default)
///   .tdt_0_6b_v3* (incl. eou)             → .english   (GRANDFATHER on v3: keep v3, do NOT auto-fetch v2)
///   absent (fresh install)                → system-locale language (§5.1); English resolves to v2
/// ```
///
/// One-shot guarded by `migratedKey`, mirroring the `ModelChoiceMigration`
/// markers — once set, later launches do not re-derive (drift prevention,
/// same discipline as `ModelChoiceMigration.swift:42-45`).
///
/// `@MainActor`-isolated because it reads `TranscriberHolder.defaultsKey` /
/// `.languageKey`, both MainActor-isolated; `JotComposition.build` (the only
/// call site) is already MainActor, so the annotation is free.
@MainActor
enum LanguageMigration {

    /// One-shot sentinel (design §6.3). Set once the language key has been
    /// seeded so subsequent launches leave the user's language intact even if
    /// they later switch models or languages manually.
    static let migratedKey = "jot.transcriptionLanguage.migrated"

    /// Seed `jot.transcriptionLanguage` if it hasn't been migrated yet.
    ///
    /// - Returns: `true` when this call wrote the language key.
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults,
        systemLocale: Locale = .current
    ) -> Bool {
        if defaults.bool(forKey: migratedKey) {
            return false
        }
        defer { defaults.set(true, forKey: migratedKey) }

        // If a language is somehow already set, respect it and just stamp the
        // sentinel (defensive — keeps the one-shot honest).
        if defaults.string(forKey: TranscriberHolder.languageKey) != nil {
            return false
        }

        let storedModel = defaults.string(forKey: TranscriberHolder.defaultsKey)
            .flatMap(ParakeetModelID.init(rawValue:))

        let language: LanguageChoice
        if let storedModel {
            // Existing user: derive language from their model, never touching
            // the model itself (grandfather rule, design §6.4 rule #1).
            language = LanguageChoice.fromStoredModelID(storedModel)
        } else {
            // Fresh install: default to the system locale's language, falling
            // back to English (design §5.1). The resolved model (v2 for
            // English) downloads via the wizard's percentage UX on the
            // genuine first-run path — we do NOT mark a pending migration
            // download here; that is the wizard's job.
            language = LanguageChoice.fromSystemLocale(systemLocale)
        }

        defaults.set(language.rawValue, forKey: TranscriberHolder.languageKey)
        return true
    }
}
