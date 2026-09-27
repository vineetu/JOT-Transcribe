import CoreML
import FluidAudio
import Foundation

/// Errors surfaced by `DiarizerHolder` beyond what FluidAudio itself throws.
enum DiarizerHolderError: Error, LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The speaker-recognition model isn't loaded yet."
        }
    }
}

/// Lifecycle owner for the NVIDIA Nemotron 3 speaker diarizer
/// (FluidAudio `Nemotron3Diarizer`, `fast128` preset) — the sibling of
/// `TranscriberHolder` for speaker diarization
/// (`docs/speaker-diarization/nemotron-migration.md`).
///
/// Not warmed at launch and no master on/off toggle — it only runs when the
/// user taps "Detect speakers" (or an import auto-diarizes). `prepareIfNeeded()`
/// is called lazily the first time that happens, or when the user explicitly
/// taps "Download" in Settings → Speaker labels.
///
/// The only file in the app that touches FluidAudio's diarization types:
/// `process` hands back Jot-owned `DiarSegment`s.
@MainActor
final class DiarizerHolder: ObservableObject {

    enum State: Equatable {
        case notDownloaded
        /// Model files are already on disk (downloaded in a prior session) but
        /// not yet loaded into memory this launch. Settings shows this as
        /// "downloaded" — NO Download button — while `prepareIfNeeded()` still
        /// loads it lazily (fast, from cache, no re-download) on first use.
        case downloadedNotLoaded
        case downloading(progress: Double)
        /// Files are on disk (already, or the download just finished); the
        /// CoreML model is being compiled/loaded. Distinct from
        /// `.downloading` so Settings doesn't sit on a full or empty bar.
        case preparing
        case ready
        case failed(message: String)
    }

    @Published private(set) var state: State = .notDownloaded

    private var models: Nemotron3Models?

    /// The one in-flight load. Unstructured on purpose: a caller that gets
    /// cancelled (an import parked because the user started dictating) must
    /// not cancel the download under everyone else — that would purge the
    /// partial ~190 MB fetch and restart it from zero. Every concurrent
    /// `prepareIfNeeded()` awaits this same task; it clears itself when done.
    private var loadTask: Task<Void, Error>?

    /// Monolithic `fast128`: 10.24 s of audio per model call, the largest
    /// chunk that still compiles for the ANE, and the best quality of the
    /// streaming presets (bench: 0.9 % speaker confusion on AMI).
    nonisolated static let config: Nemotron3Config = .fast128

    /// Audio fed per `CoreMLInferenceGate` hold (design A2). The gate is
    /// released between blocks, so a dictation that starts mid-diarization
    /// waits for at most one block (~0.2 s of inference at ~250× realtime).
    nonisolated static let blockSeconds: Double = 45

    /// `~/Library/Application Support/Jot/Models/Diarizer/` — own subdir,
    /// parallel to `ModelCache.shared.root` (`.../Models/Parakeet/`).
    /// FluidAudio nests `nemotron-3-diarization/` inside it.
    let cacheDirectory: URL

