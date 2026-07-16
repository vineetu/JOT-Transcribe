#if DEBUG
import Foundation
import os

/// DEBUG-only runtime harness for the **model-download retry state machine** in
/// `TranscriberHolder` — the `requestSwitch` → `beginPendingSwitch` →
/// `runPendingSwitchLoop` download-then-flip pipeline and its `.downloading` /
/// `.retrying` / `.failed` `PendingSwitch` transitions, plus the persisted
/// cross-launch intent (`jot.pendingModelDownloadIntent`) and
/// `rearmPendingDownloadIntentIfNeeded()`.
///
/// Mirrors the `ModelSwitchTests` / `AdvancedFlagTests` pattern — no XCTest
/// dependency (Jot's XCTest target is currently broken). `runAll()` is called
/// once from `AppDelegate.applicationDidFinishLaunching` in DEBUG so a
/// regression traps at launch.
///
/// Unlike `ModelSwitchTests` (which only exercises the *pure* routing predicate)
/// this drives the **async, MainActor, network-bound** loop end-to-end against
/// an injected `FakeDownloader` + a throwaway `ModelCache` rooted in a temp dir
/// + a per-case `UserDefaults(suiteName:)`. Because the harness must `await`,
/// `runAll()` launches a detached `@MainActor` task rather than blocking launch.
///
/// **Critical:** the loop's auto-retry uses `Task.sleep(30s+)`. These tests
/// NEVER block on real backoff — the retry-to-success case is driven via
/// `retryPendingSwitch()` (which restarts the loop from a fresh attempt,
/// skipping the sleep), and every wait is a bounded ~2s poll in 10 ms steps.
enum DownloadRetryTests {

    // MARK: - Entry point

    static func runAll() {
        // Launch on the MainActor (TranscriberHolder is @MainActor) without
        // blocking `applicationDidFinishLaunching`. A failed `assert` inside
        // still traps the process, surfacing the regression at launch.
        Task { @MainActor in
            await test_retriableFailureThenSuccess()
            await test_supersession()
            await test_cancelClearsIntent()
            await test_rearmInstalledFlipsImmediately()
            await test_rearmFailedDoesNotReArmLoop()
            await test_nonRetriableKeepsOldModel()
        }
    }

    // MARK: - Model fixtures

    /// Seeded primary (matches `TranscriberHolder`'s own init default).
    private static let primaryModel: ParakeetModelID = .tdt_0_6b_v3_eou_streaming
    /// A distinct, not-installed switch target.
    private static let targetA: ParakeetModelID = .tdt_0_6b_ja
    /// A second distinct target for the supersession case.
    private static let targetB: ParakeetModelID = .tdt_0_6b_v2_en_streaming
    /// A model whose on-disk bundle we can cheaply fake as "installed"
    /// (its `isCached` check is a plain file-presence list, not a FluidAudio
    /// `modelsExist` probe).
    private static let installedTarget: ParakeetModelID = .nemotron_multilingual_latin

    // MARK: - (a) Retriable failure then success

    /// A `serverUnavailable` thrown once → holder enters `.retrying` on the
    /// current model; a re-attempt (driven via `retryPendingSwitch()`, NOT the
    /// 30 s backoff) flips the primary to the target AND clears the persisted
    /// intent key.
    @MainActor
    static func test_retriableFailureThenSuccess() async {
        let (defaults, suite) = freshDefaults()
        let cache = freshCache()
        let fake = FakeDownloader(.throwThenSucceed(error: .serverUnavailable, times: 1))
        let holder = makeHolder(cache: cache, defaults: defaults, fake: fake)

        await holder.requestSwitch(to: targetA)

        // First attempt throws serverUnavailable → the loop publishes `.retrying`
        // and then sleeps on backoff. We observe the `.retrying` transition, then
        // drive the retry immediately.
        let reachedRetrying = await poll {
            if case .retrying(let t, _, _, let err, let next) = holder.pendingSwitch {
                return t == targetA && err.logTag == "server_unavailable" && next != nil
            }
            return false
        }
        assert(reachedRetrying, "(a) a retriable serverUnavailable must transition to .retrying with a nextRetryAt")
        assert(holder.primaryModelID == primaryModel, "(a) primary must stay on the current model while retrying")
        assert(defaults.data(forKey: TranscriberHolder.pendingIntentKey) != nil,
               "(a) the persisted intent must survive a retriable failure")

        // Re-attempt now (skips the remaining backoff). Second attempt succeeds.
        holder.retryPendingSwitch()

        let flipped = await poll { holder.primaryModelID == targetA && holder.pendingSwitch == nil }
        assert(flipped, "(a) a successful re-attempt must flip the primary to the target and clear pendingSwitch")
        assert(defaults.data(forKey: TranscriberHolder.pendingIntentKey) == nil,
               "(a) success must CLEAR the persisted intent key")
        assert(defaults.string(forKey: TranscriberHolder.defaultsKey) == targetA.rawValue,
               "(a) success must persist the new primary to jot.defaultModelID")
        assert(fake.callCount == 2, "(a) exactly two download attempts (one fail, one success)")

        cleanup(cache: cache, defaults: defaults, suite: suite)
    }

