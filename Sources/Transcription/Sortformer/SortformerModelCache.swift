import FluidAudio
import Foundation

/// Owns the on-disk location of the downloaded Sortformer streaming
/// diarization model. Lives alongside the Parakeet `ModelCache` under the
/// app's Application Support container — Speaker Labels piece A only ships
/// one variant (`fastV2_1`, 1.04 s latency, 4-speaker cap).
///
/// Disk root: `~/Library/Application Support/Jot/Models/Sortformer/`.
/// Inside that root, FluidAudio writes the variant under its own
/// `sortformer/` subdirectory (the `Repo.sortformer.folderName`), so the
/// on-disk path for the shipped variant becomes
/// `…/Jot/Models/Sortformer/sortformer/Sortformer_v2.1.mlmodelc`.
public struct SortformerModelCache: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static let shared: SortformerModelCache = {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return SortformerModelCache(
            root: appSupport.appendingPathComponent(
                "Jot/Models/Sortformer", isDirectory: true
            )
        )
    }()

    /// The fixed Sortformer variant shipped in v1.14 piece A.
    public static let variant: ModelNames.Sortformer.Variant = .fastV2_1

    /// The on-disk URL of the `.mlmodelc` bundle (a directory) for the
    /// shipped variant. This is the path Jot would hand to
    /// `SortformerModels.load(mainModelPath:)` if loading from local disk.
    public var bundleURL: URL {
        root
            .appendingPathComponent("sortformer", isDirectory: true)
            .appendingPathComponent(Self.variant.fileName, isDirectory: true)
    }

    /// True when the variant's CoreML bundle directory exists on disk.
    /// FluidAudio downloads complete by writing the `.mlmodelc` directory
    /// atomically, so existence of the directory is a sufficient signal that
    /// the download finished — no per-file allowlist needed.
    public var isCached: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: bundleURL.path,
            isDirectory: &isDir
        )
        return exists && isDir.boolValue
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Remove the cached Sortformer bundle and its parent variant directory.
    /// Equivalent to "delete the model and free disk space"; identities and
    /// voice clips live in SwiftData and are not touched here.
    public func removeCache() {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("sortformer", isDirectory: true))
    }
}
