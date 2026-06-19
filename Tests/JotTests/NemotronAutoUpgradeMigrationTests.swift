import Foundation
import Testing
@testable import Jot

/// One-shot Nemotron auto-upgrade gate scenarios. Each test mints a clean
/// ephemeral `UserDefaults` (unique suite name per test) so cases don't bleed
/// into each other, runs `NemotronAutoUpgradeMigration.runIfNeeded` with an
/// explicit `autoUpgradeEligible` (the tier seam), and asserts that the pending
/// marker is set only when the full gate passes — and that
/// `jot.defaultModelID` is NEVER written by this migration.
@MainActor
@Suite(.serialized)
struct NemotronAutoUpgradeMigrationTests {

    private static func freshDefaults() -> UserDefaults {
        let name = "jot.tests.nemotron.autoupgrade.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Eligible hardware + English language + a non-Nemotron stored model (v2):
    /// the gate passes, the pending marker is set, and the stored model is left
    /// untouched.
    @Test func eligibleEnglishV2SetsPendingAndLeavesModelUntouched() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: true
        )

        #expect(wrote == true)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == true)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.migratedKey) == true)
        // CRUCIAL: the migration must not change the active model.
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue)
    }

    /// Eligible hardware + English language + a grandfathered v3 stored model:
    /// still a non-Nemotron English user → pending marker set.
    @Test func eligibleEnglishV3SetsPending() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: true
        )

        #expect(wrote == true)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
    }

    /// Already on Nemotron: no upgrade needed → no pending marker.
    @Test func englishAlreadyOnNemotronDoesNotSetPending() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.nemotron_en.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: true
        )

        #expect(wrote == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.migratedKey) == true)
    }

    /// Non-English (Japanese) user on eligible hardware: never auto-swapped.
    @Test func japaneseUserDoesNotSetPending() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.japanese.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.tdt_0_6b_ja.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: true
        )

        #expect(wrote == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == false)
    }

    /// European-language (v3) user on eligible hardware: never auto-swapped.
    @Test func europeanLanguageUserDoesNotSetPending() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.german.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: true
        )

        #expect(wrote == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == false)
    }

    /// Ineligible hardware (the tier seam injects `false`): even an English v2
    /// user is not auto-swapped.
    @Test func ineligibleHardwareDoesNotSetPending() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: false
        )

        #expect(wrote == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.migratedKey) == true)
    }

    /// Second run is a no-op even when the gate would otherwise pass: the
    /// sentinel short-circuits before any re-evaluation, so a user who manually
    /// switched off Nemotron after the upgrade is not re-flagged.
    @Test func secondRunIsNoOp() {
        let defaults = Self.freshDefaults()
        defaults.set(LanguageChoice.english.rawValue, forKey: TranscriberHolder.languageKey)
        defaults.set(ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        // First run sets pending + sentinel.
        _ = NemotronAutoUpgradeMigration.runIfNeeded(defaults: defaults, autoUpgradeEligible: true)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == true)

        // Simulate the upgrade completing (pending cleared) and the user
        // switching back to v2. The migration must NOT re-flag.
        defaults.set(false, forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(defaults: defaults, autoUpgradeEligible: true)

        #expect(wrote == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == false)
    }

    /// No language key seeded yet (defensive — LanguageMigration runs first in
    /// production, but the gate must not fire on a nil language).
    @Test func missingLanguageKeyDoesNotSetPending() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = NemotronAutoUpgradeMigration.runIfNeeded(
            defaults: defaults,
            autoUpgradeEligible: true
        )

        #expect(wrote == false)
        #expect(defaults.bool(forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey) == false)
    }
}
