import FluidAudio
import Foundation

/// Thin wrapper around FluidAudio's `DownloadUtils.downloadRepo` for the
/// Sortformer streaming diarization model. Mirrors the shape of
/// `ModelDownloader` for Parakeet — see comments there for the broader
/// rationale. Specific to Speaker Labels piece A:
///
/// * Only one variant is supported (`fastV2_1`, ~250 MB).
/// * No multi-bundle staging; a single repo download is sufficient.
/// * On failure, any partial bundle directory is removed before throwing so
///   the next retry starts clean.
public actor SortformerModelDownloader {
    private let cache: SortformerModelCache

    public init(cache: SortformerModelCache = .shared) {
        self.cache = cache
    }

    /// Fetch the Sortformer bundle if it is not already on disk.
    ///
    /// - Parameter progress: invoked with `fractionCompleted` in `[0, 1]`.
    ///   Fires on an unspecified queue — callers that need `@MainActor` must
    ///   hop inside the closure.
    /// - Throws: `ModelDownloadError` on failure (re-uses Parakeet's error
    ///   classification so the existing UI surfaces can render it).
    public func downloadIfMissing(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        if cache.isCached {
            progress(1.0)
            return
        }

        do {
            try cache.ensureRootExists()
        } catch {
            throw ModelDownloadError.classify(error)
        }

        let progressHandler: DownloadUtils.ProgressHandler = { snapshot in
            let clamped = max(0.0, min(1.0, snapshot.fractionCompleted))
            progress(clamped)
        }

        do {
            // `DownloadUtils.downloadRepo` writes into
            // `<root>/<repo.folderName>/...` — for `.sortformer` the
            // folderName is `sortformer`. The HF repo ships every variant
            // bundle; passing `variant: SortformerModelCache.variant.fileName`
            // keeps us to the fastV2_1 bundle we actually use.
            try await DownloadUtils.downloadRepo(
                .sortformer,
                to: cache.root,
                variant: SortformerModelCache.variant.fileName,
                progressHandler: progressHandler
            )
        } catch {
            cache.removeCache()
            throw ModelDownloadError.classify(error)
        }

        guard cache.isCached else {
            cache.removeCache()
            throw ModelDownloadError.corrupted
        }

        progress(1.0)
    }
}
