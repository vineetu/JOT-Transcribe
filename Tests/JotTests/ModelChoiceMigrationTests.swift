import Foundation
import Testing
@testable import Jot

/// v1.7 pin migration scenarios from `docs/plans/streaming-option.md`
/// §3.4.4 + §11. Each test mints a clean ephemeral `UserDefaults`
/// (unique suite name per test) so cases don't bleed into each other,
/// runs `ModelChoiceMigration.runV17PinIfNeeded` with explicit inputs
/// for the §3.4.4 freshness signals, and asserts the four-step ordering.
@MainActor
@Suite(.serialized)
struct ModelChoiceMigrationV17Tests {

    // MARK: - Test infrastructure

    private static func freshDefaults() -> UserDefaults {
        let name = "jot.tests.modelchoice.v17.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Scenarios

    /// Fresh v1.7 install: no key, no caches, no recordings, `pinChecked`
    /// absent. Migration leaves the key absent (so v2.0 later detects
    /// fresh) but stamps `pinChecked` so a second launch with downloaded
    /// v3 doesn't retroactively pin.
    @Test func freshV17InstallDoesNotPin() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [],
            recordingsDirectoryEmpty: true
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == nil)
        #expect(defaults.bool(forKey: ModelChoiceMigration.pinCheckedKey) == true)
    }

    /// Returning v1.6.x → v1.7 user: no key but v3 is cached and
    /// recordings exist. Migration writes `tdt_0_6b_v3` to the key so
    /// v2.0's classifier later sees an explicit choice.
    @Test func returningUserPinsToV3() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.pinCheckedKey) == true)
    }

    /// User on v1.6.x with explicit JA key. v1.7 pin must NOT overwrite
    /// — JA users keep their JA key. `pinChecked` still flips so
    /// migration is a no-op on subsequent launches.
    @Test func explicitJAKeyIsPreserved() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_ja.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_ja],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_ja.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.pinCheckedKey) == true)
    }

    /// Recordings-only returning signal: no key, no cached bundles, but
    /// recordings exist on disk. Belt-and-suspenders detection: any one
    /// signal is enough to classify as returning. Migration pins to v3.
    @Test func recordingsOnlySignalPinsToV3() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.pinCheckedKey) == true)
    }

    /// Cache-only returning signal: no key, no recordings, but v3 is
    /// cached. Independent of the recordings signal — any one of the
    /// three §3.4.4 detectors should classify as returning. Validates
    /// the path where a user wiped recordings (or never saved any) but
    /// previously installed a model.
    @Test func cacheOnlySignalPinsToV3() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3],
            recordingsDirectoryEmpty: true
        )

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.pinCheckedKey) == true)
    }

    /// Fresh v1.7 install completes wizard step 3 (v3 downloads), then
    /// the user relaunches. On the second launch v3 is cached and
    /// `pinChecked` is already true, so migration is a no-op and the key
    /// stays absent — preserving v2.0's ability to recognize this user
    /// as a v1.7-skipper-equivalent fresh install.
    @Test func secondLaunchAfterFreshInstallIsNoOp() {
        let defaults = Self.freshDefaults()

        // First launch (fresh).
        _ = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [],
            recordingsDirectoryEmpty: true
        )
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == nil)
        #expect(defaults.bool(forKey: ModelChoiceMigration.pinCheckedKey) == true)

        // Second launch: v3 is now downloaded via wizard, but `pinChecked`
        // is already set so migration short-circuits before evaluating
        // the freshness heuristic.
        let wrote = ModelChoiceMigration.runV17PinIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3],
            recordingsDirectoryEmpty: true
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == nil)
    }
}

/// v2.0 first-launch classifier scenarios from §3.4.3 + §11.
@MainActor
@Suite(.serialized)
struct ModelChoiceMigrationV20Tests {