    // MARK: - (b) Supersession

    /// A second `requestSwitch(to: B)` while a switch to A is mid-flight → the A
    /// loop no-ops (via `switchGeneration`); the final primary / pending reflect
    /// B only, never A.
    @MainActor
    static func test_supersession() async {
        let (defaults, suite) = freshDefaults()
        let cache = freshCache()
        // A's download hangs (cancellable) so it stays genuinely mid-flight;
        // any other target succeeds instantly.
        let fake = FakeDownloader(.hangUntilCancelled(forTarget: targetA))
        let holder = makeHolder(cache: cache, defaults: defaults, fake: fake)

        await holder.requestSwitch(to: targetA)
        // Wait until A's download is actually in flight (hanging).
        let aInFlight = await poll {
            if case .downloading(let t, _, _, _) = holder.pendingSwitch { return t == targetA }
            return false
        }
        assert(aInFlight, "(b) precondition: the switch to A must be mid-download")
        let aStarted = await poll { fake.callCount >= 1 }
        assert(aStarted, "(b) precondition: A's download must have been dispatched")

        // Supersede with B. B succeeds instantly; A's generation is now stale.
        await holder.requestSwitch(to: targetB)

        let landedOnB = await poll { holder.primaryModelID == targetB && holder.pendingSwitch == nil }
        assert(landedOnB, "(b) the final primary must be B with no pending switch")
        assert(holder.primaryModelID != targetA, "(b) A must never become the primary")
        assert(defaults.string(forKey: TranscriberHolder.defaultsKey) == targetB.rawValue,
               "(b) only B's selection may be persisted")

        holder.cancelPendingSwitch()
        cleanup(cache: cache, defaults: defaults, suite: suite)
    }

    // MARK: - (c) Cancel clears intent

    /// `cancelPendingSwitch()` removes the persisted intent key and clears
    /// `pendingSwitch`.
    @MainActor
    static func test_cancelClearsIntent() async {
        let (defaults, suite) = freshDefaults()
        let cache = freshCache()
        // Hang so the switch stays pending until we cancel it.
        let fake = FakeDownloader(.hangUntilCancelled(forTarget: targetA))
        let holder = makeHolder(cache: cache, defaults: defaults, fake: fake)

        await holder.requestSwitch(to: targetA)
        let pending = await poll {
            holder.pendingSwitch != nil
                && defaults.data(forKey: TranscriberHolder.pendingIntentKey) != nil
        }
        assert(pending, "(c) precondition: an in-flight switch persists intent + sets pendingSwitch")

        holder.cancelPendingSwitch()

        assert(holder.pendingSwitch == nil, "(c) cancel must clear pendingSwitch")
        assert(defaults.data(forKey: TranscriberHolder.pendingIntentKey) == nil,
               "(c) cancel must remove the persisted intent key")
        assert(holder.primaryModelID == primaryModel, "(c) cancel must not change the primary")

        cleanup(cache: cache, defaults: defaults, suite: suite)
    }

    // MARK: - (d) Rearm — installed target flips immediately

    /// With a persisted intent whose model is ALREADY installed,
    /// `rearmPendingDownloadIntentIfNeeded()` (run from `init`) flips
    /// immediately with no download and retires the intent.
    @MainActor
    static func test_rearmInstalledFlipsImmediately() async {
        let (defaults, suite) = freshDefaults()
        let cache = freshCache()
        installFakeBundle(installedTarget, in: cache)

        // Precondition: the faked bundle reads as installed. If FluidAudio's
        // file list ever diverges this traps loudly (see report — this is the
        // one assertion coupled to the SDK's on-disk contract).
        assert(cache.isCached(installedTarget),
               "(d1) precondition: the faked bundle must read as installed")

        // Seed the persisted intent BEFORE constructing the holder so init's
        // re-arm sees it. Mirror the private Codable payload shape exactly.
        persistIntent(model: installedTarget, language: nil, into: defaults)

        let fake = FakeDownloader(.alwaysThrow(.offline)) // must never be called
        let holder = makeHolder(cache: cache, defaults: defaults, fake: fake)

        let flipped = await poll { holder.primaryModelID == installedTarget }
        assert(flipped, "(d1) an already-installed intent model must flip immediately on re-arm")
        assert(holder.pendingSwitch == nil, "(d1) an immediate flip must not leave a pending switch")
        assert(defaults.data(forKey: TranscriberHolder.pendingIntentKey) == nil,
               "(d1) a satisfied intent must be cleared")
        assert(fake.callCount == 0, "(d1) an already-installed target must NOT trigger a download")

        cleanup(cache: cache, defaults: defaults, suite: suite)
    }

