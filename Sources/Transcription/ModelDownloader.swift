// MARK: - Approach
//
// Thin wrapper around FluidAudio's own download primitives. The SDK
// already handles the HuggingFace mirror URL, per-file download progress,
// redownload-on-compile-failure, and the specific subdirectory layout its
// loader expects. Rolling our own URLSession download would duplicate all of
// that and leave us to track SDK layout changes across versions.
//
// What this wrapper adds:
//   * Overrides the cache root to `~/Library/Application Support/Jot/...`
//     instead of the shared `FluidAudio/` directory.
//   * Exposes progress as a simple `(Double) -> Void` — callers don't need to
//     import FluidAudio to observe the download.
//   * Classifies failures into `ModelDownloadError` cases UI can render
//     directly.
//   * Cleans up partial downloads on failure so the next retry starts from a
//     known state. Resume is explicitly out of scope for v1.
//   * For multi-bundle options, sequences both downloads under one progress
//     bar. Nemotron-only downloads fetch just the streaming bundle.

import FluidAudio
import Foundation

/// Class-backed (reference) high-water mark so the inner
/// `progressHandler` closure (which is `@Sendable`) and the outer
/// `report` closure share state without a `var` capture. Mutations
/// happen on whichever queue FluidAudio fires its progress callback
/// on; concurrent fires from sequential underlying downloads aren't
/// expected, but the mutation is wrapped in `os_unfair_lock` to keep
/// the helper safe against any future fan-out.
private final class MonotonicProgress: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var current: Double = 0.0

    func advance(to value: Double) -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if value > current { current = value }
        return current
    }
}

