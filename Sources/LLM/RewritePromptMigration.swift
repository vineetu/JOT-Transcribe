import Foundation

/// One-shot migration for the default `rewritePrompt` value when Jot
/// ships an improved no-instruction prompt. Runs exactly once per
/// machine (guarded by `jot.migration.rewritePromptDefaultV2`).
///
/// Why this exists: the @AppStorage default is consulted only when no
/// value is set. Users who launched any 1.4–1.9.4 build already have
/// the old default text stored in UserDefaults (read once, cached).
/// Changing `RewritePrompt.default` in code alone doesn't reach those
/// users. This migration detects the case "value in UserDefaults
/// equals the legacy default verbatim" and swaps it for the new
/// default. Customized prompts are left untouched — the user's edits
/// always win.
enum RewritePromptMigration {
    /// Bumped to V4 because V3 didn't include the pre-v1.9.2
    /// defaults — users on really old installs (v1.6 era) still had
    /// the "according to their spoken instruction" prompt cached,
    /// which the model refuses on for the no-instruction tap path.
    /// V4 adds both pre-v1.9.2 variants to the legacy list.
    private static let flagKey = "jot.migration.rewritePromptDefaultV4"
    private static let promptKey = "jot.llm.rewritePrompt"

    /// Run once. Idempotent — safe to call on every launch; the flag
    /// short-circuits subsequent calls.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let stored = defaults.string(forKey: promptKey)
        // Case 1: never customized (no value stored). @AppStorage will
        // return `RewritePrompt.default` on first read; no migration
        // needed, just set the flag and move on.
        guard let stored else { return }

        // Case 2: stored value matches ANY known legacy default
        // verbatim → user never customized; swap to the current
        // default. Covers every shipping default we know of:
        //   - V0 / V0_translate: pre-v1.9.2 single-paragraph that
        //     assumes a spoken instruction (the version causing
        //     "no instruction provided" refusals on the tap path)
        //   - V1: v1.4–v1.9.4 two-paragraph "improve clarity/flow"
        //   - V2: the brief 1.9.5-preview build-101/105 over-
        //     specified dictation-doctor draft
        let legacyDefaults: [String] = [
            RewritePrompt.legacyDefaultV0,
            RewritePrompt.legacyDefaultV0_translate,
            RewritePrompt.legacyDefaultV1,
            RewritePrompt.legacyDefaultV2,
        ]
        if legacyDefaults.contains(stored) {
            defaults.set(RewritePrompt.default, forKey: promptKey)
        }
        // Case 3: stored value differs → user customized at some point.
        // Don't touch it.
    }
}
