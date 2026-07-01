import Foundation

/// Composite `Transcribing` conformer for model choices that have a live
/// preview engine alongside (or instead of) a batch final-transcript engine.
///
/// This remains intentionally explicit rather than protocol-based:
/// - v2 / v3 / JA use a batch final transcript + a batch-pseudo-streaming
///   `PreviewScheduler` live preview (re-runs the batch model over a trailing
///   window),
/// - the retired multilingual pairing uses TDT v3 batch + Nemotron streaming,
/// - Nemotron English uses Nemotron streaming for both preview and final.
final class DualPipelineTranscriber: Transcribing, @unchecked Sendable {

    private enum FinalEngine: Sendable {
        case batch(Transcriber)
        case nemotron(any NemotronStreamingEngine)
    }

    private enum StreamingEngine: Sendable {
        case nemotron(any NemotronStreamingEngine)
        /// Batch pseudo-streaming preview (`PreviewScheduler` re-runs the batch
        /// model over a trailing window). The live preview path for v2 / v3 /
        /// JA (design §4.2).
        case batchPreview(PreviewScheduler)
    }

    private let finalEngine: FinalEngine
    private let streamingEngine: StreamingEngine
    private let pendingLock = NSLock()
    private var pendingNemotronFinal: String?

    /// Multilingual Parakeet v3 final transcript + Nemotron preview.
    init(batch: Transcriber, nemotronStreaming: NemotronStreamingTranscriber) {
        self.finalEngine = .batch(batch)
        self.streamingEngine = .nemotron(nemotronStreaming)
    }

    /// Batch final transcript + batch-pseudo-streaming preview. The
    /// `PreviewScheduler` must be constructed over the SAME `Transcriber` passed
    /// as `batch`, so the preview re-uses the loaded `AsrModels` (design §4.5).
    /// This is the live preview path for v2 / v3 / JA.
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

    /// Nemotron-multilingual-only path: identical control flow to the English
    /// Nemotron path, behind the shared `NemotronStreamingEngine` protocol.
    init(nemotronMultilingual: NemotronMultilingualStreamingTranscriber) {
        self.finalEngine = .nemotron(nemotronMultilingual)
        self.streamingEngine = .nemotron(nemotronMultilingual)
    }