    private static func freshDefaults() -> UserDefaults {
        let name = "jot.tests.modelchoice.v20.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Pristine fresh v2.0 install: no key, no caches, no recordings.
    /// Classifier stamps the current default and the marker.
    @Test func freshInstallStampsStreamingDefault() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [],
            recordingsDirectoryEmpty: true
        )

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.v2DefaultStampedKey) == true)
    }

    /// v1.7-skipper: no key (the user never ran v1.7), but v3 is cached
    /// and recordings are present. The stale v2 helper now stamps the
    /// current default; the four-option migration is the canonical path.
    @Test func v17SkipperGetsV3() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.v2DefaultStampedKey) == true)
    }

    /// User upgraded from v1.7 with the pin already applied: explicit v3
    /// key set, `pinChecked` true. Classifier sees the explicit key,
    /// stamps `v2DefaultStamped`, and exits without overwriting.
    @Test func v17PinnedUserKeyPreserved() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)
        defaults.set(true, forKey: ModelChoiceMigration.pinCheckedKey)

        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.v2DefaultStampedKey) == true)
    }

    /// Cache-only returning signal at v2.0 launch: no key, no recordings,
    /// but v3 is cached. The stale v2 helper now stamps the current default.
    @Test func cacheOnlySignalGrandfathersV3() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3],
            recordingsDirectoryEmpty: true
        )

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.v2DefaultStampedKey) == true)
    }

    /// JA user (or any explicit-key user) upgrading to v2.0. Classifier
    /// must not overwrite the existing key.
    @Test func explicitJAKeyIsPreserved() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_ja.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_ja],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_ja.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.v2DefaultStampedKey) == true)
    }

    /// Second launch on v2.0 after a prior classifier run: the marker
    /// short-circuits the helper before any freshness re-evaluation
    /// could flip the user's primary.
    @Test func secondLaunchIsNoOp() {
        let defaults = Self.freshDefaults()

        // First launch: streaming gets stamped.
        _ = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [],
            recordingsDirectoryEmpty: true
        )
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)

        // Second launch: recordings now exist (user dictated something),
        // but the marker prevents reclassification.
        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v3_eou_streaming],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
    }

    /// Soft-reset preservation (§11 R15) — when reset code preserves
    /// `jot.defaultModelID` and `v2DefaultStamped` across the wipe,
    /// the next-launch classifier sees them and no-ops, keeping the
    /// user on streaming. (Phase 3 wires `ResetActions.softReset` to do
    /// the preservation; this test asserts the classifier-side contract
    /// the reset code relies on.)
    @Test func softResetPreservedKeyIsHonored() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)
        defaults.set(true, forKey: ModelChoiceMigration.v2DefaultStampedKey)

        let wrote = ModelChoiceMigration.runV20DefaultStampIfNeeded(
            defaults: defaults,
            installedModelIDs: [.tdt_0_6b_v2_en_streaming],
            recordingsDirectoryEmpty: false
        )

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue)
    }
}

@MainActor
@Suite(.serialized)
struct ModelChoiceMigrationFourOptionTests {

    private static func freshDefaults() -> UserDefaults {
        let name = "jot.tests.modelchoice.four.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func visibleCasesAreTheFourUserSelectableOptions() {
        let visible: [ParakeetModelID] = [
            .tdt_0_6b_v3_eou_streaming,
            .tdt_0_6b_ja,
            .tdt_0_6b_v2_en_streaming,
            .nemotron_en,
        ]

        #expect(ParakeetModelID.visibleCases == visible)
        for id in ParakeetModelID.allCases {
            #expect(id.isUserSelectable == visible.contains(id))
        }
        #expect(ParakeetModelID.tdt_0_6b_v2_en_streaming.isDeprecated == true)
        // v3+Nemotron was demoted to migration-anchor (not user-selectable)
        // in v1.12 but it is not classified as deprecated — deprecation is
        // reserved for legacy options the user can still pick from the UI.
        #expect(ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.isUserSelectable == false)
        #expect(ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.isDeprecated == false)
    }

