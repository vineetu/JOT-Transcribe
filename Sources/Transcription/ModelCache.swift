import FluidAudio
import Foundation

/// The two engine sides a model bundle can have on disk. The startup
/// integrity self-heal reports per-side load failures and purges only the
/// failed side (see `DualPipelineTranscriber.probeIntegrity`,
/// `ModelCache.removeCache(for:removeBatch:removeStreaming:)`).
public enum ModelSide: Sendable, Equatable {
    /// The batch final-transcript bundle (FluidAudio `AsrModels`). For
    /// `.nemotron_en` there is no separate batch bundle; the streaming
    /// bundle backs both sides.
    case batch
    /// The streaming/live-preview bundle (EOU or Nemotron).
    case streaming
}

/// Owns the on-disk location of downloaded Parakeet/Nemotron models.
///
/// Root lives under the app's Application Support container rather than
/// FluidAudio's default `~/Library/Application Support/FluidAudio/Models/` -
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
    /// given option. For the int4 v3 option, this uses a dedicated parent
    /// folder so FluidAudio's SDK-derived `parakeet-tdt-0.6b-v3` directory
    /// does not overlap with the default v3 install. The visible
    /// multilingual+Nemotron option deliberately shares the default v3 cache.
    public func cacheURL(for id: ParakeetModelID) -> URL {
        let base = root.appendingPathComponent(id.repoFolderName, isDirectory: true)
        switch id {
        case .tdt_0_6b_v3_int4:
            return base.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .nemotron_en:
            return base
        }
    }

    /// Directory where the streaming-side model bundle for a streaming-
    /// enabled option lives:
    /// - EOU (v2 legacy + v3 default): `root/parakeet-eou-streaming/160ms/`
    /// - Nemotron: `root/nemotron-streaming-en-1120ms/`
    ///
    /// The v3+EOU and v2+EOU options share the same on-disk EOU streaming
    /// bundle; UI must protect against deletion of one while the other is
    /// the active primary.
    public func streamingPartialCacheURL(for id: ParakeetModelID) -> URL? {
        switch id {
        case .tdt_0_6b_v2_en_streaming, .tdt_0_6b_v3_eou_streaming:
            return root
                .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
                .appendingPathComponent("160ms", isDirectory: true)
        case .tdt_0_6b_v3_nemotron_streaming, .nemotron_en:
            return root.appendingPathComponent("nemotron-streaming-en-1120ms", isDirectory: true)
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return nil
        }
    }

    /// Temporary FluidAudio-shaped root used while downloading Nemotron.
    /// `DownloadUtils.downloadRepo(.nemotronStreaming1120, to:)` appends
    /// `nemotron-streaming/1120ms`; after a successful download Jot moves
    /// that produced directory into `streamingPartialCacheURL(for:)`.
    func streamingNemotronStagingRoot(for id: ParakeetModelID) -> URL? {
        switch id {
        case .tdt_0_6b_v3_nemotron_streaming, .nemotron_en:
            return root.appendingPathComponent("nemotron-streaming-en-1120ms-staging", isDirectory: true)
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_v3_eou_streaming,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming:
            return nil
        }
    }

    func streamingNemotronStagingURL(for id: ParakeetModelID) -> URL? {
        guard let stagingRoot = streamingNemotronStagingRoot(for: id) else { return nil }
        return stagingRoot
            .appendingPathComponent("nemotron-streaming", isDirectory: true)
            .appendingPathComponent("1120ms", isDirectory: true)
    }

    /// Per-side presence of a model's on-disk bundle. Used by the
    /// startup integrity self-heal (`TranscriberHolder.beginSelfHeal`) to
    /// disambiguate a *missing* side (downloadIfMissing will fetch it) from
    /// a *present-but-load-failed* side (corrupt — purge then re-download).
    /// Mirrors `isCached`'s presence semantics, scoped to one engine side:
    /// `.batch` → `batchBundleExists`, `.streaming` → `streamingPartialBundleExists`.
    /// For `.nemotron_en` the streaming bundle IS both sides, so a `.batch`
    /// query returns the streaming presence too (matching `isCached`'s
    /// single-side passthrough).
    func stillPresent(_ id: ParakeetModelID, side: ModelSide) -> Bool {
        if id == .nemotron_en {
            // Nemotron has no separate batch bundle; the streaming bundle
            // backs both preview and final. Treat either side query as the
            // streaming presence so the self-heal's per-side purge/verify
            // works on the single real bundle.
            return streamingPartialBundleExists(for: id)
        }
        switch side {
        case .batch:
            return batchBundleExists(for: id)
        case .streaming:
            return streamingPartialBundleExists(for: id)
        }
    }

    /// True when every file the loader will need is on disk.
    ///
    /// NOTE: this is a **presence/completeness** check, NOT an integrity
    /// check — a truncated/corrupt-but-present file passes `isCached` and
    /// only fails later at *load*. The startup self-heal relies on a strict
    /// load probe (`DualPipelineTranscriber.probeIntegrity`) to catch
    /// corruption that presence alone cannot.
    ///
    /// Batch Parakeet options delegate to FluidAudio's
    /// `AsrModels.modelsExist`, which is the authoritative check for "every
    /// preprocessor / encoder / decoder / joint / vocabulary file is
    /// present". Nemotron checks FluidAudio's `ModelNames.NemotronStreaming`
    /// file list, including its own `encoder/encoder_int8.mlmodelc`.
    public func isCached(_ id: ParakeetModelID) -> Bool {
        if id == .nemotron_en {
            return streamingPartialBundleExists(for: id)
        }

        let batchPresent = batchBundleExists(for: id)
        guard id.supportsStreaming else { return batchPresent }
        guard batchPresent else { return false }
        return streamingPartialBundleExists(for: id)
    }

    func batchBundleExists(for id: ParakeetModelID) -> Bool {
        switch id {
        case .nemotron_en:
            return false
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return AsrModels.modelsExist(
                at: cacheURL(for: id),
                version: id.fluidAudioVersion,
                encoderPrecision: id.encoderPrecision
            )
        }
    }

    func streamingPartialBundleExists(for id: ParakeetModelID) -> Bool {
        guard let streamingURL = streamingPartialCacheURL(for: id) else { return false }
        return Self.streamingBundleExists(at: streamingURL, for: id)
    }

    private static func streamingBundleExists(at directory: URL, for id: ParakeetModelID) -> Bool {
        let fm = FileManager.default
        let requiredModels: Set<String>
        switch id {
        case .tdt_0_6b_v2_en_streaming, .tdt_0_6b_v3_eou_streaming:
            requiredModels = ModelNames.ParakeetEOU.requiredModels
        case .tdt_0_6b_v3_nemotron_streaming, .nemotron_en:
            requiredModels = ModelNames.NemotronStreaming.requiredModels
        case .tdt_0_6b_v3, .tdt_0_6b_v3_int4, .tdt_0_6b_ja:
            return false
        }
        return requiredModels.allSatisfy { name in
            fm.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Remove a cached model. `.nemotron_en` removes only the shared Nemotron
    /// streaming directory; the default v3 batch cache may still be needed by
    /// `.tdt_0_6b_v3_nemotron_streaming`.
    func removeCache(for id: ParakeetModelID) {
        removeCache(for: id, removeBatch: true, removeStreaming: true)
    }

    /// Surgically remove only the requested side(s). The startup self-heal
    /// uses this (NEVER the blunt `removeCache(for:)`) so purging a corrupt
    /// streaming side never evicts the SHARED v3 batch bundle that other
    /// options depend on.
    func removeCache(for id: ParakeetModelID, removeBatch: Bool, removeStreaming: Bool) {
        let fm = FileManager.default
        if removeBatch {
            for url in batchCachePaths(for: id) {
                try? fm.removeItem(at: url)
            }
        }
        if removeStreaming, let streamingURL = streamingPartialCacheURL(for: id) {
            try? fm.removeItem(at: streamingURL)
        }
        if removeStreaming, let stagingRoot = streamingNemotronStagingRoot(for: id) {
            try? fm.removeItem(at: stagingRoot)
        }
    }

    /// Candidate paths for a batch model bundle: the placeholder
    /// `cacheURL(for:)` (what we hand to FluidAudio's downloader), the
    /// actual FluidAudio-derived path (what the SDK writes to), and for
    /// the int4 v3 option the dedicated parent folder.
    func batchCachePaths(for id: ParakeetModelID) -> [URL] {
        if id == .nemotron_en {
            return []
        }

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
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming,
             .tdt_0_6b_v2_en_streaming:
            return repoFolderName.replacingOccurrences(of: "-coreml", with: "")
        case .tdt_0_6b_ja, .nemotron_en:
            return repoFolderName
        }
    }
}
