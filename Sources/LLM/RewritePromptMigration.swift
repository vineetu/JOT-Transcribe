import Foundation

/// One-shot migration for the default `rewritePrompt` value when Jot
/// ships an improved no-instruction prompt. Runs exactly once per
/// machine, guarded by a per-version flag.
///
/// Why this exists: the @AppStorage default is consulted only when no
/// value is set. Users who launched any 1.4–1.9.4 build already have
/// the old default text stored in UserDefaults (read once, cached).
/// Changing `RewritePrompt.default` in code alone doesn't reach those
/// users. This migration detects the case "value in UserDefaults
/// equals a *broken* legacy default verbatim" and swaps it for the
/// last known good non-broken default. Customized prompts are left
/// untouched — the user's edits always win.
///
/// **Policy change in V5 (v1.13+):** the user-editable Rewrite prompt
/// got a substantial philosophy upgrade (idea linking + brain-dump
/// dedupe + output-format flexibility). Per product call: users who
/// already migrated forward to V3 (or who landed there as a fresh
/// install on v1.10–v1.12) **stay on V3**. We do NOT force them onto
/// V5 — they reach V5 only if they explicitly click "Reset to
/// default" in Settings → AI → Customize Prompt. So this migration
/// keeps fixing the genuinely-broken legacy defaults (V0 / V1 / V2 —
/// those refuse on the tap path because they assume a spoken
/// instruction) by upgrading them to V3, the last stable default that
/// existing users may be on. New users (no stored value) land on V5
/// via @AppStorage's default.
enum RewritePromptMigration {
    /// V5 bump signals the policy change above (target shifted from
    /// `RewritePrompt.default` to `RewritePrompt.legacyDefaultV3`).
    /// Re-running on machines that already had the V4 flag set is a
    /// no-op for V3 users (V3 isn't in the legacy list) and a no-op
    /// for users whose stored value already matches no legacy default
    /// (customized — left alone).
    private static let flagKey = "jot.migration.rewritePromptDefaultV5"
    private static let promptKey = "jot.llm.rewritePrompt"

    /// Run once. Idempotent — safe to call on every launch; the flag
    /// short-circuits subsequent calls.
    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: flagKey) else { return }
        defer { defaults.set(true, forKey: flagKey) }

        let stored = defaults.string(forKey: promptKey)
        // Case 1: never customized (no value stored). @AppStorage will
        // return `RewritePrompt.default` (V5) on first read; no
        // migration needed, just set the flag and move on.
        guard let stored else { return }

        // Case 2: stored value matches a known *broken* legacy default
        // verbatim → user never customized; swap to V3 (the last
        // stable default). Covers the pre-v1.10 shipping defaults that
        // have known bugs:
        //   - V0 / V0_translate: pre-v1.9.2 single-paragraph that
        //     assumes a spoken instruction (causes "no instruction
        //     provided" refusals on the ⌥/ tap path)
        //   - V1: v1.4–v1.9.4 two-paragraph "improve clarity/flow"
        //   - V2: the brief 1.9.5-preview build-101/105 over-
        //     specified dictation-doctor draft
        // V3 is intentionally NOT in this list — it's the upgrade
        // target, and V3 users are explicitly NOT auto-migrated to V5
        // per the policy in the type docstring.
        let legacyDefaults: [String] = [
            RewritePrompt.legacyDefaultV0,
            RewritePrompt.legacyDefaultV0_translate,
            RewritePrompt.legacyDefaultV1,
            RewritePrompt.legacyDefaultV2,
        ]
        if legacyDefaults.contains(stored) {
            defaults.set(RewritePrompt.legacyDefaultV3, forKey: promptKey)
        }
        // Case 3: stored value matches V3 OR is fully customized →
        // leave alone.
    }
}
