import Foundation

/// One-shot, launch-time auto-upgrade of existing **English** users on
/// high-RAM Apple Silicon to the Nemotron transcription model.
///
/// This is the deliberate counterpart to `LanguageMigration`'s "**No silent
/// downgrade**" rule: here we *do* perform an unsolicited, opt-in-by-policy
/// model **upgrade** — but it is engineered to be safe. The migration NEVER
/// touches `jot.defaultModelID`. All it does is flip a one-shot *pending*
/// marker; the actual model swap is performed later by
/// `TranscriberHolder.startPendingNemotronUpgradeIfNeeded()`, which downloads
/// Nemotron in the background and only flips the active model **after** the
/// download fully succeeds. The user keeps dictating on their current model
/// the entire time — there is no window where the active model is uninstalled.
///
/// ## Gate (all must hold)
///  1. `tier.autoUpgradeToNemotronEligible` — Apple Silicon, chip ≥ M2 Pro,
///     and **≥ 24 GB RAM** (the higher auto-swap bar, distinct from the 16 GB
///     run floor — see `HardwareTier`).
///  2. The active transcription language is **English** (`jot.transcriptionLanguage
///     == "english"`). We never auto-swap a Japanese or European-language user.
///  3. The stored `jot.defaultModelID` resolves to a **non-Nemotron** model
///     (a user already on Nemotron needs no upgrade).
///
/// When all three hold, set `autoUpgradePendingKey = true`. Otherwise leave it
/// absent. Either way, stamp `migratedKey` so the gate is evaluated **once**
/// (drift prevention, same discipline as `LanguageMigration` /
/// `ModelChoiceMigration`).
///
/// ## Ordering
/// MUST run **after** `LanguageMigration.runIfNeeded(...)`, which seeds
/// `jot.transcriptionLanguage`. Reading the language key before it is seeded
/// would make every grandfathered user look non-English. Wired accordingly in
/// `JotComposition.build`.
///
/// `@MainActor`-isolated because it reads `TranscriberHolder.defaultsKey` /
/// `.languageKey`, both MainActor-isolated; `JotComposition.build` (the only
/// production call site) is already MainActor, so the annotation is free.
@MainActor
enum NemotronAutoUpgradeMigration {

    /// One-shot sentinel. Set once the gate has been evaluated so later
    /// launches never re-evaluate (a user who manually switched off Nemotron
    /// after the upgrade must not be re-flagged).
    static let migratedKey = "jot.nemotron.autoUpgradeMigrated"

    /// Pending marker consumed by `TranscriberHolder.startPendingNemotronUpgradeIfNeeded()`
    /// / `JotAppWindow`. Distinct from `migratedKey`: the gate is evaluated
    /// once (`migratedKey`), but the download-then-flip work may need to
    /// **retry across launches** if the download fails — so this marker is only
    /// cleared on a *successful* swap, never on failure.
    static let autoUpgradePendingKey = "jot.nemotron.autoUpgradePending"

    /// Evaluate the auto-upgrade gate exactly once and, when it passes, set the
    /// pending marker. NEVER writes `jot.defaultModelID`.
    ///
    /// - Parameters:
    ///   - defaults: the UserDefaults store to read/write.
    ///   - autoUpgradeEligible: the hardware gate result. Defaults to the live
    ///     `HardwareTier.autoUpgradeToNemotronEligible`; tests inject an
    ///     explicit `Bool` so the chip/RAM facts don't have to be faked at the
    ///     sysctl level.
    /// - Returns: `true` when this call set the pending marker.
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults,
        autoUpgradeEligible: Bool = HardwareTier.autoUpgradeToNemotronEligible
    ) -> Bool {
        if defaults.bool(forKey: migratedKey) {
            return false
        }
        defer { defaults.set(true, forKey: migratedKey) }

        // 1. Hardware gate (≥ M2 Pro AND ≥ 24 GB, Apple Silicon).
        guard autoUpgradeEligible else { return false }

        // Superseded by `NemotronMultilingualMigration`: on ≥24 GB, English now
        // folds into the Nemotron multilingual "latin" ship instead of
        // `nemotron_en`. Since this gate and the multilingual gate are both
        // ≥24 GB, this short-circuits the nemotron_en auto-upgrade entirely.
        guard !HardwareTier.nemotronMultilingualEligible else { return false }

        // 2. Active language must be English. Read the seeded key directly;
        //    LanguageMigration runs before us, so a grandfathered English user
        //    already has `jot.transcriptionLanguage == "english"`.
        let language = defaults.string(forKey: TranscriberHolder.languageKey)
            .flatMap(LanguageChoice.init(rawValue:))
        guard language == .english else { return false }

        // 3. Stored model must resolve to a NON-Nemotron model. A user already
        //    on Nemotron needs no upgrade.
        let storedModel = defaults.string(forKey: TranscriberHolder.defaultsKey)
            .flatMap(ParakeetModelID.init(rawValue:))
        guard let storedModel, storedModel != .nemotron_en else { return false }

        defaults.set(true, forKey: autoUpgradePendingKey)
        return true
    }
}
