#if DEBUG
import Foundation

/// DEBUG-only runtime tests for `AdvancedFlag.migrateIfNeeded(...)`.
///
/// Mirrors the `DockActivationPolicyTests` / `HelpInfraTests` pattern —
/// no XCTest dependency, the suite is called once from
/// `AppDelegate.applicationDidFinishLaunching` in DEBUG so misses fire
/// at launch. Each test uses an in-memory `UserDefaults(suiteName:)` so
/// nothing leaks into the standard domain.
enum AdvancedFlagTests {
    static func runAll() {
        test_freshInstall_seedsAdvancedOff_andMarksMigrated()
        test_existingUser_seedsAdvancedOn_andMarksMigrated()
        test_secondCall_isNoOp_andDoesNotOverwriteUserChoice()
    }

    /// Fresh install: `setupComplete = false` at first launch.
    /// Migration must seed `advanced = false` and set `migrated = true`.
    static func test_freshInstall_seedsAdvancedOff_andMarksMigrated() {
        let defaults = makeIsolatedDefaults()
        // Default state: neither key set, setupComplete also absent.
        AdvancedFlag.migrateIfNeeded(defaults: defaults)
        assert(
            defaults.bool(forKey: AdvancedFlag.storageKey) == false,
            "Fresh install should seed Advanced OFF; got \(defaults.bool(forKey: AdvancedFlag.storageKey))"
        )
        assert(
            defaults.bool(forKey: AdvancedFlag.migratedKey) == true,
            "Migration sentinel must be set after first run"
        )
    }

    /// Existing user (already completed wizard on a prior version).
    /// Migration must seed `advanced = true` so their sidebar looks
    /// unchanged after the v1.13 update.
    static func test_existingUser_seedsAdvancedOn_andMarksMigrated() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "jot.setupComplete")
        AdvancedFlag.migrateIfNeeded(defaults: defaults)
        assert(
            defaults.bool(forKey: AdvancedFlag.storageKey) == true,
            "Existing user should seed Advanced ON; got \(defaults.bool(forKey: AdvancedFlag.storageKey))"
        )
        assert(
            defaults.bool(forKey: AdvancedFlag.migratedKey) == true,
            "Migration sentinel must be set after first run"
        )
    }

    /// Second call must be a no-op — once the sentinel is set, the
    /// migration must NOT overwrite a user's later choice (e.g. they
    /// flipped Advanced off and quit; the next launch must preserve
    /// that).
    static func test_secondCall_isNoOp_andDoesNotOverwriteUserChoice() {
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: "jot.setupComplete")
        AdvancedFlag.migrateIfNeeded(defaults: defaults)
        // Simulate a user flipping Advanced off after the migration.
        defaults.set(false, forKey: AdvancedFlag.storageKey)
        // A second call should NOT overwrite the user's choice.
        AdvancedFlag.migrateIfNeeded(defaults: defaults)
        assert(
            defaults.bool(forKey: AdvancedFlag.storageKey) == false,
            "Second migration call must not overwrite the user's stored choice; got \(defaults.bool(forKey: AdvancedFlag.storageKey))"
        )
    }

    // MARK: - Helpers

    private static func makeIsolatedDefaults() -> UserDefaults {
        // Unique suite per call so tests don't observe each other's writes.
        let suite = "com.jot.tests.advancedFlag.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}
#endif