    init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let appSupport = try! FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.cacheDirectory = appSupport.appendingPathComponent("Jot/Models/Diarizer", isDirectory: true)
        }
        removeRetiredModelFiles()
        refreshCachedStateIfNeeded()
    }

    var isReady: Bool { state == .ready }

    /// `<cacheDirectory>/nemotron-3-diarization/` — the repo folder
    /// `Nemotron3Models.loadFromHuggingFace` downloads into.
    nonisolated static func repoDirectory(in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent(Repo.nemotron3Diarization.folderName, isDirectory: true)
    }

    /// Whether a complete copy of the CURRENT weights is on disk: the
    /// compiled bundle's manifest, the root silence embedding, and a
    /// weights-version marker whose CONTENT matches this FluidAudio build's
    /// `weightsVersion` (A6). A marker from an older checkpoint reads as
    /// "not downloaded" — `loadFromHuggingFace` would purge and re-fetch it,
    /// so Settings must offer the download rather than claim it's there.
    nonisolated static func modelsPresent(in cacheDirectory: URL) -> Bool {
        let repo = repoDirectory(in: cacheDirectory)
        let fm = FileManager.default
        let manifest = repo
            .appendingPathComponent(config.hubSubdirectory, isDirectory: true)
            .appendingPathComponent(config.modelFileName, isDirectory: true)
            .appendingPathComponent("coremldata.bin")
        let silence = repo.appendingPathComponent(ModelNames.Nemotron3.silenceEmbeddingFile)
        let marker = repo.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
        guard fm.fileExists(atPath: manifest.path), fm.fileExists(atPath: silence.path) else { return false }
        let cached = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cached == ModelNames.Nemotron3.weightsVersion
    }

    /// Best-effort removal of what the retired pyannote/VBx diarizer left in
    /// `cacheDirectory`: its model folder and the old owner voiceprint
    /// (voiceprints were dropped). Missing files are a no-op, so after the
    /// first launch on this version it costs two failed stats.
    private func removeRetiredModelFiles() {
        let fm = FileManager.default
        for name in ["speaker-diarization", "owner-voiceprint.json"] {
            let url = cacheDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Cheap, synchronous, no-network check of whether the diarizer's model
    /// is already on disk — lets Settings reflect "already downloaded" on a
    /// fresh launch (before anyone taps anything) without paying for the
    /// full async model load. Never downgrades an in-memory `.ready` /
    /// in-flight `.downloading` / `.preparing` state.
    func refreshCachedStateIfNeeded() {
        guard state == .notDownloaded else { return }
        if Self.modelsPresent(in: cacheDirectory) {
            // Present on disk from a prior download. Surface it as
            // "downloaded" (`.downloadedNotLoaded`) so Settings stops offering
            // a re-download on every launch. It's still not loaded into memory
            // this session — the next `prepareIfNeeded()` (first "Detect
            // speakers") loads it fast from this cache and flips to `.ready`.
            state = .downloadedNotLoaded
        }
    }

    /// Load (downloading if needed) the diarizer model. Idempotent: a call
    /// while `.ready` returns at once, and concurrent calls all await the
    /// same load, so every caller comes back with the model ready (or the
    /// same error). After a failure the next call starts a fresh attempt.
    func prepareIfNeeded() async throws {
        if case .ready = state { return }
        if let loadTask {
            return try await loadTask.value
        }
        let task = Task { @MainActor in
            defer { self.loadTask = nil }
            try await self.load()
        }
        loadTask = task
        try await task.value
    }

    private func load() async throws {
        state = Self.modelsPresent(in: cacheDirectory) ? .preparing : .downloading(progress: 0)
        do {
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: Self.config,
                cacheDirectory: cacheDirectory,
                computeUnits: .all,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        // Subdirectory downloads report 0…1 with no compile
                        // phase; at 1 the model load is what's left.
                        self.state = progress.fractionCompleted >= 1
                            ? .preparing
                            : .downloading(progress: progress.fractionCompleted)
                    }
                }
            )
            self.models = models
            self.state = .ready
        } catch {
            self.state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    /// Diarize a 16 kHz mono Float32 buffer into exclusive speech runs
    /// (`DiarizationProjection.project`).
    ///
    /// Runs the streaming API (`appendAudio` / `processBufferedAudio` /
    /// `finishStream` — frame-exact with `processComplete`) in
    /// `blockSeconds` blocks. Each block holds `CoreMLInferenceGate` (design
    /// D6: the ASR and diarizer CoreML graphs must never run concurrently)
    /// and runs off the main actor; between blocks the gate is released and
    /// cancellation is checked, so neither a dictation nor a cancel waits on
    /// a whole hour-long file (A2). Two overlapping runs (a manual Detect
    /// plus an import) share `models`' preallocated I/O buffers; that is safe
    /// for the same reason — every model call happens inside a gated block.
    func process(samples: [Float]) async throws -> [DiarSegment] {
        guard let models else { throw DiarizerHolderError.notReady }
        let run = BlockRun(diarizer: Nemotron3Diarizer(config: Self.config, models: models))
        let blockSize = Int(Self.blockSeconds * 16_000)

        var probabilities: [Float] = []
        var frameCount = 0
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let end = min(offset + blockSize, samples.count)
            let block = Array(samples[offset..<end])
            let isLast = end == samples.count

            await CoreMLInferenceGate.shared.acquire()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try run.feed(block, finish: isLast) }
            }.value
            await CoreMLInferenceGate.shared.release()

            for chunk in try result.get() {
                probabilities.append(contentsOf: chunk.probabilities)
                frameCount += chunk.frameCount
            }
            offset = end
        } while offset < samples.count
        try Task.checkCancellation()

        return DiarizationProjection.project(
            probabilities: probabilities,
            frameCount: frameCount,
            numSpeakers: Self.config.numSpeakers
        )
    }

    /// One diarization run's `Nemotron3Diarizer` (a synchronous,
    /// non-`Sendable` class holding the streaming state). `process` hands it
    /// to exactly one detached task at a time and awaits each before the
    /// next, so it is never touched concurrently — hence `@unchecked`.
    private final class BlockRun: @unchecked Sendable {
        private let diarizer: Nemotron3Diarizer

        init(diarizer: Nemotron3Diarizer) {
            self.diarizer = diarizer
        }

        func feed(_ samples: [Float], finish: Bool) throws -> [Nemotron3ChunkResult] {
            diarizer.appendAudio(samples)
            var results = try diarizer.processBufferedAudio()
            if finish {
                results += try diarizer.finishStream()
            }
            return results
        }
    }
}