/// Seam for the model-fetch step so callers can be unit-tested without a
/// real HuggingFace download. `ModelDownloader` is the production conformer;
/// the startup self-heal injects this via `TranscriberHolder.downloaderFactory`
/// so tests can substitute a no-op fetcher (the same pattern as
/// `TranscriberHolder.transcriberFactory`).
public protocol ModelDownloading: Sendable {
    func downloadIfMissing(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws
}

/// Process-global single-in-flight registry, keyed by `ParakeetModelID`.
///
/// Two independent callers fetching the SAME model — e.g. the background
/// startup self-heal AND the Settings → Transcription "Download" button — used
/// to construct separate `ModelDownloader` instances and both call
/// `DownloadUtils.downloadRepo(...)` into the SAME staging directory. That
/// races FluidAudio's file-move step ("CFNetworkDownload_*.tmp couldn't be
/// moved to decoder_joint.mlmodelc because the folder doesn't exist" — one
/// task removes/recreates the parent dir while the other moves into it).
///
/// This coordinator collapses concurrent fetches of one id onto a single
/// shared `Task`: the first caller starts it, later callers `await` the same
/// task (forwarding the live progress to every observer) instead of starting
/// a colliding download. The registry is `static` so it dedupes across every
/// `ModelDownloader` instance, not just one.
actor DownloadCoordinator {
    static let shared = DownloadCoordinator()

    /// An in-flight fetch for one model id: the running task plus the set of
    /// observer progress closures to fan progress out to.
    private final class InFlight: @unchecked Sendable {
        var task: Task<Void, Error>?
        var observers: [(Double) -> Void] = []
        let lock = os_unfair_lock_t.allocate(capacity: 1)
        init() { lock.initialize(to: os_unfair_lock()) }
        deinit { lock.deallocate() }

        func addObserver(_ o: @escaping (Double) -> Void) {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            observers.append(o)
        }
        func broadcast(_ value: Double) {
            os_unfair_lock_lock(lock)
            let snapshot = observers
            os_unfair_lock_unlock(lock)
            for o in snapshot { o(value) }
        }
    }

    private var inFlight: [ParakeetModelID: InFlight] = [:]

    /// Success observers (self-heal Fix-b). Fired with the model id whenever a
    /// download for that id completes successfully via this coordinator —
    /// regardless of which path initiated it. `TranscriberHolder` registers one
    /// so a model that becomes healthy through ANY download (a racing one, a
    /// migration/upgrade fetch, etc.) drops a stale `.failed` repair state, even
    /// if that path didn't itself touch `repairState`.
    private var successObservers: [@Sendable (ParakeetModelID) -> Void] = []

    func addSuccessObserver(_ observer: @escaping @Sendable (ParakeetModelID) -> Void) {
        successObservers.append(observer)
    }

    private func notifySuccess(_ id: ParakeetModelID) {
        for observer in successObservers { observer(id) }
    }

    /// Run `body` for `id` exactly once even if called concurrently. Progress
    /// from the single underlying download is fanned out to every caller's
    /// `progress` closure. Joiners observe the same task's success/failure.
    func run(
        _ id: ParakeetModelID,
        progress: @escaping @Sendable (Double) -> Void,
        body: @escaping @Sendable (_ report: @escaping @Sendable (Double) -> Void) async throws -> Void
    ) async throws {
        if let existing = inFlight[id] {
            // Join the in-flight download: register our progress observer and
            // await the same task — no second (colliding) fetch is started.
            existing.addObserver(progress)
            try await existing.task!.value
            return
        }

        let entry = InFlight()
        entry.addObserver(progress)
        inFlight[id] = entry

        let report: @Sendable (Double) -> Void = { value in
            entry.broadcast(value)
        }
        // The registry entry must live exactly as long as the underlying
        // download — NOT as long as the initiator's await. If the initiator's
        // parent Task is cancelled mid-download, a `defer` on the initiator's
        // await would clear the entry while the shared Task is still running,
        // and a new caller arriving in that window would start a 2nd colliding
        // `downloadRepo`. So the shared Task itself removes the entry as its
        // final step (success AND failure), hopping back onto this actor
        // BEFORE it returns — so by the time any awaiter's `task.value`
        // resolves, the entry is already gone and `isDownloading(id)` is false.
        // Reentrancy is safe: `clear`/`run`/`isDownloading` only touch
        // `inFlight` synchronously and never await while mutating it.
        // This `Task` inherits the coordinator actor's isolation (it's created
        // inside an actor-isolated method), so `clear(id)` runs synchronously
        // on the actor as the task's final step — no extra hop, deterministic.
        let task = Task<Void, Error> {
            do {
                try await body(report)
            } catch {
                clear(id)
                throw error
            }
            clear(id)
            // Fix-b: a successful download of `id` — tell observers so a stale
            // repair-failure for this model can self-clear regardless of which
            // path initiated the download.
            notifySuccess(id)
        }
        entry.task = task

        try await task.value
    }

    /// Remove the in-flight entry for `id`. Called only from the shared Task as
    /// its final step (success AND failure) so the entry's lifetime matches the
    /// underlying download, not any particular caller's await.
    private func clear(_ id: ParakeetModelID) {
        inFlight[id] = nil
    }

    /// Whether a download for `id` is currently in flight.
    func isDownloading(_ id: ParakeetModelID) -> Bool {
        inFlight[id] != nil
    }
}

public actor ModelDownloader: ModelDownloading {
    private let cache: ModelCache

    public init(cache: ModelCache = .shared) {
        self.cache = cache
    }

    /// Fetch the model if it's not already fully present on disk.
    ///
    /// Routes through the process-global `DownloadCoordinator` so concurrent
    /// fetches of the SAME id (e.g. background self-heal + the manual
    /// Settings → Transcription Download button) join one shared task instead
    /// of colliding in FluidAudio's staging-move step.
    ///
    /// - Parameters:
    ///   - id: which Parakeet variant to download. For multi-bundle
    ///     options (the streaming option) both bundles are fetched
    ///     sequentially under one combined progress bar.
    ///   - progress: invoked with fractionCompleted in `[0, 1]`. Fires on an
    ///     unspecified queue — callers that need MainActor must hop inside
    ///     the closure.
    /// - Throws: `ModelDownloadError` on failure. Any partial download is
    ///   removed before the error propagates so the next call starts clean.
    public func downloadIfMissing(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        if cache.isCached(id) {
            progress(1.0)
            return
        }

        let cache = self.cache
        try await DownloadCoordinator.shared.run(id, progress: progress) { report in
            try await Self.performDownload(id, cache: cache, progress: report)
        }
    }

    /// The actual fetch, invoked once per id by the coordinator. `nonisolated
    /// static` so the coordinator can run it off this actor without a hop and
    /// without capturing `self` (the only state it needs is `cache`).
    nonisolated private static func performDownload(
        _ id: ParakeetModelID,
        cache: ModelCache,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        do {
            try cache.ensureRootExists()
        } catch {
            throw ModelDownloadError.classify(error)
        }

        let downloader = ModelDownloader(cache: cache)
        if id == .nemotron_multilingual || id == .nemotron_multilingual_latin {
            try await downloader.downloadNemotronMultilingual(id, progress: progress)
        } else if id == .nemotron_en {
            try await downloader.downloadStreamingOnly(id, progress: progress)
        } else if id.supportsStreaming {
            try await downloader.downloadMultiBundle(id, progress: progress)
        } else {
            try await downloader.downloadSingleBundle(id, progress: progress)
        }
    }

    // MARK: - Single-bundle (v3 / JA)

    private func downloadSingleBundle(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let targetDir = cache.cacheURL(for: id)
        let version = id.fluidAudioVersion

        let progressHandler: DownloadUtils.ProgressHandler = { snapshot in
            let clamped = max(0.0, min(1.0, snapshot.fractionCompleted))
            progress(clamped)
        }

        do {
            _ = try await AsrModels.download(
                to: targetDir,
                force: false,
                version: version,
                encoderPrecision: id.encoderPrecision,
                progressHandler: progressHandler
            )
        } catch {
            cache.removeCache(for: id)
            throw ModelDownloadError.classify(error)
        }

        // Sanity-check: SDK returned success, but confirm the files the
        // loader will look for are actually present. Catches the edge case
        // where a partial-success download lands some files but not the
        // vocabulary JSON.
        guard cache.isCached(id) else {
            cache.removeCache(for: id)
            throw ModelDownloadError.corrupted
        }

        progress(1.0)
    }

    // MARK: - Streaming options

    private func downloadStreamingOnly(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        do {
            try await downloadNemotronStreamingSide(id, progress: progress)
        } catch {
            cache.removeCache(for: id)
            throw error
        }

        guard cache.isCached(id) else {
            cache.removeCache(for: id)
            throw ModelDownloadError.corrupted
        }

        progress(1.0)
    }

    // MARK: - Streaming options

    /// Sequence the two underlying downloads under a single combined
    /// progress bar. Apportionment is fixed by approximate bundle size so the
    /// progress bar's slope roughly tracks bytes-on-the-wire instead of
    /// jumping at bundle boundaries. The combined stream is forced
    /// **monotonic** via a high-water-mark wrapper: FluidAudio's
    /// per-component download (`AsrModels.download` runs one
    /// `DownloadUtils.loadModels` per CoreML file and resets `fractionCompleted`
    /// each time) would otherwise cause the bar to jump backwards
    /// inside the batch phase.
    private func downloadMultiBundle(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let batchShare = batchProgressShare(for: id)
        let streamingShare = 1.0 - batchShare
        let batchAlreadyCached = cache.batchBundleExists(for: id)
        let streamingAlreadyCached = cache.streamingPartialBundleExists(for: id)

        let monotonic = MonotonicProgress()
        let report: @Sendable (Double) -> Void = { value in
            progress(monotonic.advance(to: max(0.0, min(1.0, value))))
        }

        do {
            if batchAlreadyCached {
                report(batchShare)
            } else {
                try await downloadBatchSide(
                    id,
                    progress: { fraction in
                        report(fraction * batchShare)
                    }
                )
            }
            // Pin the floor at the batch ceiling so any streaming progress
            // jitter can't dip below where the batch phase ended.
            report(batchShare)
            if streamingAlreadyCached {
                report(1.0)
            } else {
                try await downloadStreamingSide(
                    id,
                    progress: { fraction in
                        report(batchShare + fraction * streamingShare)
                    }
                )
            }
        } catch {
            cache.removeCache(
                for: id,
                removeBatch: !batchAlreadyCached,
                removeStreaming: !streamingAlreadyCached
            )
            // `error` is already a `ModelDownloadError` — the helpers
            // classify before throwing.
            throw error
        }

        guard cache.isCached(id) else {
            cache.removeCache(for: id)
            throw ModelDownloadError.corrupted
        }

        // Route the terminal 1.0 through `report` so the high-water
        // mark is updated; any stragglers from the underlying downloads
        // can't then publish a regression below 1.0.
        report(1.0)
    }

    private func batchProgressShare(for id: ParakeetModelID) -> Double {
        switch id {
        case .tdt_0_6b_v3_nemotron_streaming:
            // v3 int8 batch ≈ 1.25 GB, Nemotron 1120ms ≈ 600 MB.
            return 1_250_000_000.0 / 1_850_000_000.0
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .nemotron_en,
             // Streaming-only (no batch side) — like .nemotron_en.
             .nemotron_multilingual,
             .nemotron_multilingual_latin:
            return 1.0
        }
    }

    /// Download a Nemotron multilingual ship (`latin` or full `multilingual`)
    /// via FluidAudio's idempotent `downloadVariant` (a no-op when already
    /// cached). The variant is baked into `id`, so this is fully id-keyed: the
    /// `languageCode` passed to `downloadVariant` is just a representative code
    /// for the ship (any latin code selects the latin dir; "auto" selects the
    /// multilingual dir — the bundle serves every language in that variant).
    /// `downloadVariant(to: cache.root)` produces exactly `cacheURL(for: id)`.
    func downloadNemotronMultilingual(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let representativeCode: String
        switch id {
        case .nemotron_multilingual_latin: representativeCode = "en-US"
        case .nemotron_multilingual: representativeCode = "auto"
        default: throw ModelDownloadError.corrupted
        }
        do {
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: representativeCode,
                chunkMs: ModelCache.nemotronMultilingualChunkMs,
                to: cache.root,
                progressHandler: { snapshot in
                    progress(max(0.0, min(1.0, snapshot.fractionCompleted)))
                }
            )
        } catch {
            throw ModelDownloadError.classify(error)
        }
        guard cache.isCached(id) else {
            cache.removeCache(for: id)
            throw ModelDownloadError.corrupted
        }
        progress(1.0)
    }

