import FluidAudio
import Foundation

/// Owns the on-disk location of downloaded Parakeet models.
///
/// Root lives under the app's Application Support container rather than
/// FluidAudio's default `~/Library/Application Support/FluidAudio/Models/` —
/// we want model files co-located with Jot's other data so "delete the app's
/// data" is a single directory remove, and so users never see a "FluidAudio"
/// folder in their Library that they can't attribute to any app they
/// installed.
public struct ModelCache: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let shared: ModelCache = {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return ModelCache(
            root: appSupport.appendingPathComponent("Jot/Models/Parakeet", isDirectory: true)
        )
    }()

    /// Directory handed to FluidAudio for the *batch* model files for a
    /// given option. FluidAudio derives its actual repo folder from the
    /// parent of this URL. For the int4 v3 option, that parent is a
    /// dedicated Jot folder so the SDK's `parakeet-tdt-0.6b-v3` cache is
    /// isolated from the default v3 install. For the streaming option this
    /// returns the TDT v2 folder; the EOU streaming sibling is reached via
    /// `streamingPartialCacheURL(for:)`.
    public func cacheURL(for id: ParakeetModelID) -> URL {
        let base = root.appendingPathComponent(id.repoFolderName, isDirectory: true)
        switch id {
        case .tdt_0_6b_v3_int4:
            return base.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        case .tdt_0_6b_v3, .tdt_0_6b_ja, .tdt_0_6b_v2_en_streaming:
            return base
        }
    }

    /// Directory where the streaming-side model bundle for a streaming-
    /// enabled option lives. Mirrors the layout FluidAudio's
    /// `StreamingEouAsrManager.loadModels(to:)` writes to:
    /// `root/parakeet-eou-streaming/160ms/<file>.mlmodelc` (per
    /// `Repo.parakeetEou160.folderName`).
    ///
    /// Returns `nil` for options without a streaming sibling — keeps
    /// the existing `cacheURL(for:)` semantics intact for v3 / JA.
    public func streamingPartialCacheURL(for id: ParakeetModelID) -> URL? {
        guard id.supportsStreaming else { return nil }
        switch id {
        case .tdt_0_6b_v2_en_streaming:
            return root
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent("160ms", isDirectory: true)
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return nil
        }
    }

    /// True when every file the loader will need is on disk.
    ///
    /// For single-bundle options (v3, JA) this delegates to the SDK's
    /// `AsrModels.modelsExist`, which is the authoritative check for
    /// "every preprocessor / decoder / joint / vocabulary file is
    /// present" — a directory-exists check would falsely succeed on a
    /// partial download.
    ///
    /// For the streaming option this is **all-or-nothing** (§11 R2):
    /// the result is `true` only when *both* the TDT v2 batch bundle
    /// and the EOU 120M streaming bundle are fully present. A partial
    /// cache (e.g. batch downloaded but EOU interrupted) returns
    /// `false`, which causes Settings to render the option as "Not
    /// installed" with a Retry affordance.
    public func isCached(_ id: ParakeetModelID) -> Bool {
        let batchPresent = AsrModels.modelsExist(
            at: cacheURL(for: id),
            version: id.fluidAudioVersion,
            encoderPrecision: id.encoderPrecision
        )
        guard id.supportsStreaming else { return batchPresent }
        guard batchPresent else { return false }
        guard let streamingURL = streamingPartialCacheURL(for: id) else { return batchPresent }
        return Self.streamingBundleExists(at: streamingURL)
    }

    /// Disk check for the EOU 120M streaming bundle. Reuses
    /// FluidAudio's own `ModelNames.ParakeetEOU.requiredModels` set so
    /// "files present" stays in lockstep with "loader will succeed"
    /// across SDK upgrades — an SDK bump that adds a required file
    /// surfaces here as `false` instead of a load-time crash.
    private static func streamingBundleExists(at directory: URL) -> Bool {
        let fm = FileManager.default
        return ModelNames.ParakeetEOU.requiredModels.allSatisfy { name in
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Remove a cached model. Used after a failed download so the next retry
    /// starts clean. Removes both the batch and (when present) the
    /// streaming sibling, so a multi-bundle option's all-or-nothing
    /// invariant survives a retry cycle.
    ///
    /// FluidAudio's downloader strips the trailing `-coreml` suffix
    /// from the supplied directory name and re-derives the actual
    /// folder via `Repo.folderName`. As a result `cacheURL(for:)`
    /// returns a *placeholder* path the SDK never writes to (e.g.
    /// `<root>/parakeet-tdt-0.6b-v3-coreml`), while files actually
    /// land at `<root>/parakeet-tdt-0.6b-v3`. Both are deleted here so
    /// removeCache is genuine cleanup, not a no-op on the placeholder.
    func removeCache(for id: ParakeetModelID) {
        let fm = FileManager.default
        for url in batchCachePaths(for: id) {
            try? fm.removeItem(at: url)
        }
        if let streamingURL = streamingPartialCacheURL(for: id) {
            try? fm.removeItem(at: streamingURL)
        }
    }

    /// Candidate paths for a batch model bundle: the placeholder
    /// `cacheURL(for:)` (what we hand to FluidAudio's downloader), the
    /// actual FluidAudio-derived path (what the SDK writes to), and for
    /// the int4 v3 option the dedicated parent folder. Used by
    /// `removeCache` to clean both placeholder and real cache slots.
    func batchCachePaths(for id: ParakeetModelID) -> [URL] {
        let placeholder = cacheURL(for: id)
        let derived = placeholder.deletingLastPathComponent().appendingPathComponent(
            id.actualRepoFolderName,
            isDirectory: true
        )
        var paths = placeholder == derived ? [placeholder] : [placeholder, derived]
        if id == .tdt_0_6b_v3_int4 {
            paths.append(root.appendingPathComponent(id.repoFolderName, isDirectory: true))
        }
        return paths
    }
}

private extension ParakeetModelID {
    var actualRepoFolderName: String {
        switch self {
        case .tdt_0_6b_v3_int4:
            return "parakeet-tdt-0.6b-v3"
        case .tdt_0_6b_v3, .tdt_0_6b_v2_en_streaming:
            return repoFolderName.replacingOccurrences(of: "-coreml", with: "")
        case .tdt_0_6b_ja:
            return repoFolderName
        }
    }
}
