import Foundation

/// Composite `Transcribing` conformer for model choices that have a live
/// preview engine alongside (or instead of) a batch final-transcript engine.
///
/// This remains intentionally explicit rather than protocol-based:
/// - legacy v2 uses TDT v2 batch + EOU streaming,
/// - multilingual live preview uses TDT v3 batch + Nemotron streaming,
/// - Nemotron English uses Nemotron streaming for both preview and final.
final class DualPipelineTranscriber: Transcribing, @unchecked Sendable {

    private enum FinalEngine: Sendable {
        case batch(Transcriber)
        case nemotron(NemotronStreamingTranscriber)
    }

    private enum StreamingEngine: Sendable {
        case eou(StreamingTranscriber)
        case nemotron(NemotronStreamingTranscriber)
        /// Batch pseudo-streaming preview (`PreviewScheduler` re-runs the batch
        /// model over a trailing window). Replaces `.eou` once routing/EOU
        /// removal lands (design §4.2); added here as the stable seam.
        case batchPreview(PreviewScheduler)
    }

    private let finalEngine: FinalEngine
    private let streamingEngine: StreamingEngine
    private let pendingLock = NSLock()
    private var pendingNemotronFinal: String?

    /// Legacy v2 + EOU path.
    init(batch: Transcriber, streaming: StreamingTranscriber) {
        self.finalEngine = .batch(batch)
        self.streamingEngine = .eou(streaming)
    }

    /// Multilingual Parakeet v3 final transcript + Nemotron preview.
    init(batch: Transcriber, nemotronStreaming: NemotronStreamingTranscriber) {
        self.finalEngine = .batch(batch)
        self.streamingEngine = .nemotron(nemotronStreaming)
    }

    /// Batch final transcript + batch-pseudo-streaming preview. The
    /// `PreviewScheduler` must be constructed over the SAME `Transcriber` passed
    /// as `batch`, so the preview re-uses the loaded `AsrModels` (design §4.5).
    /// Not yet routed by the factory — this is the seam the routing/EOU-removal
    /// task plugs into.
    init(batch: Transcriber, batchPreview: PreviewScheduler) {
        self.finalEngine = .batch(batch)
        self.streamingEngine = .batchPreview(batchPreview)
    }

    /// Nemotron-only path: one manager instance provides partials and the
    /// final transcript for a live recording session.
    init(nemotron: NemotronStreamingTranscriber) {
        self.finalEngine = .nemotron(nemotron)
        self.streamingEngine = .nemotron(nemotron)
    }

    // MARK: - Transcribing

    func ensureLoaded() async throws {
        switch finalEngine {
        case .batch(let batch):
            async let batchLoad: Void = batch.ensureLoaded()
            async let streamLoad: Void = ensureStreamingLoadedQuietly()
            _ = try await batchLoad
            _ = await streamLoad
        case .nemotron(let nemotron):
            try await nemotron.ensureLoaded()
        }
    }

