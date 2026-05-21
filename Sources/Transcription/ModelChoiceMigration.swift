import Foundation

/// One-shot UserDefaults migrations that decide which `ParakeetModelID` is
/// the user's primary at launch.
///
/// Two helpers, run at different release boundaries:
///
/// - `runV17PinIfNeeded` — v1.7's quiet pin. Writes `jot.defaultModelID =
///   "tdt_0_6b_v3"` for *returning* users with no explicit key, so v2.0's
///   classifier later sees an explicit choice and never silently swaps the
///   user onto streaming. Fresh v1.7 installs leave the key absent.
///
/// - `runV20DefaultStampIfNeeded` — v2.0's first-launch classifier. Writes
///   either the streaming default (genuine fresh install) or v3 (returning
///   user who skipped v1.7). Persists the result so the choice doesn't drift
///   between launches as the freshness heuristic flips on first recording.
///
/// Both share the same `isFreshInstall` heuristic (§3.4.4): any one of an
/// explicit key, a cached v3/JA bundle, or a non-empty recordings directory
/// classifies the user as returning. `installedModelIDs` and
/// `recordingsDirectoryEmpty` are passed in so tests can stub them without
/// touching the dev/CI machine's real cache or `~/Library/Application
/// Support/Jot/Recordings/`.
///
/// Both migrations are idempotent — they record `pinChecked` /
/// `v2DefaultStamped` markers and exit early on subsequent launches.
///
/// `@MainActor`-isolated because the migration reads
/// `TranscriberHolder.defaultsKey`, which is itself MainActor-isolated.
/// `JotComposition.build` is the only call site and is already MainActor,
/// so the annotation is free.
@MainActor
enum ModelChoiceMigration {

    /// UserDefaults key marking that v1.7's one-shot pin migration has
    /// already evaluated this user. Set on every v1.7+ launch so a fresh
    /// install that later downloads v3 in the wizard doesn't get
    /// retroactively pinned on its second launch.
    static let pinCheckedKey = "jot.modelChoice.pinChecked"

    /// UserDefaults key marking that v2.0's first-launch classifier has run.
    /// Without this marker, the classifier would re-evaluate every launch
    /// and silently flip the user's primary as recordings accumulate
    /// (fresh → returning) — see §3.4.3.
    static let v2DefaultStampedKey = "jot.modelChoice.v2DefaultStamped"

    /// UserDefaults key marking that the four-option Nemotron picker
    /// migration has run. This migration intentionally does not delete old
    /// cache directories; shared/orphan cache cleanup is a future explicit
    /// storage-management task.
    static let fourOptionMigratedKey = "jot.modelChoice.fourOptionMigrated"

    /// One-shot marker consumed by `TranscriberHolder`/`JotAppWindow` to
    /// download the newly selected post-migration model with visible progress.
    static let fourOptionDownloadPendingKey = "jot.modelChoice.fourOptionDownloadPending"

    /// Collapse legacy persisted model choices into the current four-option
    /// picker. Fresh installs with no stored key land on the new default:
    /// multilingual Parakeet v3 final transcript with Nemotron English
    /// live preview.
    ///
    /// - Returns: `true` when this call wrote `jot.defaultModelID`.
    @discardableResult
    static func runFourOptionMigrationIfNeeded(defaults: UserDefaults) -> Bool {
        if defaults.bool(forKey: fourOptionMigratedKey) {
            return false
        }
        defer { defaults.set(true, forKey: fourOptionMigratedKey) }

        let stored = defaults.string(forKey: TranscriberHolder.defaultsKey)
            .flatMap(ParakeetModelID.init(rawValue:))

        let target: ParakeetModelID
        switch stored {
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, nil:
            target = .tdt_0_6b_v3_nemotron_streaming
        case .tdt_0_6b_v2_en_streaming:
            target = .tdt_0_6b_v2_en_streaming
        case .tdt_0_6b_ja:
            target = .tdt_0_6b_ja
        case .tdt_0_6b_v3_nemotron_streaming:
            target = .tdt_0_6b_v3_nemotron_streaming
        case .nemotron_en:
            target = .nemotron_en
        }

        if stored == target {
            return false
        }
        defaults.set(target.rawValue, forKey: TranscriberHolder.defaultsKey)
        defaults.set(true, forKey: fourOptionDownloadPendingKey)
        return true
    }

    /// v1.7 pin. Idempotent: records `pinChecked = true` on every run, even
    /// when the body short-circuits on an existing explicit key, so a second
    /// launch never re-classifies the user.
    ///
    /// - Returns: `true` when this call wrote `jot.defaultModelID`. Tests
    ///   read this to assert the four-step ordering. Production callers can
    ///   ignore the return value.
    @discardableResult
    static func runV17PinIfNeeded(
        defaults: UserDefaults,
        installedModelIDs: Set<ParakeetModelID>,
        recordingsDirectoryEmpty: Bool
    ) -> Bool {
        if defaults.bool(forKey: pinCheckedKey) {
            return false
        }
        defer { defaults.set(true, forKey: pinCheckedKey) }

        if defaults.string(forKey: TranscriberHolder.defaultsKey) != nil {
            return false
        }
        if isFreshInstall(
            defaults: defaults,
            installedModelIDs: installedModelIDs,
            recordingsDirectoryEmpty: recordingsDirectoryEmpty
        ) {
            return false
        }
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)
        return true
    }

    /// Legacy v2.0 first-launch classifier (§3.4.3). Retained for tests and
    /// rollback history; current launch code uses the four-option migration
    /// above.
    ///
    /// 1. `v2DefaultStamped == true` → no-op (already classified).
    /// 2. Explicit `jot.defaultModelID` already set → set the marker
    ///    and exit, leaving the user's choice intact (covers v1.7
    ///    pinned users, JA users, and post-v2.0 manual changes).
    /// 3. No explicit key → write the current default
    ///    `tdt_0_6b_v3_nemotron_streaming`.
    ///
    /// Persisting the classification is what prevents drift: a naive
    /// read-only fallback on `nil` would re-evaluate every launch and
    /// silently swap the user's primary as recordings accumulate.
    ///
    /// - Returns: `true` when this call wrote `jot.defaultModelID`.
    @discardableResult
    static func runV20DefaultStampIfNeeded(
        defaults: UserDefaults,
        installedModelIDs: Set<ParakeetModelID>,
        recordingsDirectoryEmpty: Bool
    ) -> Bool {
        if defaults.bool(forKey: v2DefaultStampedKey) {
            return false
        }
        defer { defaults.set(true, forKey: v2DefaultStampedKey) }

        if defaults.string(forKey: TranscriberHolder.defaultsKey) != nil {
            return false
        }
        let target: ParakeetModelID = .tdt_0_6b_v3_nemotron_streaming
        defaults.set(target.rawValue, forKey: TranscriberHolder.defaultsKey)
        return true
    }

    /// Shared §3.4.4 freshness heuristic. Returns `true` only when *all*
    /// returning-user signals are absent — no explicit key, no cached
    /// Parakeet bundle, no recordings on disk.
    static func isFreshInstall(
        defaults: UserDefaults,
        installedModelIDs: Set<ParakeetModelID>,
        recordingsDirectoryEmpty: Bool
    ) -> Bool {
        if defaults.string(forKey: TranscriberHolder.defaultsKey) != nil { return false }
        if !installedModelIDs.isEmpty { return false }
        if !recordingsDirectoryEmpty { return false }
        return true
    }
}