    private func downloadBatchSide(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let targetDir = cache.cacheURL(for: id)
        let version = id.fluidAudioVersion

        let progressHandler: DownloadUtils.ProgressHandler = { snapshot in
            progress(max(0.0, min(1.0, snapshot.fractionCompleted)))
        }

        do {
            _ = try await AsrModels.download(
                to: targetDir,
                force: false,
                version: version,
                encoderPrecision: id.encoderPrecision,
                progressHandler: progressHandler
            )
        } catch {
            throw ModelDownloadError.classify(error)
        }
    }

    private func downloadStreamingSide(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        switch id {
        case .tdt_0_6b_v3_nemotron_streaming, .nemotron_en:
            try await downloadNemotronStreamingSide(id, progress: progress)
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_eou_streaming,
             // Multilingual ships download via `downloadVariant` (handled in
             // `performDownload`), never this batch+streaming staging flow.
             .nemotron_multilingual,
             .nemotron_multilingual_latin:
            // No separate streaming bundle — these fetch only their batch /
            // single bundle. Reaching here would be a routing bug.
            throw ModelDownloadError.corrupted
        }
    }

    /// The upper bound of FluidAudio `DownloadUtils.downloadRepo`'s **download**
    /// phase. `downloadRepo` reports `fractionCompleted` in `[0, 0.5]` while
    /// fetching bytes and reserves `[0.5, 1.0]` for the CoreML compile step
    /// (which `downloadRepo` alone never runs). COUPLED to the SDK — re-check on
    /// every FluidAudio bump (see `DownloadUtils.swift`, the `0.5 *` factors in
    /// `downloadRepo`'s progress reports).
    static let repoDownloadBandCeiling: Double = 0.5