    // MARK: - (d) Rearm — a .failed state does NOT re-arm a loop

    /// A holder parked in `.failed` (offline / non-retriable) does not re-arm a
    /// background download loop when `rearmPendingDownloadIntentIfNeeded()` is
    /// called: the `pendingSwitch != nil` guard short-circuits it, so no new
    /// download attempt is dispatched.
    @MainActor
    static func test_rearmFailedDoesNotReArmLoop() async {
        let (defaults, suite) = freshDefaults()
        let cache = freshCache()
        let fake = FakeDownloader(.alwaysThrow(.offline))
        let holder = makeHolder(cache: cache, defaults: defaults, fake: fake)

        await holder.requestSwitch(to: targetA)
        let failed = await poll {
            if case .failed(let t, _, _, let err) = holder.pendingSwitch {
                return t == targetA && err.logTag == "offline"
            }
            return false
        }
        assert(failed, "(d2) precondition: an offline error parks the switch in .failed")
        let callsBefore = fake.callCount
        assert(defaults.data(forKey: TranscriberHolder.pendingIntentKey) != nil,
               "(d2) a .failed switch keeps its persisted intent")

        // Explicitly re-arm: the pendingSwitch != nil guard must make this a no-op.
        holder.rearmPendingDownloadIntentIfNeeded()

        // Give any (erroneously) spawned loop a chance to dispatch a download.
        _ = await poll(timeout: 0.3) { false }
        let callsAfter = fake.callCount
        assert(callsAfter == callsBefore, "(d2) re-arm over a .failed state must NOT start a new download loop")
        if case .failed = holder.pendingSwitch {} else {
            assert(false, "(d2) the state must remain .failed after a guarded re-arm")
        }
        assert(holder.primaryModelID == primaryModel, "(d2) the primary must stay unchanged")

        holder.cancelPendingSwitch()
        cleanup(cache: cache, defaults: defaults, suite: suite)
    }

    // MARK: - (e) Non-retriable keeps old model

    /// An `offline` error → `.failed`, the primary is unchanged, and no
    /// automatic retry loop is scheduled (the attempt count stays put and the
    /// state never drifts to `.retrying`).
    @MainActor
    static func test_nonRetriableKeepsOldModel() async {
        let (defaults, suite) = freshDefaults()
        let cache = freshCache()
        let fake = FakeDownloader(.alwaysThrow(.offline))
        let holder = makeHolder(cache: cache, defaults: defaults, fake: fake)

        await holder.requestSwitch(to: targetA)
        let failed = await poll {
            if case .failed(let t, let from, _, let err) = holder.pendingSwitch {
                return t == targetA && from == primaryModel && err.logTag == "offline"
            }
            return false
        }
        assert(failed, "(e) a non-retriable offline error must land in .failed(from: currentModel)")
        assert(holder.primaryModelID == primaryModel, "(e) the primary must stay on the old model")
        assert(defaults.string(forKey: TranscriberHolder.defaultsKey) == nil,
               "(e) a failed switch must not persist a new primary")

        // No auto-retry loop: after a short wait the attempt count is still 1
        // and the state has not drifted to .retrying.
        let callsAfterFailure = fake.callCount
        assert(callsAfterFailure == 1, "(e) exactly one attempt should have been made")
        _ = await poll(timeout: 0.3) { false }
        assert(fake.callCount == 1, "(e) a non-retriable failure must NOT schedule an automatic retry")
        if case .failed = holder.pendingSwitch {} else {
            assert(false, "(e) the state must remain .failed (never .retrying) for a non-retriable error")
        }

        cleanup(cache: cache, defaults: defaults, suite: suite)
    }

    // MARK: - Harness plumbing

