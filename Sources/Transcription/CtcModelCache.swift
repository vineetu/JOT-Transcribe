import FluidAudio
import Foundation

/// On-disk location for the Parakeet CTC 110M encoder bundle used by the
/// vocabulary-boosting pipeline.
///
/// Mirrors `ModelCache` for the main TDT model: the CTC encoder lives
/// under Jot's own Application Support subtree rather than FluidAudio's
/// default cache so "delete Jot's data" is a single directory remove and
/// users don't see an orphan "FluidAudio" folder in their Library.
///
/// The CTC bundle is ~97.5 MB (two CoreML model packages + a vocab JSON)
/// and is separate from the main TDT model — they share no files, so
/// downloading one does not imply the other.
public struct CtcModelCache: Sendable {
    public let root: URL
    public let variant: CtcModelVariant

    public init(root: URL, variant: CtcModelVariant = .ctc110m) {
        self.root = root
        self.variant = variant
    }

    public static let shared: CtcModelCache = {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return CtcModelCache(
            root: appSupport.appendingPathComponent("Jot/Models", isDirectory: true)
        )
    }()

    /// Directory FluidAudio reads from / writes to for the configured
    /// variant. FluidAudio's own layout is `<parent>/<repo-name>/*.mlmodelc`
    /// — we hand its API the parent directory and let it manage the subtree.
    public var directory: URL {
        // `parakeet-ctc-110m-coreml` (matches FluidAudio's repo-name convention).
        // Keeping this explicit avoids a surprise when a variant adds a
        // different folder name — the mismatch would show up as a "not
        // cached" result that would silently trigger a redownload.
        switch variant {
        case .ctc110m:
            return root.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true)
        case .ctc06b:
            return root.appendingPathComponent("parakeet-ctc-06b-coreml", isDirectory: true)
        }
    }

    /// True when every file FluidAudio requires is on disk. Delegates to
    /// the SDK — only it knows the exact required file set (MelSpectrogram,
    /// AudioEncoder, CtcHead bundles + vocabulary.json + tokenizer.json).
    /// A mere "directory exists" check would falsely claim success on a
    /// partial download.
    public var isCached: Bool {
        CtcModels.modelsExist(at: directory)
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Download + load in one step. If the files are already cached this
    /// is a hot load from disk (no network). On cold start this is the
    /// ~97.5 MB download.
    public func ensureLoaded() async throws -> CtcModels {
        try ensureRootExists()
        return try await CtcModels.downloadAndLoad(to: directory, variant: variant)
    }

    /// Remove the cached bundle. Used after a failed download so the
    /// next retry starts from a known-empty state.
    func removeCache() {
        try? FileManager.default.removeItem(at: directory)
    }
}
