import CoreML
import CryptoKit
import Foundation
import OSLog
import Tokenizers

/// On-device sentence-embedding encoder backed by **multilingual-e5-small**
/// (Microsoft, MIT License), converted to Core ML for Jot. Exposes a single
/// `encode(_:role:) -> [Float]` surface so callers depend only on the `[Float]`
/// shape and a future model swap stays contained to this file.
///
/// Replaced EmbeddingGemma-300M (Gemma Terms of Use) in v1.23.4: e5 is MIT,
/// about a third of the download, and runs without the CoreML-LLM package.
/// iPhone Jot still uses EmbeddingGemma; the two indexes are never shared.
///
/// ## Model bundle
///
/// One zip (~129 MB unpacked: `encoder.mlmodelc` 113 MB int8 + `tokenizer.json`
/// 17 MB + configs, `LICENSE`, `NOTICE`, `jot-model.json`), downloaded once to
/// `~/Library/Application Support/Jot/Models/SearchE5/multilingual-e5-small/`.
/// Where it comes from is `JOT_SEARCH_MODEL_URL` in Info.plist (a GitHub
/// release on JOT-Transcribe; a flavor build may point elsewhere). Every copy
/// is the same zip, checked against `bundleSHA256` before it is unpacked, so
/// a swapped file is refused.
///
/// The conversion folds attention-masked mean pooling and L2 normalisation into
/// the model: input is 256 token ids + mask (int32), output is the final 384-d
/// unit vector. Built from the source repo at revision 614241f6 with
/// coremltools 9 (fp16 compute, int8 per-channel weights); matches the PyTorch
/// model at cosine ≥ 0.9998.
///
/// ## Roles
///
/// e5 is trained with text prefixes: `"query: "` for what the user asks,
/// `"passage: "` for stored transcript chunks. Encoding the two differently is
/// what makes retrieval work.
///
/// ## Why an `actor`
///
/// Pure transform, no UI state; the loaded model + `loadTask` are exactly
/// what an actor serialises. Concurrent cold callers coalesce onto one load.
actor E5EmbeddingService {
    static let shared = E5EmbeddingService()

    /// Discriminator stamped on every embedding row written by this service.
    /// Bump when swapping the model, its conversion or the output dim: rows at
    /// any other version are hidden from search and purged at launch, and
    /// `backfillMissing()` re-indexes the library at the new version.
    static let modelVersion = "e5-small-int8-384-v1"

    /// Output dimension (e5-small's native width; no truncation).
    static let outputDim = 384

    /// Fixed input length the model was converted with. Longer text is
    /// truncated (the indexer's chunks are sized to fit).
    static let sequenceLength = 256

    /// SHA-256 of the published zip. The same file is served from every host.
    static let bundleSHA256 = "e50e22b88757bc03b5e3e7fb09373b3ce350e3d9470dfd47db14f6bbb5cfa1f2"

    /// Public download location, used when Info.plist carries no override.
    static let defaultBundleURL = URL(string: "https://github.com/vineetu/JOT-Transcribe/releases/download/models-e5-small-v1/multilingual-e5-small.zip")!

    /// Rows written by the model this one replaced. Purged at launch.
    static let retiredModelVersions = ["embeddinggemma-300m-256"]

    enum Role { case query, document }

    struct DownloadProgress: Sendable {
        var bytesReceived: Int64
        var bytesTotal: Int64
    }

    enum ServiceError: LocalizedError {
        case checksumMismatch
        case unpackFailed(String)
        case incompleteBundle
        case badOutput

        var errorDescription: String? {
            switch self {
            case .checksumMismatch: return "The search model download was corrupted. Try again."
            case .unpackFailed(let detail): return "Couldn't unpack the search model (\(detail))."
            case .incompleteBundle: return "The search model download is incomplete. Try again."
            case .badOutput: return "The search model returned an unexpected result."
            }
        }
    }

    private static let log = Logger(subsystem: "com.jot.Jot", category: "e5-embedding")

    /// `MLModel` and the tokenizer aren't `Sendable`; only this actor touches
    /// them, so box them to cross back from the load task.
    private struct LoadedModel: @unchecked Sendable {
        let model: MLModel
        let tokenizer: Tokenizer
        let padID: Int
        let eosID: Int
    }

    private var loaded: LoadedModel?
    private var loadTask: Task<LoadedModel, Error>?
    /// Everyone waiting on the current download (launch prewarm, the Settings
    /// button) sees the same progress.
    private var progressObservers: [@Sendable (DownloadProgress) -> Void] = []
    /// After a failed load, further attempts fail fast for `retryAfter` so a
    /// backfill sweep can't start one 113 MB download per recording.
    private var lastFailure: (date: Date, error: Error)?
    private static let retryAfter: TimeInterval = 10 * 60

    // MARK: - Locations

    static var modelsRoot: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return appSupport.appendingPathComponent("Jot/Models", isDirectory: true)
    }

    static var bundleDirectory: URL {
        modelsRoot.appendingPathComponent("SearchE5/multilingual-e5-small", isDirectory: true)
    }

    /// Where EmbeddingGemma used to live; removed at launch.
    static var retiredModelDirectory: URL {
        modelsRoot.appendingPathComponent("EmbeddingGemma", isDirectory: true)
    }

    static var bundleURL: URL {
        #if DEBUG
        // Test hook: any URL (file:// included) to exercise the download path.
        if let raw = ProcessInfo.processInfo.environment["JOT_SEARCH_MODEL_URL_OVERRIDE"],
           let url = URL(string: raw) {
            return url
        }
        #endif
        if let raw = Bundle.main.object(forInfoDictionaryKey: "JOT_SEARCH_MODEL_URL") as? String,
           let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme == "https" {
            return url
        }
        return defaultBundleURL
    }

    private static let requiredFiles = [
        "encoder.mlmodelc/coremldata.bin",
        "tokenizer.json",
        "tokenizer_config.json",
        "jot-model.json",
    ]

    /// True when the model bundle is fully present on disk (no download needed).
    nonisolated static func isDownloaded() -> Bool {
        let fm = FileManager.default
        return requiredFiles.allSatisfy {
            fm.fileExists(atPath: bundleDirectory.appendingPathComponent($0).path)
        }
    }

    /// Deletes the EmbeddingGemma model folder left by earlier versions.
    nonisolated static func removeRetiredModel() {
        let dir = retiredModelDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            log.info("Removed retired EmbeddingGemma model")
        } catch {
            log.error("Couldn't remove retired EmbeddingGemma model: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Public surface

    /// Force-load the model, downloading it first if missing. Idempotent;
    /// coalesces concurrent callers. `onProgress` reports the one-time download.
    func prewarm(onProgress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        _ = try await ensureModel(onProgress: onProgress)
    }

    /// Encode `text` into a 384-d unit-norm embedding.
    func encode(_ text: String, role: Role = .document) async throws -> [Float] {
        let m = try await ensureModel(onProgress: nil)
        let prefix = role == .query ? "query: " : "passage: "
        let ids = Self.fit(m.tokenizer.encode(text: prefix + text), eosID: m.eosID)

        let n = Self.sequenceLength
        let shape = [1, n] as [NSNumber]
        let inputIDs = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        for i in 0..<n {
            let real = i < ids.count
            inputIDs[i] = NSNumber(value: Int32(real ? ids[i] : m.padID))
            mask[i] = NSNumber(value: Int32(real ? 1 : 0))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let out = try await m.model.prediction(from: input)
        guard let array = out.featureValue(for: "embedding")?.multiArrayValue,
              array.count == Self.outputDim else { throw ServiceError.badOutput }

        var vector = (0..<array.count).map { array[$0].floatValue }
        // The model already normalises; re-normalise so fp16 drift can't
        // shift scores against the cut-offs.
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 0 else { throw ServiceError.badOutput }
        for i in vector.indices { vector[i] /= norm }
        return vector
    }

    #if DEBUG
    /// The ids `encode` feeds the model (prefix added, fitted). For the self-test.
    func tokenIDs(_ text: String, role: Role) async throws -> [Int] {
        let m = try await ensureModel(onProgress: nil)
        let prefix = role == .query ? "query: " : "passage: "
        return Self.fit(m.tokenizer.encode(text: prefix + text), eosID: m.eosID)
    }
    #endif

    /// Truncate to the model's window, keeping the closing `</s>` the model
    /// was trained to see.
    static func fit(_ ids: [Int], eosID: Int) -> [Int] {
        guard ids.count > sequenceLength else { return ids }
        return Array(ids.prefix(sequenceLength - 1)) + [eosID]
    }

    // MARK: - Load

    private func ensureModel(
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> LoadedModel {
        if let loaded { return loaded }
        if let onProgress { progressObservers.append(onProgress) }
        if let loadTask { return try await loadTask.value }
        // A user pressing Download (onProgress set) always gets a fresh try;
        // background callers wait out the backoff.
        if onProgress == nil, let lastFailure,
           Date().timeIntervalSince(lastFailure.date) < Self.retryAfter {
            throw lastFailure.error
        }

        let report: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { await self?.broadcast(progress) }
        }
        let task = Task<LoadedModel, Error> {
            let started = Date()
            if !Self.isDownloaded() {
                try await Self.download(onProgress: report)
            }
            do {
                return try await Self.load(started: started)
            } catch {
                // Files present but unloadable (damaged weights, bad
                // tokenizer): remove them so the next attempt re-downloads
                // instead of failing the same way forever.
                Self.log.error("e5 bundle unloadable, removing for re-download: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: Self.bundleDirectory)
                throw error
            }
        }
        loadTask = task
        do {
            let box = try await task.value
            loaded = box
            loadTask = nil
            lastFailure = nil
            progressObservers.removeAll()
            return box
        } catch {
            loadTask = nil
            lastFailure = (Date(), error)
            progressObservers.removeAll()
            Self.log.error("e5 load FAILED error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func broadcast(_ progress: DownloadProgress) {
        for observer in progressObservers { observer(progress) }
    }

    private static func load(started: Date) async throws -> LoadedModel {
        let dir = bundleDirectory
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try await MLModel.load(
            contentsOf: dir.appendingPathComponent("encoder.mlmodelc"),
            configuration: config
        )
        let tokenizer = try await AutoTokenizer.from(modelFolder: dir)
        let padID = tokenizer.convertTokenToId("<pad>") ?? 1
        let eosID = tokenizer.eosTokenId ?? 2
        let elapsed = Date().timeIntervalSince(started)
        log.info("e5 ready elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s")
        return LoadedModel(model: model, tokenizer: tokenizer, padID: padID, eosID: eosID)
    }

    // MARK: - Download

    /// Download the zip, verify its SHA-256, unpack it next to the final
    /// location and move it into place, so a partial download never looks
    /// installed.
    private static func download(onProgress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        let fm = FileManager.default
        let source = bundleURL
        log.info("Downloading search model from \(source.host() ?? "?", privacy: .public)")

        let zip = try await ProgressDownload.fetch(source, onProgress: onProgress)
        defer { try? fm.removeItem(at: zip) }

        let digest = try sha256(of: zip)
        guard digest == bundleSHA256 else {
            log.error("Search model checksum mismatch: \(digest, privacy: .public)")
            throw ServiceError.checksumMismatch
        }

        let parent = bundleDirectory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Staging folders left by an install that was killed mid-unpack.
        for leftover in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where leftover.hasPrefix(".unpack-") {
            try? fm.removeItem(at: parent.appendingPathComponent(leftover))
        }
        let staging = parent.appendingPathComponent(".unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try unzip(zip, into: staging)

        let unpacked = staging.appendingPathComponent(bundleDirectory.lastPathComponent, isDirectory: true)
        guard requiredFiles.allSatisfy({ fm.fileExists(atPath: unpacked.appendingPathComponent($0).path) }) else {
            throw ServiceError.incompleteBundle
        }
        if fm.fileExists(atPath: bundleDirectory.path) {
            try fm.removeItem(at: bundleDirectory)
        }
        try fm.moveItem(at: unpacked, to: bundleDirectory)
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unzip(_ zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dir.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ServiceError.unpackFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// A one-file download that reports byte progress, for the search model.
private final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (@Sendable (E5EmbeddingService.DownloadProgress) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: (@Sendable (E5EmbeddingService.DownloadProgress) -> Void)?) {
        self.onProgress = onProgress
    }

    static func fetch(
        _ url: URL,
        onProgress: (@Sendable (E5EmbeddingService.DownloadProgress) -> Void)?
    ) async throws -> URL {
        let delegate = ProgressDownload(onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(.init(bytesReceived: totalBytesWritten,
                          bytesTotal: max(totalBytesExpectedToWrite, 0)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns; move it somewhere we own.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("jot-search-model-\(UUID().uuidString).zip")
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "The search model download failed (HTTP \(http.statusCode)).",
            ])))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