    @Test func freshInstallDefaultsToV3EouStreaming() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runFourOptionMigrationIfNeeded(defaults: defaults)

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionMigratedKey) == true)
        #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) == true)
    }

    @Test func legacyV3VariantsMapToV3EouStreaming() {
        for legacy in [ParakeetModelID.tdt_0_6b_v3, .tdt_0_6b_v3_int4] {
            let defaults = Self.freshDefaults()
            defaults.set(legacy.rawValue, forKey: TranscriberHolder.defaultsKey)

            let wrote = ModelChoiceMigration.runFourOptionMigrationIfNeeded(defaults: defaults)

            #expect(wrote == true)
            #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
            #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) == true)
        }
    }

    @Test func legacyV3PlusNemotronMapsToV3EouStreaming() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = ModelChoiceMigration.runFourOptionMigrationIfNeeded(defaults: defaults)

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) == true)
    }

    @Test func legacyEouIsPreservedAsDeprecatedSelectableOption() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = ModelChoiceMigration.runFourOptionMigrationIfNeeded(defaults: defaults)

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v2_en_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) == false)
    }

    @Test func japaneseAndCurrentCasesArePreserved() {
        for current in [
            ParakeetModelID.tdt_0_6b_ja,
            .tdt_0_6b_v2_en_streaming,
            .tdt_0_6b_v3_eou_streaming,
            .nemotron_en,
        ] {
            let defaults = Self.freshDefaults()
            defaults.set(current.rawValue, forKey: TranscriberHolder.defaultsKey)

            let wrote = ModelChoiceMigration.runFourOptionMigrationIfNeeded(defaults: defaults)

            #expect(wrote == false)
            #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == current.rawValue)
            #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) == false)
        }
    }
}

@MainActor
@Suite(.serialized)
struct ModelChoiceMigrationEouRenameTests {

    private static func freshDefaults() -> UserDefaults {
        let name = "jot.tests.modelchoice.eou.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func rewritesNemotronStreamingToEouStreaming() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        let wrote = ModelChoiceMigration.runV12EouRenameIfNeeded(defaults: defaults)

        #expect(wrote == true)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)
        #expect(defaults.bool(forKey: ModelChoiceMigration.eouRenameMigratedKey) == true)
        #expect(defaults.bool(forKey: ModelChoiceMigration.fourOptionDownloadPendingKey) == true)
    }

    @Test func leavesOtherCasesAlone() {
        for unchanged in [
            ParakeetModelID.tdt_0_6b_ja,
            .tdt_0_6b_v2_en_streaming,
            .tdt_0_6b_v3_eou_streaming,
            .nemotron_en,
        ] {
            let defaults = Self.freshDefaults()
            defaults.set(unchanged.rawValue, forKey: TranscriberHolder.defaultsKey)

            let wrote = ModelChoiceMigration.runV12EouRenameIfNeeded(defaults: defaults)

            #expect(wrote == false)
            #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == unchanged.rawValue)
            #expect(defaults.bool(forKey: ModelChoiceMigration.eouRenameMigratedKey) == true)
        }
    }

    @Test func secondLaunchIsNoOp() {
        let defaults = Self.freshDefaults()
        defaults.set(ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)

        // First launch: rewrites the value and sets the marker.
        _ = ModelChoiceMigration.runV12EouRenameIfNeeded(defaults: defaults)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_eou_streaming.rawValue)

        // Hypothetically the user manually flipped back to the legacy
        // pairing (e.g. through a debug build). The migration must NOT
        // rewrite again, because the marker is set.
        defaults.set(ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.rawValue, forKey: TranscriberHolder.defaultsKey)
        let wrote = ModelChoiceMigration.runV12EouRenameIfNeeded(defaults: defaults)

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == ParakeetModelID.tdt_0_6b_v3_nemotron_streaming.rawValue)
    }

    @Test func noStoredKeyIsNoOp() {
        let defaults = Self.freshDefaults()

        let wrote = ModelChoiceMigration.runV12EouRenameIfNeeded(defaults: defaults)

        #expect(wrote == false)
        #expect(defaults.string(forKey: TranscriberHolder.defaultsKey) == nil)
        #expect(defaults.bool(forKey: ModelChoiceMigration.eouRenameMigratedKey) == true)
    }
}