    /// True when the final transcript runs the Nemotron CTC-gate vocabulary path
    /// (`nemotronResult` → spot + `gateDetections`). Batch models (v3 / v2 / JA)
    /// use the rescorer path instead, so the streaming CTC spotter only applies
    /// here. The recording pipeline reads this to decide whether to tee audio to
    /// a `StreamingCtcSpotter`.
    var usesNemotronVocabGate: Bool {
        if case .nemotron = finalEngine { return true }
        return false
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

    /// Per-side strict integrity probe for the startup self-heal (design
    /// §Phase 1, review B1 + G2). Unlike `ensureLoaded()`, this does NOT
    /// route the streaming side through `ensureStreamingLoadedQuietly` — that
    /// path swallows streaming load errors for *runtime degradation
    /// tolerance*, which would let a batch-healthy / preview-corrupt bundle
    /// pass and skip the heal. Here each side is loaded strictly and its
    /// load result (success/failure) is reported back so the caller can purge
    /// + re-download ONLY the side that actually failed.
    ///
    /// This loads the SAME live engines this instance already holds — it is
    /// the single launch load (review G1), not a second loader, so there is
    /// no double multi-GB ANE load and no race on FluidAudio's process-global
    /// `sharedMLArrayCache`.
    ///
    /// `nil` for a side means "this configuration has no such side" (e.g. a
    /// `.batchPreview` streaming engine re-uses the batch model, so there is
    /// nothing distinct to load/fail on the streaming side).
    func probeIntegrity() async -> (batch: Result<Void, Error>?, streaming: Result<Void, Error>?) {
        let batchResult: Result<Void, Error>?
        switch finalEngine {
        case .batch(let batch):
            do { try await batch.ensureLoaded(); batchResult = .success(()) }
            catch { batchResult = .failure(error) }
        case .nemotron(let nemotron):
            // Nemotron-only: one engine backs both preview and final. Probe
            // it once as the "batch" (final) side; the streaming side is the
            // same engine and is reported as `nil` (single-side passthrough).
            do { try await nemotron.ensureLoaded(); batchResult = .success(()) }
            catch { batchResult = .failure(error) }
        }

        let streamingResult: Result<Void, Error>?
        switch streamingEngine {
        case .nemotron(let nemotron):
            if case .nemotron = finalEngine {
                // Nemotron-only: streaming == final, already probed above.
                streamingResult = nil
            } else {
                do { try await nemotron.ensureLoaded(); streamingResult = .success(()) }
                catch { streamingResult = .failure(error) }
            }
        case .batchPreview:
            // Re-uses the batch final engine — nothing distinct to probe.
            streamingResult = nil
        }

        return (batch: batchResult, streaming: streamingResult)
    }

    private func ensureStreamingLoadedQuietly() async {
        do {
            switch streamingEngine {
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

    func transcribe(
        _ samples: [Float],
        recordsProvenance: Bool
    ) async throws -> TranscriptionResult {
        switch finalEngine {
        case .batch(let batch):
            return try await batch.transcribe(samples, recordsProvenance: recordsProvenance)
        case .nemotron(let nemotron):
            guard samples.count >= Int(AudioFormat.sampleRate) else {
                throw TranscriberError.audioTooShort
            }
            // Own the shared provenance slot for the saving path: clear any
            // stale `pending` proposals at the START (mirrors the TDT path in
            // `Transcriber.transcribe`). Without this, a prior dictation that
            // filled `pending` but never reached `commit` (save error / discard)
            // could have its vocab proposals committed under THIS recording's id.
            if recordsProvenance {
                await CorrectionProvenance.shared.clearPending()
            }
            // The final transcript is ALWAYS a fresh one-shot decode over the
            // full captured audio — never the live streamed accumulation.
            //
            // Why: on a cold model the streaming consumer only starts decoding
            // ~1s into the recording (model warm-up), and `finish()` drains the
            // backlog with a bounded timeout, so the accumulated text can be
            // missing the head (~1s of speech). This was verified directly: the
            // saved audio is always complete, and a one-shot decode over it
            // reproduces the full transcript (head intact) at any chunk size,
            // while the live streamed-final does not. Re-decoding the complete
            // `samples` here is the authoritative, head-complete result.
            // Streaming stays on purely for the live preview (and the CTC vocab
            // spotter, which is independent of this handoff). We then run the
            // custom-vocabulary spot+gate over the audio — this is the live
            // dictation path for Nemotron, so vocab MUST run here (it was
            // previously only wired into `Transcriber.transcribeWithNemotron`,
            // which this path never calls).
            clearPendingNemotronFinal()
            let started = Date()
            let raw = try await nemotron.transcribeOneShot(samples)
            let processingTime = Date().timeIntervalSince(started)
            return await Self.nemotronResult(
                raw: raw,
                samples: samples,
                processingTime: processingTime,
                recordsProvenance: recordsProvenance
            )
        }
    }

    func transcribeFile(
        _ url: URL,
        recordsProvenance: Bool
    ) async throws -> TranscriptionResult {
        switch finalEngine {
        case .batch(let batch):
            return try await batch.transcribeFile(url, recordsProvenance: recordsProvenance)
        case .nemotron:
            let fallback = Transcriber(modelID: .nemotron_en)
            try await fallback.ensureLoaded()
            return try await fallback.transcribeFile(url, recordsProvenance: recordsProvenance)
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
        case .nemotron(let nemotron):
            await nemotron.start(generation: generation, onPartial: onPartial)
        case .batchPreview(let scheduler):
            await scheduler.begin(generation: generation, onPartial: onPartial)
        }
    }

    func enqueueStreaming(samples: [Float]) {
        switch streamingEngine {
        case .nemotron(let nemotron):
            nemotron.enqueue(samples: samples)
        case .batchPreview(let scheduler):
            scheduler.enqueue(samples: samples)
        }
    }

    func finishStreaming() async -> String? {
        let final: String?
        switch streamingEngine {
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

        // The streamed text is NOT used as the final transcript anymore (the
        // final is a one-shot decode over the full captured audio in
        // `transcribe(_:recordsProvenance:)` — see the head-drop note there).
        // `finish()` is still called to drain + flush the streaming session
        // cleanly; its return value is intentionally discarded.
        return final
    }

    func cancelStreaming() async {
        clearPendingNemotronFinal()
        switch streamingEngine {
        case .nemotron(let nemotron):
            await nemotron.cancel()
        case .batchPreview(let scheduler):
            await scheduler.cancel()
        }
    }

    // MARK: - Nemotron final handoff

    private func clearPendingNemotronFinal() {
        pendingLock.lock()
        pendingNemotronFinal = nil
        pendingLock.unlock()
    }

    /// Build the Nemotron final result, running the custom-vocabulary spot+gate
    /// pass over the audio — the SAME no-fork CTC-spotter path as
    /// `Transcriber.transcribeWithNemotron`. Best-effort: any spotter/gate
    /// failure falls through to the raw Nemotron transcript so vocab can never
    /// regress the user-visible result. Nemotron is English-only.
    private static func nemotronResult(
        raw: String,
        samples: [Float],
        processingTime: TimeInterval,
        recordsProvenance: Bool
    ) async -> TranscriptionResult {
        let duration = TimeInterval(samples.count) / AudioFormat.sampleRate
        let holder = VocabularyRescorerHolder.shared

        var text = raw
        var corrections: [VocabularyRescorerHolder.UXCorrection] = []
        do {
            // Prefer the payload the streaming spotter accumulated DURING
            // recording (no post-stop wait). Falls back to the one-shot spot
            // when streaming didn't run (no vocab, non-recorder path, or a
            // streaming failure) — identical result, just slower.
            let payload: VocabularyRescorerHolder.SpotPayload?
            if let streamed = await holder.takePendingStreamedPayload() {
                payload = streamed
            } else {
                payload = try await holder.spotDetections(audioSamples: samples)
            }
            if let payload {
                let gated = await holder.gateDetections(
                    transcript: raw,
                    payload: payload,
                    language: .english,
                    recordsProvenance: recordsProvenance
                )
                text = gated.text
                corrections = gated.corrections
            }
        } catch {
            await ErrorLog.shared.warn(
                component: "DualPipelineTranscriber",
                message: "Nemotron vocabulary spot/gate failed; using raw transcript",
                context: ["error": ErrorLog.redactedAppleError(error)]
            )
        }

        // v1.13.1: Nemotron emits clean native punctuation + casing.
        return TranscriptionResult(
            text: text,
            rawText: raw,
            duration: duration,
            processingTime: processingTime,
            confidence: 1.0,
            corrections: corrections
        )
    }
}
