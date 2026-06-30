import Foundation

/// One-shot, launch-time retirement of the Qwen3-ASR engine (removed from
/// FluidAudio 0.15.x) and reclassification of its languages onto Nemotron 3.5
/// Multilingual or a safe fallback.
///
/// ## Why this must run FIRST (before `LanguageMigration` and before
/// `TranscriberHolder` is constructed)
///
/// After the already-shipped `LanguageMigration`, routing is computed from the
/// **language** (`LanguageChoice.modelID(tier:)`), not the stored model id.
/// When the dropped `LanguageChoice` cases are removed (Phase 6), a stored
/// `jot.transcriptionLanguage == "cantonese"` would fail `LanguageChoice
/// .init(rawValue:)` and silently coerce to English at `TranscriberHolder.init`
/// — with no notice, even for *surviving* languages like Korean. So this
/// migration reads the **raw** language string and classifies it against a
/// **hardcoded literal map** (the enum can't classify cases it no longer has),
/// rewriting the key before anything reads it. It NEVER calls
/// `LanguageChoice(rawValue:)` on the retired values.
///
/// Like `NemotronAutoUpgradeMigration` it never performs the model swap
/// itself: for a surviving language on eligible hardware it sets a *pending*
/// marker and the download-then-flip happens later in
/// `TranscriberHolder.startPendingNemotronMultilingualUpgradeIfNeeded()`.
///
/// `@MainActor` because it reads `TranscriberHolder.languageKey` /
/// `.defaultsKey` (both MainActor-isolated); `JotComposition.build` is already
/// MainActor.
@MainActor
enum QwenRetirementMigration {

    /// One-shot sentinel — the classification runs exactly once.
    static let migratedKey = "jot.qwenRetirementMigrated"

    /// Pending marker consumed by
    /// `TranscriberHolder.startPendingNemotronMultilingualUpgradeIfNeeded()`.
    /// Cleared only on a *successful* multilingual download+flip (retries
    /// across launches on failure), like the auto-upgrade marker.
    static let multilingualUpgradePendingKey = "jot.nemotron.multilingualUpgradePending"

    /// Set while a surviving-Qwen user (≥24 GB) is standing on the now-unloadable
    /// Qwen bundle with the multilingual download still pending. Read at the top
    /// of `resolveSessionTranscriber` to fall the session back to English (or a
    /// download-progress block) so the user can dictate *something* meanwhile.
    /// Cleared when the multilingual flip succeeds.
    static let crossLanguageFallbackKey = "jot.qwen.pendingCrossLanguageFallback"

    /// One-shot, user-facing notice surfaced once via the migration banner, then
    /// cleared. Value is `"retired:<lang>"` or `"needs24GB:<lang>"`.
    static let noticeKey = "jot.qwenRetirement.notice"

    /// Languages dropped entirely (not in the Nemotron set) — reset to English.
    static let droppedLanguages: Set<String> = [
        "cantonese", "persian", "thai", "indonesian", "malay", "filipino", "macedonian",
    ]

    /// Languages that survive on Nemotron Multilingual (≥24 GB only).
    static let survivingLanguages: Set<String> = [
        "mandarin", "arabic", "korean", "hindi", "vietnamese", "turkish",
    ]

    /// Evaluate the retirement exactly once. Reads the RAW language string and
    /// rewrites `jot.transcriptionLanguage` / `jot.defaultModelID` / the pending
    /// + notice markers as needed. Never calls `LanguageChoice(rawValue:)` on a
    /// retired value (the case may already be gone).
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults,
        multilingualEligible: Bool = HardwareTier.nemotronMultilingualEligible
    ) -> Bool {
        if defaults.bool(forKey: migratedKey) {
            return false
        }
        defer { defaults.set(true, forKey: migratedKey) }

        // A stored Qwen MODEL id no longer decodes under 0.15.x — rewrite it to
        // a loadable default regardless of the language outcome below, so
        // nothing dangles on `.qwen3_multilingual`.
        if defaults.string(forKey: TranscriberHolder.defaultsKey)
            == ParakeetModelID.qwen3_multilingual.rawValue {
            defaults.set(
                ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue,
                forKey: TranscriberHolder.defaultsKey)
        }

        guard let raw = defaults.string(forKey: TranscriberHolder.languageKey) else {
            return false
        }

        if droppedLanguages.contains(raw) {
            // No backend in the Nemotron set — reset the language and tell the
            // user it was retired.
            defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
            defaults.set("retired:\(raw)", forKey: noticeKey)
            return true
        }

        if survivingLanguages.contains(raw) {
            if multilingualEligible {
                // Keep the language; queue the multilingual download. Until it
                // flips, the active model is the dead Qwen bundle with no
                // same-language Parakeet fallback, so also arm the cross-language
                // English fallback for the session.
                defaults.set(true, forKey: multilingualUpgradePendingKey)
                defaults.set(true, forKey: crossLanguageFallbackKey)
            } else {
                // Below the 24 GB bar there is no backend — fall back to English
                // and tell the user the language now needs a 24 GB Mac.
                defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
                defaults.set("needs24GB:\(raw)", forKey: noticeKey)
            }
            return true
        }

        // Not a Qwen language (English / Japanese / European) — nothing to do.
        return false
    }
}
