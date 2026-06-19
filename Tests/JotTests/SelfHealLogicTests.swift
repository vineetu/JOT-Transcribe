import Foundation
import Testing
@testable import Jot

/// Startup model-integrity self-heal: classification, deferral, and the
/// Phase 5 transient-fallback resolver.
///
/// These exercise `TranscriberHolder` in isolation — a temp `ModelCache`
/// root and an ephemeral suite-scoped `UserDefaults` so the dev/CI machine's
/// real `~/Library/Application Support/Jot/` tree and prefs are never touched.
/// A controllable fake `Transcribing` lets us simulate "active model not
/// loadable" vs "alternate loadable" without CoreML.
///
/// NOTE (per the implementation handoff): the JotTests target is
/// pre-existing-broken on this branch (OpenAIProbe / TierClassifier), so this
/// suite may not be runnable as-is; it is written to compile-by-inspection and
/// to be correct once the target builds.
@MainActor
@Suite(.serialized)
struct SelfHealLogicTests {

    // MARK: - Fakes

    /// Controllable `Transcribing` stub. `readiness` flips after a successful
    /// `ensureLoaded()`; `loadShouldFail` forces a load error to simulate a
    /// corrupt/unloadable bundle.
    final class FakeTranscriber: Transcribing, @unchecked Sendable {
        private let loadShouldFail: Bool
        private var loaded = false

        init(loadShouldFail: Bool) {
            self.loadShouldFail = loadShouldFail
        }

        func ensureLoaded() async throws {
            if loadShouldFail { throw TranscriberError.modelMissing }
            loaded = true
        }

        func transcribe(_ samples: [Float]) async throws -> TranscriptionResult {
            TranscriptionResult(text: "ok", rawText: "ok", duration: 1, processingTime: 0, confidence: 1)
        }

        func transcribeFile(_ url: URL) async throws -> TranscriptionResult {
            TranscriptionResult(text: "ok", rawText: "ok", duration: 1, processingTime: 0, confidence: 1)
        }

        var isReady: Bool { get async { loaded } }
    }

    /// No-op model fetcher so the self-heal download path runs with ZERO
    /// network — `beginSelfHeal` would otherwise construct a real
    /// `ModelDownloader` and trigger a multi-GB HuggingFace fetch.
    ///
    /// `neverCompletes: true` suspends indefinitely so `repairState` stays
    /// `.downloading` while a test inspects the in-flight repair (the suspended
    /// Task is cancelled at process teardown). `false` returns immediately,
    /// matching `downloadIfMissing`'s already-present contract.
    struct NoopDownloader: ModelDownloading {
        let neverCompletes: Bool
        init(neverCompletes: Bool = false) { self.neverCompletes = neverCompletes }

        func downloadIfMissing(
            _ id: ParakeetModelID,
            progress: @Sendable @escaping (Double) -> Void
        ) async throws {
            if neverCompletes {
                // Hold the download open so the caller's `repairState` remains
                // `.downloading` for the duration of the test.
                try? await Task.sleep(nanoseconds: .max)
                return
            }
            progress(1.0)
        }
    }

    // MARK: - Infra

    private static func freshDefaults() -> UserDefaults {
        let name = "jot.tests.selfheal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func freshCache() throws -> ModelCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-selfheal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ModelCache(root: root)
    }

    // MARK: - Phase 5 resolver

