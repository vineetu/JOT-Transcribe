import CoreMLLLM
import Foundation
import OSLog

/// On-device sentence-embedding encoder backed by **EmbeddingGemma-300M**
/// (Core ML / ANE via the `CoreMLLLM` package). Exposes a single
/// `encode(_:role:) -> [Float]` surface so callers depend only on the `[Float]`
/// shape and a future model swap stays contained to this file.
///
/// Ported from jot-mobile (`jot-mobile/Jot/App/Embeddings/EmbeddingGemmaService.swift`).
/// The macOS difference is **model acquisition**: mobile bundles the artifact in
/// `Resources/Models/EmbeddingGemma/`; here we **download it on first load** to
/// the app's Application Support container — exactly the posture Jot already uses
/// for the Parakeet/Sortformer speech models (downloaded, never bundled). The
/// download is handled by the package's own `Gemma3BundleDownloader`, which knows
/// the canonical HuggingFace file list, skips files already on disk (self-heal),
/// and reports incremental progress.
///
/// ## Model
///
/// EmbeddingGemma-300M Core ML bundle (~328 MB: `encoder.mlmodelc` 295 MB INT8 +
/// `hf_model/tokenizer.json` 33 MB), downloaded from the public HuggingFace repo
/// `mlboydaisuke/embeddinggemma-300m-coreml` to
/// `~/Library/Application Support/Jot/Models/EmbeddingGemma/embeddinggemma-300m/`.
/// Bundle layout the loader expects (`EmbeddingGemma.load`):
/// `encoder.mlmodelc` + `model_config.json` + `hf_model/tokenizer.json`.
///
/// ## Output shape
///
/// 256-d float32, unit-norm (Matryoshka truncation of the native 768-d — the
/// `dim` arg does the truncate + L2-renormalize inside the package). The
/// asymmetric `role` maps to EmbeddingGemma's task prefixes (`retrieval_query`
/// vs `retrieval_document`) — queries and documents are encoded differently,
/// which materially improves retrieval.
///
/// ## Why an `actor`
///
/// Pure transform, no UI state; the `model` + `loadTask` shared state is exactly
/// what an `actor` is for. Callers `await` from any context; encode runs on the
/// actor's executor; `[Float]` is `Sendable`.
///
/// ## Pre-warm
///
/// `prewarm()` fires a non-blocking force-load. First load downloads (if needed),
/// then compiles + loads the Core ML model into the ANE; subsequent encodes are
/// fast. Concurrent cold callers coalesce onto one in-flight `loadTask`.
actor EmbeddingGemmaService {
    static let shared = EmbeddingGemmaService()

    /// Discriminator stamped on every embedding row written by this service.
    /// Bump when swapping the model or output dim so old rows stay
    /// distinguishable and retrieval can filter to the current version.
    static let modelVersion = "embeddinggemma-300m-256"

    /// Matryoshka output dimension. 256 balances quality vs storage/scan cost
    /// (native is 768; 128/256/512/768 are the supported truncations).
    static let outputDim = 256

    /// Asymmetric encoding role. EmbeddingGemma was trained with task prefixes;
    /// encoding a query vs a stored document differently improves recall.
    enum Role { case query, document }

    private static let log = Logger(
        subsystem: "com.jot.Jot",
        category: "gemma-embedding"
    )

    /// `EmbeddingGemma` is a non-`Sendable` class (it wraps an `MLModel` +
    /// tokenizer). We only ever touch it from this actor's executor, so it's
    /// effectively serialized — box it as `@unchecked Sendable` so the load
    /// `Task`'s result can cross back into actor-isolated state safely.
    private struct LoadedModel: @unchecked Sendable { let model: EmbeddingGemma }

    private var loaded: LoadedModel?
    private var loadTask: Task<LoadedModel, Error>?

    /// Root directory the EmbeddingGemma bundle is downloaded into. Sibling of
    /// the Parakeet model cache (`ModelCache.shared.root` is
    /// `…/Jot/Models/Parakeet`), so all of Jot's models live under
    /// `~/Library/Application Support/Jot/Models/`.
    static var modelsDirectory: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Jot/Models/EmbeddingGemma", isDirectory: true)
    }

    /// True when the model bundle is fully present on disk (no download needed).
    nonisolated static func isDownloaded() -> Bool {
        Gemma3BundleDownloader.localBundle(.embeddingGemma300m, under: modelsDirectory) != nil
    }

    /// Force-load the model, downloading it first if missing. Idempotent;
    /// coalesces concurrent callers. `onProgress` is invoked during the
    /// (one-time) download with byte counts.
    func prewarm(onProgress: ((Gemma3BundleDownloader.Progress) -> Void)? = nil) async throws {
        _ = try await ensureModel(onProgress: onProgress)
    }

    /// Encode `text` into a 256-d unit-norm embedding. `role` selects the
    /// task prefix (`.query` for the question, `.document` for stored chunks).
    func encode(_ text: String, role: Role = .document) async throws -> [Float] {
        let model = try await ensureModel(onProgress: nil)
        let task: EmbeddingGemma.Task = (role == .query) ? .retrievalQuery : .retrievalDocument
        return try model.encode(text: text, task: task, dim: Self.outputDim)
    }

    private func ensureModel(
        onProgress: ((Gemma3BundleDownloader.Progress) -> Void)?
    ) async throws -> EmbeddingGemma {
        if let loaded { return loaded.model }
        if let loadTask { return try await loadTask.value.model }

        let progress = onProgress
        let task = Task<LoadedModel, Error> {
            let dir = Self.modelsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.log.info("Ensuring EmbeddingGemma model in: \(dir.path, privacy: .public)")
            let started = Date()
            // `downloadAndLoad` is a single call: it downloads the bundle from
            // HuggingFace (skipping files already on disk), then loads it.
            // computeUnits defaults to `.cpuAndNeuralEngine` in the package;
            // Jot is Apple-Silicon-only so the ANE path is always available.
            let model = try await EmbeddingGemma.downloadAndLoad(
                modelsDir: dir,
                hfToken: nil,
                onProgress: progress
            )
            let elapsed = Date().timeIntervalSince(started)
            Self.log.info("EmbeddingGemma ready elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s")
            return LoadedModel(model: model)
        }
        loadTask = task
        do {
            let box = try await task.value
            self.loaded = box
            self.loadTask = nil
            return box.model
        } catch {
            self.loadTask = nil
            Self.log.error("EmbeddingGemma load FAILED error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