    /// Rescale a `DownloadUtils.downloadRepo` progress snapshot to a per-side
    /// [0, 1] fraction.
    ///
    /// `downloadRepo` already reports **byte-weighted, monotonic** progress (it
    /// sums `totalBytes` from the HF listing and drives a per-byte
    /// `URLSessionDownloadDelegate`), but it confines the *download* phase to
    /// the `[0, repoDownloadBandCeiling]` band. Our streaming-side fetches only
    /// download — never compile — so the raw snapshot would stall at the ceiling
    /// and then snap to 1.0 when our wrapper forces the terminal report.
    /// Rescaling that download band to a full 0.0–1.0 per-side fraction restores
    /// a smooth, byte-weighted 0→100% with no long stall at the ceiling.
    static func repoDownloadFraction(_ fractionCompleted: Double) -> Double {
        let expanded = fractionCompleted / repoDownloadBandCeiling
        return max(0.0, min(1.0, expanded))
    }

    private func downloadNemotronStreamingSide(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let streamingURL = cache.streamingPartialCacheURL(for: id),
              let stagingRoot = cache.streamingNemotronStagingRoot(for: id),
              let stagingURL = cache.streamingNemotronStagingURL(for: id)
        else {
            throw ModelDownloadError.corrupted
        }

        let progressHandler: DownloadUtils.ProgressHandler = { snapshot in
            progress(Self.repoDownloadFraction(snapshot.fractionCompleted))
        }

        do {
            try? FileManager.default.removeItem(at: stagingRoot)
            try await DownloadUtils.downloadRepo(
                .nemotronStreaming1120,
                to: stagingRoot,
                variant: nil,
                progressHandler: progressHandler
            )

            let fm = FileManager.default
            try fm.createDirectory(
                at: streamingURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: streamingURL.path) {
                try fm.removeItem(at: streamingURL)
            }
            try fm.moveItem(at: stagingURL, to: streamingURL)
            try? fm.removeItem(at: stagingRoot)
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw ModelDownloadError.classify(error)
        }
    }
}