    /// No repair in flight → the resolver always returns `.active` (the live
    /// transcriber), regardless of readiness.
    @Test func resolverReturnsActiveWhenNoRepairInFlight() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)

        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: false) },
            installedModelIDs: []
        )

        guard case .active = await holder.resolveSessionTranscriber() else {
            Issue.record("expected .active when no repair in flight")
            return
        }
    }

    /// Repair in flight, active model not ready, AND no installed alternate
    /// English model → `.blocked` (caller shows the persistent repairing pill).
    @Test func resolverBlocksWhenRepairingAndNoAlternateInstalled() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        defaults.set(ParakeetModelID.nemotron_en.rawValue, forKey: TranscriberHolder.defaultsKey)

        // Factory always returns an unloadable transcriber; installed set is
        // empty so `installedFallbackModel` finds nothing. A no-op downloader
        // keeps the self-heal download path off the network.
        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: true) },
            downloaderFactory: { _ in NoopDownloader(neverCompletes: true) },
            installedModelIDs: []
        )

        // Drive into a repairing state via the public probe → self-heal path.
        // The active model is unloadable, so the probe reports a failed side
        // and `beginSelfHeal` sets `repairState = .downloading` (no network —
        // the no-op downloader returns immediately).
        let probe = await holder.probeActiveModelOnLaunch()
        #expect(probe.allHealthy == false)
        await holder.beginSelfHeal(failedSides: probe.failedSides)
        #expect(holder.repairState != nil)

        guard case .blocked = await holder.resolveSessionTranscriber() else {
            Issue.record("expected .blocked when repairing with no alternate")
            return
        }
    }

    // MARK: - Phase 2 deferral guard (G5)

    /// Self-heal DEFERS one launch when a four-option migration download is
    /// pending — it must not run a 3rd concurrent download. `repairState` stays
    /// nil (the probe re-runs next launch).
    @Test func selfHealDefersWhenFourOptionDownloadPending() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)
        defaults.set(true, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)

        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: true) },
            downloaderFactory: { _ in NoopDownloader() },
            installedModelIDs: []
        )

        await holder.beginSelfHeal(failedSides: [.batch])
        #expect(holder.repairState == nil)
    }

    /// Symmetric deferral for the Nemotron auto-upgrade pending marker.
    @Test func selfHealDefersWhenNemotronUpgradePending() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)
        defaults.set(true, forKey: NemotronAutoUpgradeMigration.autoUpgradePendingKey)

        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: true) },
            downloaderFactory: { _ in NoopDownloader() },
            installedModelIDs: []
        )

        await holder.beginSelfHeal(failedSides: [.batch])
        #expect(holder.repairState == nil)
    }

    /// The once-flag prevents a second self-heal within the same launch even if
    /// `beginSelfHeal` is invoked twice.
    @Test func selfHealOnceFlagBlocksSecondInvocation() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        // Pending markers set so the first call defers (and trips the flag)
        // without kicking a real download.
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)
        defaults.set(true, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)

        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: true) },
            downloaderFactory: { _ in NoopDownloader() },
            installedModelIDs: []
        )

        await holder.beginSelfHeal(failedSides: [.batch])
        // Clear the pending marker; a second call would otherwise proceed —
        // but the once-flag must keep it a no-op.
        defaults.set(false, forKey: ModelChoiceMigration.fourOptionDownloadPendingKey)
        await holder.beginSelfHeal(failedSides: [.batch])
        #expect(holder.repairState == nil)
    }

    // MARK: - Single-in-flight download coordinator (Fix 3a)

    /// Two concurrent `run(id:)` calls for the SAME id execute `body` exactly
    /// once — the second joins the first's task instead of starting a colliding
    /// download. Both callers still observe completion. This is the guard that
    /// prevents the self-heal + manual Download button from racing in
    /// FluidAudio's staging move.
    @Test func coordinatorRunsBodyOnceForConcurrentSameId() async throws {
        let coordinator = DownloadCoordinator()
        let runCount = Counter()

        // A body that signals it started, waits to be released, then finishes —
        // so the second caller is guaranteed to arrive while the first is still
        // in flight.
        let gate = Gate()
        let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void = { report in
            await runCount.increment()
            report(0.5)
            await gate.wait()
            report(1.0)
        }

        async let first: Void = coordinator.run(.nemotron_en, progress: { _ in }, body: body)
        // Give `first` a moment to register as in-flight, then start a joiner.
        try await Task.sleep(nanoseconds: 50_000_000)
        async let second: Void = coordinator.run(.nemotron_en, progress: { _ in }, body: body)

        await gate.open()
        _ = try await (first, second)

        // `body` ran exactly once despite two concurrent callers.
        #expect(await runCount.value == 1)
        // And the id is no longer marked in flight after both complete.
        #expect(await coordinator.isDownloading(.nemotron_en) == false)
    }

    /// Different ids run independently — the coordinator only dedupes by id, so
    /// two distinct models download concurrently.
    @Test func coordinatorRunsDistinctIdsConcurrently() async throws {
        let coordinator = DownloadCoordinator()
        let runCount = Counter()
        let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void = { report in
            await runCount.increment()
            report(1.0)
        }

        try await coordinator.run(.nemotron_en, progress: { _ in }, body: body)
        try await coordinator.run(.tdt_0_6b_v3_eou_streaming, progress: { _ in }, body: body)

        #expect(await runCount.value == 2)
    }

    /// The coordinator entry's lifetime is tied to the SHARED task, not the
    /// initiator's await. If the initiator's parent task is cancelled
    /// mid-download, the entry must remain in flight until the underlying
    /// download actually finishes — so a caller arriving in that window joins
    /// (run count stays 1) rather than starting a 2nd colliding fetch.
    @Test func coordinatorKeepsEntryAliveWhenInitiatorCancelled() async throws {
        let coordinator = DownloadCoordinator()
        let runCount = Counter()
        let gate = Gate()
        let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void = { _ in
            await runCount.increment()
            await gate.wait()
        }

        // Initiator runs in its own task we then cancel mid-download.
        let initiator = Task {
            try await coordinator.run(.nemotron_en, progress: { _ in }, body: body)
        }
        try await Task.sleep(nanoseconds: 50_000_000)  // let it register in-flight
        initiator.cancel()                              // cancel the initiator's await
        _ = try? await initiator.value                  // its await unwinds

        // The shared download is still running → still marked in flight.
        #expect(await coordinator.isDownloading(.nemotron_en) == true)

        // A new caller in this window JOINS (does not start a 2nd fetch).
        let joiner = Task {
            try await coordinator.run(.nemotron_en, progress: { _ in }, body: body)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        await gate.open()                               // release the shared download
        _ = try await joiner.value

        // `body` ran exactly once despite the cancellation + the joiner.
        #expect(await runCount.value == 1)
        #expect(await coordinator.isDownloading(.nemotron_en) == false)
    }

    // MARK: - repoDownloadFraction rescale (Fix 3)

    /// The [0, 0.5] download band is rescaled to a full [0, 1] per-side
    /// fraction, and out-of-band values clamp to [0, 1].
    @Test func repoDownloadFractionRescalesAndClamps() {
        #expect(ModelDownloader.repoDownloadFraction(0.0) == 0.0)
        #expect(ModelDownloader.repoDownloadFraction(0.25) == 0.5)
        #expect(ModelDownloader.repoDownloadFraction(0.5) == 1.0)
        // Beyond the download band (would only happen if the SDK ever drove the
        // compile band on this path) clamps to 1.0 rather than overshooting.
        #expect(ModelDownloader.repoDownloadFraction(0.6) == 1.0)
        #expect(ModelDownloader.repoDownloadFraction(-0.1) == 0.0)
    }

    // MARK: - Manual retry drives repairState (Fix 1)

    /// A successful manual retry of the ACTIVE model via `runManualRepair`
    /// clears `repairState` to nil (so the failure UI everywhere — Settings
    /// row, persistent pill, banner — goes away). Starts from a `.failed`
    /// repair state to mirror the post-self-heal-failure retry path.
    @Test func manualRetrySuccessClearsRepairState() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        defaults.set(ParakeetModelID.tdt_0_6b_v3.rawValue, forKey: TranscriberHolder.defaultsKey)

        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            // Loadable transcriber so the post-download ensureLoaded() succeeds.
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: false) },
            // No-op downloader → the "download" succeeds instantly with no network.
            downloaderFactory: { _ in NoopDownloader() },
            installedModelIDs: []
        )

        await holder.runManualRepair(.tdt_0_6b_v3)
        #expect(holder.repairState == nil)
    }

    // MARK: - Self-clearing stale failure (Fix a/b/c)

    /// `noteActiveModelHealthy()` clears a stale `.failed` repair state — the
    /// signal a successful transcription on the ACTIVE model sends so the
    /// failure pill never nags after the model is actually working (Fix-a).
    @Test func noteActiveModelHealthyClearsFailedRepairState() async throws {
        let defaults = Self.freshDefaults()
        let cache = try Self.freshCache()
        defaults.set(ParakeetModelID.nemotron_en.rawValue, forKey: TranscriberHolder.defaultsKey)

        let holder = TranscriberHolder(
            cache: cache,
            defaults: defaults,
            transcriberFactory: { _, _ in FakeTranscriber(loadShouldFail: true) },
            // Downloader that always fails → drives `repairState` to `.failed`.
            downloaderFactory: { _ in FailingDownloader() },
            installedModelIDs: []
        )

        let probe = await holder.probeActiveModelOnLaunch()
        await holder.beginSelfHeal(failedSides: probe.failedSides)
        // Let the failing download settle into `.failed`.
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .failed = holder.repairState {} else {
            Issue.record("expected .failed repair state after a failing download")
        }

        // A subsequent proven-healthy signal clears it.
        holder.noteActiveModelHealthy()
        #expect(holder.repairState == nil)
    }

    /// The coordinator notifies success observers with the completed id (Fix-b)
    /// — the hook the holder uses to drop a stale failure when the active model
    /// becomes healthy via any download path.
    @Test func coordinatorNotifiesSuccessObservers() async throws {
        let coordinator = DownloadCoordinator()
        let observed = ModelIDBox()
        await coordinator.addSuccessObserver { id in
            Task { await observed.set(id) }
        }

        try await coordinator.run(.nemotron_en, progress: { _ in }) { report in
            report(1.0)
        }
        // Give the observer's hop a moment.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await observed.value == .nemotron_en)
    }

    actor ModelIDBox {
        private(set) var value: ParakeetModelID?
        func set(_ v: ParakeetModelID) { value = v }
    }

    /// A downloader that always throws — drives `beginSelfHeal` to `.failed`
    /// without touching the network.
    struct FailingDownloader: ModelDownloading {
        struct Boom: Error {}
        func downloadIfMissing(
            _ id: ParakeetModelID,
            progress: @Sendable @escaping (Double) -> Void
        ) async throws {
            throw Boom()
        }
    }

    // Tiny async-safe helpers for the coordinator tests.
    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            opened = true
            for c in continuations { c.resume() }
            continuations.removeAll()
        }
    }
}
