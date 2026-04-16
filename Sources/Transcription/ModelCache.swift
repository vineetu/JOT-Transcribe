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

    /// Directory where the files for a given model live. FluidAudio's
    /// downloader lays files out at `root/<repoFolderName>/...`; consumers
    /// that load the model point `AsrModels.load(from:)` at this URL.
    public func cacheURL(for id: ParakeetModelID) -> URL {
        root.appendingPathComponent(id.repoFolderName, isDirectory: true)
    }

    /// True when every file the SDK needs is on disk.
    ///
    /// Delegates to `AsrModels.modelsExist` because only the SDK knows the
    /// exact set of required files (preprocessor / decoder / joint plus the
    /// vocabulary JSON, with the list differing for fused-encoder vs.
    /// split-encoder variants). A mere "directory exists" check would falsely
    /// claim success on a partial download.
    public func isCached(_ id: ParakeetModelID) -> Bool {
        AsrModels.modelsExist(at: cacheURL(for: id), version: id.fluidAudioVersion)
    }

    public func ensureRootExists() throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    /// Remove a cached model. Used after a failed download so the next retry
    /// starts clean.
    func removeCache(for id: ParakeetModelID) {
        let url = cacheURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }
}
