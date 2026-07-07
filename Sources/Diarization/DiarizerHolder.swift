import FluidAudio
import Foundation

/// Errors surfaced by `DiarizerHolder` beyond what `OfflineDiarizerManager`
/// itself throws.
enum DiarizerHolderError: Error, LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The speaker-recognition model isn't loaded yet."
        }
    }
}

/// Lifecycle owner for the FluidAudio offline VBx diarizer
/// (`OfflineDiarizerManager`, pinned 0.15.4) — the sibling of
/// `TranscriberHolder` for speaker diarization
/// (`docs/speaker-diarization/design.md`, Phase 1).
///
/// Unlike the removed Sortformer holder, this is **not** warmed at launch
/// and has **no** master on/off toggle (design decision — offline VBx has
/// no background cost; it only runs when the user taps "Detect speakers").
/// `prepareIfNeeded()` is called lazily the first time that happens, or
/// when the user explicitly taps "Download" in Settings → Speaker labels.
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
        case ready
        case failed(message: String)
    }

    @Published private(set) var state: State = .notDownloaded

    private var manager: OfflineDiarizerManager?

    /// `~/Library/Application Support/Jot/Models/Diarizer/` — own subdir,
    /// parallel to `ModelCache.shared.root` (`.../Models/Parakeet/`).
    /// FluidAudio nests `speaker-diarization/` inside whatever directory
    /// we hand it.
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
        refreshCachedStateIfNeeded()
    }

    var isReady: Bool { state == .ready }

    /// Cheap, synchronous, no-network check of whether the diarizer's
    /// repo folder already exists on disk — lets Settings reflect "already
    /// downloaded" on a fresh launch (before anyone taps anything) without
    /// paying for the full async model load. Never downgrades an in-memory
    /// `.ready` / in-flight `.downloading` state.
    func refreshCachedStateIfNeeded() {
        guard state == .notDownloaded else { return }
        // NOTE: the on-disk model folder is `speaker-diarization` (NOT
        // `…-coreml`) — FluidAudio's OfflineDiarizerModels.load downloads it
        // there. The earlier `-coreml` name never matched, so Settings kept
        // showing "Download" even with the model fully present on disk.
        let repoDir = cacheDirectory.appendingPathComponent("speaker-diarization", isDirectory: true)
        if FileManager.default.fileExists(atPath: repoDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path),
           !contents.isEmpty {
            // Present on disk from a prior download. Surface it as
            // "downloaded" (`.downloadedNotLoaded`) so Settings stops offering
            // a re-download on every launch. It's still not loaded into memory
            // this session — the next `prepareIfNeeded()` (first "Detect
            // speakers") loads it fast from this cache and flips to `.ready`.
            state = .downloadedNotLoaded
        }
    }

    /// Load (downloading if needed) the offline diarizer models. Idempotent
    /// — a second call while `.ready` or `.downloading` is a fast no-op /
    /// no-op respectively.
    func prepareIfNeeded() async throws {
        switch state {
        case .ready:
            return
        case .downloading:
            return
        case .notDownloaded, .downloadedNotLoaded, .failed:
            break
        }

        state = .downloading(progress: 0)
        let directory = cacheDirectory
        do {
            let models = try await OfflineDiarizerModels.load(
                from: directory,
                configuration: nil,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .downloading = self.state {
                            self.state = .downloading(progress: progress.fractionCompleted)
                        }
                    }
                }
            )
            let mgr = OfflineDiarizerManager(config: .default)
            mgr.initialize(models: models)
            self.manager = mgr
            self.state = .ready
        } catch {
            self.state = .failed(message: error.localizedDescription)
            throw error
        }
    }

    /// Run the offline VBx pipeline over a 16 kHz mono Float32 buffer.
    /// Serialized against `Transcriber` via `CoreMLInferenceGate` (design D6).
    func process(samples: [Float]) async throws -> DiarizationResult {
        guard let manager else { throw DiarizerHolderError.notReady }
        // Not routed through `CoreMLInferenceGate.withLock(_:)`: that takes a
        // `@Sendable` closure, and `OfflineDiarizerManager` isn't `Sendable`
        // (capturing it would be a Swift 6 error). Acquire/release directly
        // instead — same serialization guarantee, no closure boundary to cross.
        await CoreMLInferenceGate.shared.acquire()
        defer { Task { await CoreMLInferenceGate.shared.release() } }
        return try await manager.process(audio: samples)
    }
}
