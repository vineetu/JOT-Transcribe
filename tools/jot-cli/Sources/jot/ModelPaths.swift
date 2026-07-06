import Foundation

/// Resolves where to load models from. Mirrors the app's `ModelCache` /
/// `DiarizerHolder` on-disk layout (`Sources/Transcription/ModelCache.swift`,
/// `Sources/Diarization/DiarizerHolder.swift`) exactly, so a user who has
/// already run Jot.app doesn't need to download anything a second time.
enum ModelPaths {
    /// `~/Library/Application Support/Jot/Models`
    static var jotModelsRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Jot/Models", isDirectory: true)
    }

    /// Default Parakeet root: `.../Jot/Models/Parakeet`. `--model-dir`
    /// overrides this entire root (not just the leaf bundle dir), matching
    /// `ModelCache.root`.
    static func parakeetRoot(override: String?) -> URL {
        if let override {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return jotModelsRoot.appendingPathComponent("Parakeet", isDirectory: true)
    }

    /// The v3 batch model's on-disk bundle dir under a given Parakeet root.
    /// Matches `ModelCache.cacheURL(for: .tdt_0_6b_v3)` — FluidAudio's
    /// `AsrModels.load` derives the *actual* on-disk folder name (which
    /// drops the `-coreml` suffix) from `directory.deletingLastPathComponent()`,
    /// so this placeholder name is exactly what the app hands FluidAudio too.
    static func parakeetV3BundleDir(root: URL) -> URL {
        root.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
    }

    /// Default offline-diarizer root: `.../Jot/Models/Diarizer`.
    static var diarizerRoot: URL {
        jotModelsRoot.appendingPathComponent("Diarizer", isDirectory: true)
    }
}
