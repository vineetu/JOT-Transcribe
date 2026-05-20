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
//   * For multi-bundle options (the streaming option's TDT v2 + EOU
//     pair) sequences both downloads under one progress bar with
//     all-or-nothing semantics — failure of either side cleans up
//     both and propagates a single error.

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

public actor ModelDownloader {
    private let cache: ModelCache

    public init(cache: ModelCache = .shared) {
        self.cache = cache
    }

    /// Fetch the model if it's not already fully present on disk.
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

        do {
            try cache.ensureRootExists()
        } catch {
            throw ModelDownloadError.classify(error)
        }

        if id.supportsStreaming {
            try await downloadMultiBundle(id, progress: progress)
        } else {
            try await downloadSingleBundle(id, progress: progress)
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

    // MARK: - Multi-bundle (streaming option: TDT v2 + EOU 120M)

    /// Sequence the two underlying downloads under a single combined
    /// progress bar. Apportionment is fixed by approximate bundle size —
    /// TDT v2 ≈ 600 MB (83% of total), EOU 120M ≈ 120 MB (17%) — so the
    /// progress bar's slope roughly tracks bytes-on-the-wire instead of
    /// jumping at bundle boundaries. The combined stream is forced
    /// **monotonic** via a high-water-mark wrapper: FluidAudio's
    /// per-component download (`AsrModels.download` runs one
    /// `DownloadUtils.loadModels` per CoreML file and resets `fractionCompleted`
    /// each time) would otherwise cause the bar to jump backwards
    /// inside the batch phase. The all-or-nothing invariant from
    /// §11 R2: a failure on either side calls `cache.removeCache(for:)`
    /// (which clears both bundle directories) before the error
    /// propagates, so the next retry starts from a clean slate and a
    /// partial cache never deceives `isCached`.
    private func downloadMultiBundle(
        _ id: ParakeetModelID,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        // Apportion: TDT v2 batch is the larger bundle.
        let batchShare = 0.83
        let streamingShare = 1.0 - batchShare

        let monotonic = MonotonicProgress()
        let report: @Sendable (Double) -> Void = { value in
            progress(monotonic.advance(to: max(0.0, min(1.0, value))))
        }

        do {
            try await downloadBatchSide(
                id,
                progress: { fraction in
                    report(fraction * batchShare)
                }
            )
            // Pin the floor at the batch ceiling so any EOU progress jitter
            // can't dip below where the batch phase ended.
            report(batchShare)
            try await downloadStreamingSide(
                id,
                progress: { fraction in
                    report(batchShare + fraction * streamingShare)
                }
            )
        } catch {
            cache.removeCache(for: id)
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
        guard let streamingURL = cache.streamingPartialCacheURL(for: id) else {
            // Defensive: should be unreachable — `id.supportsStreaming`
            // gated the call site. Treat the missing slot as a
            // corruption rather than a silent success.
            throw ModelDownloadError.corrupted
        }

        // `DownloadUtils.downloadRepo` writes to
        // `<root>/<repo.folderName>/...`, where for `parakeetEou160`
        // the folderName is `parakeet-eou-streaming/160ms`. We hand it
        // the streaming root (the directory two levels above the
        // 160ms slot) so the SDK's own layout produces our expected
        // `streamingPartialCacheURL`.
        let streamingRoot = streamingURL
            .deletingLastPathComponent() // drop "160ms"
            .deletingLastPathComponent() // drop "parakeet-eou-streaming"

        let progressHandler: DownloadUtils.ProgressHandler = { snapshot in
            progress(max(0.0, min(1.0, snapshot.fractionCompleted)))
        }

        do {
            try await DownloadUtils.downloadRepo(
                .parakeetEou160,
                to: streamingRoot,
                variant: nil,
                progressHandler: progressHandler
            )
        } catch {
            throw ModelDownloadError.classify(error)
        }
    }
}
