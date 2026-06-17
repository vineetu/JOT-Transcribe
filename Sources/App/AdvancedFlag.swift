import Foundation

/// One-shot launch migration + storage-key contract for the "Show
/// advanced features" toggle introduced in v1.13.
///
/// Storage keys:
///   * `jot.advanced.enabled`  — the master toggle. Bool, default `false`.
///   * `jot.advanced.migrated` — write-once sentinel that gates the
///     migration. Bool, default `false`.
///
/// On first launch after the v1.13 update, `migrateIfNeeded()` seeds
/// `jot.advanced.enabled` from the existing-user signal
/// (`jot.setupComplete`):
///   * Existing users (wizard already complete) get Advanced ON — they
///     see no change to their sidebar / shortcuts / Ask Jot routing.
///   * Fresh installs (wizard not yet run) get Advanced OFF — slim
///     mode by default, and they STAY off after completing the Setup
///     Wizard. New installs only get Advanced ON by opting in via
///     Settings → General. (`FirstRunState.markComplete()` deliberately
///     does not flip this flag.)
///
/// IMPORTANT: the existing-user seed above is the grandfather/upgrade
/// migration — it must be preserved so longtime users upgrading from a
/// pre-advanced-flag build keep full features. Only the new-install
/// wizard-completion flip was removed.
///
/// The sentinel `jot.advanced.migrated` ensures we only seed once. After
/// the first launch, the user's explicit toggle choice (any subsequent
/// flip) is authoritative — we never overwrite it.
enum AdvancedFlag {
    static let storageKey = "jot.advanced.enabled"
    static let migratedKey = "jot.advanced.migrated"

    /// Run once at app launch, before the SwiftUI scene materializes.
    /// Idempotent — guarded by `jot.advanced.migrated`.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let existingUser = defaults.bool(forKey: "jot.setupComplete")
        defaults.set(existingUser, forKey: storageKey)
        defaults.set(true, forKey: migratedKey)
    }
}