    @MainActor
    private static func makeHolder(
        cache: ModelCache,
        defaults: UserDefaults,
        fake: FakeDownloader
    ) -> TranscriberHolder {
        TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber() },
            downloaderFactory: { _ in fake },
            installedModelIDs: []
        )
    }

    private static func freshDefaults() -> (UserDefaults, String) {
        let suite = "jot.tests.downloadretry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private static func freshCache() -> ModelCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-downloadretry-\(UUID().uuidString)", isDirectory: true)
        return ModelCache(root: root)
    }

    private static func cleanup(cache: ModelCache, defaults: UserDefaults, suite: String) {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: cache.root)
    }

    /// Mirrors `TranscriberHolder.PendingDownloadIntent` (private) so we can seed
    /// a persisted intent the holder's `loadPendingIntent()` will decode.
    private struct IntentMirror: Codable { let model: String; let language: String? }

    @MainActor
    private static func persistIntent(
        model: ParakeetModelID,
        language: LanguageChoice?,
        into defaults: UserDefaults
    ) {
        let payload = IntentMirror(model: model.rawValue, language: language?.rawValue)
        let data = try! JSONEncoder().encode(payload)
        defaults.set(data, forKey: TranscriberHolder.pendingIntentKey)
    }

    /// Cheaply fake a Nemotron-multilingual bundle as "installed" by creating the
    /// exact files `ModelCache.streamingBundleExists` checks for that variant
    /// (core files + one fused decode path). Only valid for the multilingual
    /// ships, whose presence check is a plain file list (not a FluidAudio probe).
    private static func installFakeBundle(_ id: ParakeetModelID, in cache: ModelCache) {
        let dir = cache.cacheURL(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = [
            "preprocessor.mlmodelc", "encoder.mlmodelc",
            "metadata.json", "tokenizer.json",
            "decoder_joint.mlmodelc",
        ]
        for name in files {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
    }

    /// Bounded poll: spin up to `timeout` seconds in 10 ms steps waiting for
    /// `condition`. Never sleeps for a fixed duration on the happy path.
    @MainActor
    private static func poll(
        timeout: TimeInterval = 2.0,
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        return await condition()
    }
}

// MARK: - Fakes

/// Configurable `ModelDownloading` double. Records how many times it was called
/// so tests can assert attempt counts. `@unchecked Sendable` with an `NSLock`
/// so `callCount` is readable synchronously from a MainActor poll closure while
/// `downloadIfMissing` may run off-actor.
private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    enum Behavior {
        /// Succeed immediately.
        case succeed
        /// Always throw the given error.
        case alwaysThrow(ModelDownloadError)
        /// Throw `error` for the first `times` calls, then succeed.
        case throwThenSucceed(error: ModelDownloadError, times: Int)
        /// Block (cancellably) while the requested id is `forTarget`; succeed
        /// instantly for any other id. Used to hold a switch genuinely
        /// mid-flight so a later switch can supersede it.
        case hangUntilCancelled(forTarget: ParakeetModelID)
    }

    private let behavior: Behavior
    // OSAllocatedUnfairLock's `withLock` is a synchronous scoped API that is
    // safe to call from async contexts (unlike NSLock.lock()/unlock(), which
    // Swift 6 forbids in async code).
    private let _callCount = OSAllocatedUnfairLock(initialState: 0)

    var callCount: Int { _callCount.withLock { $0 } }

    init(_ behavior: Behavior) { self.behavior = behavior }

    func downloadIfMissing(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let n = _callCount.withLock { $0 += 1; return $0 }

        switch behavior {
        case .succeed:
            progress(1.0)
        case .alwaysThrow(let error):
            throw error
        case .throwThenSucceed(let error, let times):
            if n <= times { throw error }
            progress(1.0)
        case .hangUntilCancelled(let forTarget):
            if id == forTarget {
                // Cancellable "forever": supersession/cancel wakes this and it
                // throws CancellationError, which the loop's guard no-ops.
                try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
            } else {
                progress(1.0)
            }
        }
    }
}

/// No-op `Transcribing` so `setPrimary`'s `ensureLoaded()` / `isReady` never
/// touch CoreML.
private struct FakeTranscriber: Transcribing {
    func ensureLoaded() async throws {}
    func transcribe(_ samples: [Float], recordsProvenance: Bool) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", rawText: "", duration: 0, processingTime: 0, confidence: 1)
    }
    func transcribeFile(_ url: URL, recordsProvenance: Bool) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", rawText: "", duration: 0, processingTime: 0, confidence: 1)
    }
    var isReady: Bool { get async { true } }
}
#endif
