import Foundation

/// One-shot, launch-time auto-upgrade of existing **English and Latin-European**
/// users on ≥24 GB Apple Silicon to the Nemotron 3.5 Multilingual model — the
/// counterpart to `QwenRetirementMigration` (which covers the ex-Qwen
/// languages). Together they move every eligible existing user onto the
/// multilingual ship.
///
/// Supersedes `NemotronAutoUpgradeMigration` (English → `nemotron_en` at
/// ≥24 GB): on ≥24 GB English now folds into the latin ship, so the old
/// nemotron_en auto-upgrade is gated off (see its `runIfNeeded`).
///
/// Like the other upgrade migrations it NEVER swaps the model itself — it sets
/// the shared `multilingualUpgradePendingKey`, and
/// `TranscriberHolder.startPendingNemotronMultilingualUpgradeIfNeeded()` does
/// the download-then-flip (resolving the latin vs full ship from the active
/// language). The user keeps dictating on their CURRENT working model (v2 / v3
/// / nemotron_en) until the flip — so, unlike the ex-Qwen path, this does NOT
/// arm the cross-language fallback (there is no dead bundle to bridge).
///
/// `@MainActor` for the same reason as the sibling migrations (reads
/// `TranscriberHolder.languageKey` / `.defaultsKey`).
@MainActor
enum NemotronMultilingualMigration {

    static let migratedKey = "jot.nemotron.multilingualMigrated"

    /// Languages that ship in the Nemotron "latin" bundle and should upgrade on
    /// eligible hardware. (The ex-Qwen "multilingual" ship is handled by
    /// `QwenRetirementMigration`.)
    static let latinLanguages: Set<String> = [
        "english", "spanish", "french", "german", "italian", "portuguese",
    ]

    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults,
        multilingualEligible: Bool = HardwareTier.nemotronMultilingualEligible
    ) -> Bool {
        if defaults.bool(forKey: migratedKey) {
            return false
        }
        defer { defaults.set(true, forKey: migratedKey) }

        guard multilingualEligible else { return false }

        // Active language must be one the latin ship covers.
        guard let raw = defaults.string(forKey: TranscriberHolder.languageKey),
              latinLanguages.contains(raw) else { return false }

        // A user already on a multilingual ship needs no upgrade.
        let stored = defaults.string(forKey: TranscriberHolder.defaultsKey)
            .flatMap(ParakeetModelID.init(rawValue:))
        if stored == .nemotron_multilingual || stored == .nemotron_multilingual_latin {
            return false
        }

        defaults.set(true, forKey: QwenRetirementMigration.multilingualUpgradePendingKey)
        return true
    }
}