    private func ensureStreamingLoadedQuietly() async {
        do {
            switch streamingEngine {
            case .eou(let streaming):
                try await streaming.ensureLoaded()
            case .nemotron(let nemotron):
                try await nemotron.ensureLoaded()
            case .batchPreview:
                // Nothing to load — the scheduler re-uses the batch final
                // engine's already-loaded model (loaded above via `batch`).
                break
            }
        } catch {
            await ErrorLog.shared.error(
                component: "DualPipelineTranscriber",
                message: "Streaming engine load failed (degrading to final-only)",
                context: ["error": ErrorLog.redactedAppleError(error)]
            )
        }
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptionResult {
        switch finalEngine {
        case .batch(let batch):
            return try await batch.transcribe(samples)
        case .nemotron(let nemotron):
            guard samples.count >= Int(AudioFormat.sampleRate) else {
                throw TranscriberError.audioTooShort
            }
            if let final = consumePendingNemotronFinal() {
                return Self.nemotronResult(raw: final, samples: samples, processingTime: 0)
            }

            let started = Date()
            let raw = try await nemotron.transcribeOneShot(samples)
            return Self.nemotronResult(
                raw: raw,
                samples: samples,
                processingTime: Date().timeIntervalSince(started)
            )
        }
    }

    func transcribeFile(_ url: URL) async throws -> TranscriptionResult {
        switch finalEngine {
        case .batch(let batch):
            return try await batch.transcribeFile(url)
        case .nemotron:
            let fallback = Transcriber(modelID: .nemotron_en)
            try await fallback.ensureLoaded()
            return try await fallback.transcribeFile(url)
        }
    }

    var isReady: Bool {
        get async {
            switch finalEngine {
            case .batch(let batch):
                return await batch.isReady
            case .nemotron(let nemotron):
                return await nemotron.isReady
            }
        }
    }

    // MARK: - Streaming session

    func startStreaming(
        generation: UInt64,
        onPartial: @escaping @Sendable (String, UInt64) -> Void
    ) async {
        clearPendingNemotronFinal()
        switch streamingEngine {
        case .eou(let streaming):
            await streaming.start(generation: generation, onPartial: onPartial)
        case .nemotron(let nemotron):
            await nemotron.start(generation: generation, onPartial: onPartial)
        case .batchPreview(let scheduler):
            await scheduler.begin(generation: generation, onPartial: onPartial)
        }
    }

    func enqueueStreaming(samples: [Float]) {
        switch streamingEngine {
        case .eou(let streaming):
            streaming.enqueue(samples: samples)
        case .nemotron(let nemotron):
            nemotron.enqueue(samples: samples)
        case .batchPreview(let scheduler):
            scheduler.enqueue(samples: samples)
        }
    }

    func finishStreaming() async -> String? {
        let final: String?
        switch streamingEngine {
        case .eou(let streaming):
            final = await streaming.finish()
        case .batchPreview(let scheduler):
            // Stop fence: drain + block further ticks BEFORE the caller runs the
            // final batch pass, so no preview decode overlaps it on the
            // module-global `sharedMLArrayCache` (design §4.3.1). Batch is
            // authoritative — the assembled preview text is not used as the final.
            await scheduler.quiesce()
            final = nil
        case .nemotron(let nemotron):
            do {
                final = try await nemotron.finish()
            } catch {
                await ErrorLog.shared.error(
                    component: "DualPipelineTranscriber",
                    message: "Nemotron finish failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
                final = nil
            }
        }

        if case .nemotron = finalEngine, let final {
            storePendingNemotronFinal(final)
        }
        return final
    }

    func cancelStreaming() async {
        clearPendingNemotronFinal()
        switch streamingEngine {
        case .eou(let streaming):
            await streaming.cancel()
        case .nemotron(let nemotron):
            await nemotron.cancel()
        case .batchPreview(let scheduler):
            await scheduler.cancel()
        }
    }

    // MARK: - Nemotron final handoff

    private func storePendingNemotronFinal(_ text: String) {
        pendingLock.lock()
        pendingNemotronFinal = text
        pendingLock.unlock()
    }

    private func consumePendingNemotronFinal() -> String? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let value = pendingNemotronFinal
        pendingNemotronFinal = nil
        return value
    }

    private func clearPendingNemotronFinal() {
        pendingLock.lock()
        pendingNemotronFinal = nil
        pendingLock.unlock()
    }

    private static func nemotronResult(
        raw: String,
        samples: [Float],
        processingTime: TimeInterval
    ) -> TranscriptionResult {
        // v1.13.1: Nemotron emits clean native punctuation + casing.
        // Pure pass-through — no deterministic post-processing.
        return TranscriptionResult(
            text: raw,
            rawText: raw,
            duration: TimeInterval(samples.count) / AudioFormat.sampleRate,
            processingTime: processingTime,
            confidence: 1.0
        )
    }
}
