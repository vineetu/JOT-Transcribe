// MARK: - Approach
//
// Thin wrapper around FluidAudio's own `AsrModels.download(...)`. The SDK
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

import FluidAudio
import Foundation

public actor ModelDownloader {
    private let cache: ModelCache

    public init(cache: ModelCache = .shared) {
        self.cache = cache
    }

    /// Fetch the model if it's not already fully present on disk.
    ///
    /// - Parameters:
    ///   - id: which Parakeet variant to download.
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
}
