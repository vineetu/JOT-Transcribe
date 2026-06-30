@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.log

/// Jot's wrapper around FluidAudio's `AsrManager`.
///
/// Responsibilities:
/// - Load Parakeet from `ModelCache` and keep it hot across calls. FluidAudio
///   takes ~4–6 s to warm the Neural Engine on first inference, so we avoid
///   reloading per-transcription.
/// - Enforce **single in-flight** transcription: overlapping calls throw
///   `.busy`. This matches the plan (`docs/plans/swift-rewrite.md` →
///   Transcription layer).
/// - Apply deterministic cleanup + `PostProcessing` to the decoded text and
///   expose both raw and cleaned strings on `TranscriptionResult`.
///
/// Actor-isolated. Safe to hold one instance for the lifetime of the app.
public actor Transcriber: Transcribing {
    private let log = Logger(subsystem: "com.jot.Jot", category: "Transcriber")

    private let cache: ModelCache
    /// Bound at init and never observed afterward. `TranscriberHolder`
    /// creates a fresh conformer whenever the primary model changes.
    private let modelID: ParakeetModelID

    /// The active transcription language, threaded in at construction by
    /// `TranscriberHolder` (mirroring `modelID`). Drives the FluidAudio
    /// `language:` script hint passed at `transcribe(...)` time. `nil` means
    /// "no hint" (the pre-language-picker behavior) — used by tests and any
    /// caller that constructs a `Transcriber` directly without a language.
    ///
    /// Only the v3 European paths actually exercise the hint; v2 (English) and
    /// JA ignore it (design §2.1, §5.4). For these the resolved hint is `nil`
    /// regardless.
    private let language: LanguageChoice?

    private var manager: AsrManager?
    private var nemotronBatch: NemotronStreamingTranscriber?
    private var isTranscribing: Bool = false

    public init(
        cache: ModelCache = .shared,
        modelID: ParakeetModelID = .tdt_0_6b_v3,
        language: LanguageChoice? = nil
    ) {
        self.cache = cache
        self.modelID = modelID
        self.language = language
    }

    /// Load Parakeet into memory if it isn't already. Idempotent — safe to
    /// call from the UI layer speculatively (e.g. right after the model
    /// download finishes) to front-load the ANE warm-up.
    public func ensureLoaded() async throws {
        switch modelID {
        case .nemotron_en:
            if nemotronBatch != nil { return }

            guard cache.isCached(modelID) else {
                throw TranscriberError.modelMissing
            }
            guard let directory = cache.streamingPartialCacheURL(for: modelID) else {
                throw TranscriberError.modelMissing
            }

            do {
                let transcriber = NemotronStreamingTranscriber(bundleDirectory: directory)
                try await transcriber.ensureLoaded()
                nemotronBatch = transcriber
                log.info("Nemotron loaded")
            } catch {
                await ErrorLog.shared.error(component: "Transcriber", message: "Nemotron load failed", context: ["modelID": modelID.rawValue, "error": ErrorLog.redactedAppleError(error)])
                throw TranscriberError.fluidAudio(error)
            }
            return

        case .qwen3_multilingual, .nemotron_multilingual, .nemotron_multilingual_latin:
            // Neither is an `AsrManager` model; both load through a dedicated
            // streaming transcriber built by `JotComposition.transcriberFactory`
            // (DualPipelineTranscriber), never this wrapper. Reaching here is a
            // routing bug.
            throw TranscriberError.modelMissing

        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            break
        }

        if manager != nil { return }

        let directory = cache.cacheURL(for: modelID)
        guard cache.isCached(modelID) else {
            throw TranscriberError.modelMissing
        }

        do {
            let models = try await AsrModels.load(
                from: directory,
                version: modelID.fluidAudioVersion,
                encoderPrecision: modelID.encoderPrecision
            )
            let manager = AsrManager()
            try await manager.loadModels(models)
            self.manager = manager
            log.info("Parakeet loaded")
        } catch let error as TranscriberError {
            await ErrorLog.shared.error(component: "Transcriber", message: "Parakeet load failed", context: ["modelID": modelID.rawValue, "error": ErrorLog.redactedAppleError(error)])
            throw error
        } catch {
            await ErrorLog.shared.error(component: "Transcriber", message: "Parakeet load failed", context: ["modelID": modelID.rawValue, "error": ErrorLog.redactedAppleError(error)])
            throw TranscriberError.fluidAudio(error)
        }
    }

    /// Drop the in-memory model. No-op if nothing is loaded. Phase 2 doesn't
    /// wire this to any policy — Phase 4 will decide when to evict (e.g. on
    /// long idle periods to free ANE memory).
    public func unload() {
        manager = nil
        nemotronBatch = nil
    }

    /// Transcribe a 16 kHz mono Float32 buffer (the exact shape
    /// `AudioCapture` produces). Throws `.busy` if a previous call is still
    /// running — by policy, we refuse to queue.
    ///
    /// FluidAudio itself requires `samples.count >= sampleRate` (≥ 1 second
    /// of audio) — shorter buffers are rejected with `.audioTooShort` rather
    /// than forwarded, since the SDK error for that case is less specific.
    ///
    /// - Parameter recordsProvenance: when `true`, this call owns the shared
    ///   `CorrectionProvenance` pending slot — it clears it on entry and the
    ///   gate records fresh proposals into it for a later `commit(transcriptID:)`.
    ///   Only the saving paths (recorder-owned dictation and the Library
    ///   re-transcribe) pass `true`. Non-saving voice callers (Ask Jot, Rewrite)
    ///   pass `false` (the default): they run during a real dictation's async
    ///   transform window, so touching the shared slot would wipe or mis-attribute
    ///   that dictation's pending proposals. When `false` the gate still runs and
    ///   returns gated text — it just must not touch the provenance actor.
    public func transcribe(
        _ samples: [Float],
        recordsProvenance: Bool = false
    ) async throws -> TranscriptionResult {
        guard !isTranscribing else { throw TranscriberError.busy }
        guard samples.count >= Int(AudioFormat.sampleRate) else {
            throw TranscriberError.audioTooShort
        }

        // Slice C linkage: clear any stale gate proposals before every
        // PROVENANCE-OWNING transcription. The gate fills
        // `CorrectionProvenance.pending` at rescore time, but only the saving
        // path (`RecordingPersister` / re-transcribe) ever calls `commit`.
        // Non-saving voice callers (Ask Jot, Rewrite) run `transcribe(...)`
        // too — and they fire DURING a real dictation's multi-second async
        // transform window (the pipeline is already `.idle` before that
        // dictation's `commit` lands). If those callers cleared/recorded here,
        // they'd wipe the dictation's pending proposals or write their own
        // under its id. Gating both side-effects on `recordsProvenance` keeps
        // the shared slot owned exclusively by the saving path.
        if recordsProvenance {
            await CorrectionProvenance.shared.clearPending()
        }

        isTranscribing = true
        defer { isTranscribing = false }

        switch modelID {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            guard let manager else { throw TranscriberError.modelNotLoaded }
            return try await transcribeWithAsrManager(
                samples,
                manager: manager,
                recordsProvenance: recordsProvenance
            )

        case .nemotron_en:
            guard let nemotronBatch else { throw TranscriberError.modelNotLoaded }
            return try await transcribeWithNemotron(
                samples,
                nemotronBatch: nemotronBatch,
                recordsProvenance: recordsProvenance
            )

        case .qwen3_multilingual, .nemotron_multilingual, .nemotron_multilingual_latin:
            // Never reached: both route through their own streaming
            // transcriber, not this `AsrManager` wrapper.
            throw TranscriberError.modelNotLoaded
        }
    }

    private func transcribeWithAsrManager(
        _ samples: [Float],
        manager: AsrManager,
        recordsProvenance: Bool
    ) async throws -> TranscriptionResult {
        let result: ASRResult
        do {
            // FluidAudio 0.13.7+ exposes the TDT decoder state explicitly
            // instead of hiding it behind a `source: .microphone` enum
            // (#502). Each utterance Jot transcribes is independent —
            // there's no streaming chunk continuity to preserve — so we
            // hand the manager a fresh decoder state per call. The number
            // of LSTM layers is version-specific (1 for `tdtCtc110m`, 2
            // for v2/v3/tdtJa) and `AsrModelVersion.decoderLayers` is the
            // SDK's source of truth.
            //
            // Language hint (design §5.4): we now pass the active language's
            // FluidAudio script hint. It is the v3-only Latin/Cyrillic token
            // filter — only the v3 European paths exercise it; v2 (English)
            // and tdtJa ignore it (their resolved hint is `nil` anyway).
            var decoderState = TdtDecoderState.make(
                decoderLayers: modelID.fluidAudioVersion.decoderLayers
            )
            result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: language?.fluidAudioLanguage
            )
        } catch {
            await ErrorLog.shared.error(component: "Transcriber", message: "FluidAudio transcribe failed", context: ["sampleCount": String(samples.count), "error": ErrorLog.redactedAppleError(error)])
            throw TranscriberError.fluidAudio(error)
        }

        // Vocabulary boosting pass — best-effort. Any failure falls
        // through to the raw TDT transcript so a broken rescorer can
        // never regress the user-visible result.
        //
        // Two paths today:
        // - Japanese primary: alias-based substitution at the text
        //   layer. FluidAudio doesn't expose a `CtcJaKeywordSpotter` or
        //   token timings from `TdtJaManager.transcribe`, so the
        //   English-style acoustic CTC rescoring isn't reproducible on
        //   JA without an upstream change. See
        //   `JapaneseVocabularySubstituter` for the trade.
        // - Everything else (v3+EOU, v3+Nemotron legacy, v2+EOU,
        //   Nemotron-only): acoustic CTC rescoring via FluidAudio.
        //   Requires token timings from the primary; the rescorer
        //   holder itself declines when the bundle isn't loaded
        //   (e.g. Nemotron-only).
        var transcriptText = result.text
        // Slice D: the de-duped gate corrections for this pass. Threaded onto the
        // returned `TranscriptionResult` so the delivery bridge can decide whether
        // to hold the paste and ask. Empty unless the English-style CTC rescore
        // path below actually produced corrections.
        var corrections: [VocabularyRescorerHolder.UXCorrection] = []
        if modelID == .tdt_0_6b_ja {
            // Slice D (piece 8): Japanese vocab substitution is OFF. JA dictation
            // gets NO vocab substitution — the alias-based `JapaneseVocabularySubstituter`
            // path is disabled here (JA transcription itself is unchanged; only the
            // post-hoc vocab rewrite is removed). The acoustic CTC gate does not run
            // on JA (no token timings / CTC JA spotter from FluidAudio), so there are
            // no ask candidates on this path either.
            //
            // Previously this branch ran `JapaneseVocabularySubstituter.substitute(...)`
            // when the vocabulary master toggle was on; that substitution is now
            // intentionally skipped for Japanese. (No-op branch retained so the
            // model-specific routing stays explicit.)
            _ = transcriptText  // JA: pass the raw TDT text straight through.
        } else if let timings = result.tokenTimings {
            do {
                if let rescored = try await VocabularyRescorerHolder.shared.rescore(
                    transcript: result.text,
                    tokenTimings: timings,
                    audioSamples: samples,
                    language: language,
                    recordsProvenance: recordsProvenance
                ) {
                    // Slice A: the gate returns the GATED text plus the de-duped
                    // applied-correction set (`rescored.corrections`) for the
                    // future pill/review UX. The UX wiring (feedback-ux.md) is a
                    // later slice — for now we keep the gated text and don't drop
                    // the correction set (it rides the gate's CorrectionProvenance
                    // record; the in-band UX channel lands with the pill work).
                    transcriptText = rescored.text
                    // Slice D: carry the de-duped corrections out so the delivery
                    // bridge can hold the paste and ask for `askCandidate` ones.
                    corrections = rescored.corrections
                }
            } catch {
                log.error("vocabulary rescore failed — falling back to raw: \(error.localizedDescription)")
                await ErrorLog.shared.warn(component: "Transcriber", message: "Vocabulary rescore failed, fell back to raw", context: ["error": ErrorLog.redactedAppleError(error)])
            }
        }

        // Paragraph segmentation (deterministic, pause-based — jot-mobile parity)
        // runs for ANY model that returns per-word token timings: Parakeet v2 AND
        // v3. v3 emits well-cased, punctuated text but NOT paragraph breaks, so
        // without this its transcripts were one undifferentiated block. The
        // segmenter only inserts `\n\n` (1.4s pause after sentence-final
        // punctuation, with safety caps + timing verification) — it never
        // rewrites words, so it's safe to run on v3's already-clean text.
        // Nemotron / Qwen3 emit plain text with NO timings, so `tokenTimings` is
        // nil and they remain a single block (deterministic-only by design).
        //
        // The v2-ONLY regex cleanup chain (FillerWordCleaner → NumberNormalizer →
        // PostProcessing) stays scoped to v2: v3 already emits well-cased,
        // filler-trimmed text and the regex pass would double-edit / regress its
        // casing.
        var segmented = transcriptText
        if let timings = result.tokenTimings {
            segmented = ParagraphSegmenter.segment(
                rescoredText: segmented,
                tokenTimings: timings
            )
        }
        let cleaned: String
        if modelID == .tdt_0_6b_v2_en_streaming {
            let dedupped = FillerWordCleaner.clean(segmented)
            let normalized = NumberNormalizer.normalize(dedupped)
            cleaned = PostProcessing.apply(normalized, language: modelID)
        } else {
            cleaned = segmented
        }
        return TranscriptionResult(
            text: cleaned,
            rawText: result.text,
            duration: result.duration,
            processingTime: result.processingTime,
            confidence: result.confidence,
            corrections: corrections
        )
    }

    /// Lean preview decode for the live pill (batch pseudo-streaming —
    /// `docs/batch-pseudo-streaming/design.md` §4.3). Mirrors
    /// `transcribeWithAsrManager` MINUS the parts a re-runnable preview tick must
    /// not pay for or must not mutate:
    ///   - **No `isTranscribing` busy-throw.** Ticks are coalesced single-flight
    ///     by `PreviewScheduler`, and the scheduler's `quiesce()` stop fence
    ///     guarantees no preview tick overlaps the final pass (design §4.3.1), so
    ///     the lean path neither sets nor checks the busy flag. The *final*
    ///     `transcribe(_:)` still honors it.
    ///   - **No vocabulary rescore** and **no provenance/diagnostics** side
    ///     effects (vocab corrects only on the final stop pass).
    ///   - **Returns `nil` instead of throwing** — for < 1 s of audio, an
    ///     unloaded/Nemotron model, or any decode error. It must never throw into
    ///     the scheduler.
    ///
    /// Decoder config is identical to `transcribe(_:)`: a **fresh
    /// `TdtDecoderState` per call** (no carried state — design §2.5), sized by
    /// `modelID.fluidAudioVersion.decoderLayers`, so preview decodes against
    /// whichever batch model is loaded (the v2/v3 blank-id difference is
    /// encapsulated in the version). The per-call language hint is threaded
    /// through here exactly as it is through the final path — it reads the
    /// actor's active `language` (set at construction by `TranscriberHolder`)
    /// rather than taking a parameter, so `PreviewScheduler`'s single-arg call
    /// site is unchanged.
    func previewTranscribe(_ samples: [Float]) async -> String? {
        guard samples.count >= Int(AudioFormat.sampleRate) else { return nil }

        switch modelID {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            guard let manager else { return nil }
            return await previewWithAsrManager(samples, manager: manager)

        case .nemotron_en:
            // Nemotron has its own streaming preview; it is not driven by the
            // batch PreviewScheduler.
            return nil

        case .qwen3_multilingual, .nemotron_multilingual, .nemotron_multilingual_latin:
            // Qwen3 has no live preview; Nemotron multilingual drives its own
            // streaming preview. Neither routes through this wrapper.
            return nil
        }
    }

    private func previewWithAsrManager(
        _ samples: [Float],
        manager: AsrManager
    ) async -> String? {
        let result: ASRResult
        do {
            // Decoder config reads the ACTIVE model's version (design §5.4 —
            // v2 blankId 1024 vs v3 blankId 8192), so the preview decodes
            // against whichever batch model is loaded. The language hint is
            // threaded identically to the final path; only v3 European paths
            // exercise it.
            var decoderState = TdtDecoderState.make(
                decoderLayers: modelID.fluidAudioVersion.decoderLayers
            )
            result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: language?.fluidAudioLanguage
            )
        } catch {
            // Never throw into the scheduler — a failed tick just produces no
            // preview text; the saved transcript is unaffected.
            return nil
        }

        // v2-gated post-processing only, matching the final path (`:220-235`).
        // NO vocabulary rescore. v3+/JA/Nemotron emit well-cased, filler-trimmed
        // text natively, so they pass through.
        if modelID == .tdt_0_6b_v2_en_streaming {
            let segmented: String
            if let timings = result.tokenTimings {
                segmented = ParagraphSegmenter.segment(
                    rescoredText: result.text,
                    tokenTimings: timings
                )
            } else {
                segmented = result.text
            }
            let dedupped = FillerWordCleaner.clean(segmented)
            let normalized = NumberNormalizer.normalize(dedupped)
            return PostProcessing.apply(normalized, language: modelID)
        } else {
            return result.text
        }
    }

    private func transcribeWithNemotron(
        _ samples: [Float],
        nemotronBatch: NemotronStreamingTranscriber,
        recordsProvenance: Bool
    ) async throws -> TranscriptionResult {
        let started = Date()

        // No-fork custom-vocabulary for Nemotron. Nemotron's stream returns a
        // plain String — NO per-word timings, NO confidence — so the timing-
        // dependent CTC rescorer (`ctcTokenRescore`) is INERT here. Instead we
        // run the CTC keyword SPOTTER on the AUDIO: it acoustically detects each
        // vocab term + its audio time range WITHOUT needing transcript timings.
        // We then place the detections onto the decoded transcript via the gate's
        // own plausibility metric + proportional position, and apply the SAME
        // `VocabularyGate`. See `VocabularyRescorerHolder.spotDetections` /
        // `gateDetections`.
        //
        // CONCURRENCY: the spotter (Mel + Encoder + CtcHead on the ANE) depends
        // ONLY on `audioSamples`, so phase 1 runs CONCURRENTLY with the Nemotron
        // decode via `async let` — wall-clock ≈ max(decode, spot), not their sum.
        // The audio buffer is an immutable Sendable `[Float]` shared read-only
        // across both tasks → no data race. Placement (phase 2) needs the decoded
        // transcript, so it runs after the decode lands.
        //
        // VOCAB-OFF: `spotDetections` returns `nil` WITHOUT running the spotter
        // when the rescorer isn't ready (toggle off / empty vocab / models not
        // downloaded), so the common path burns no extra ANE and stays a pure,
        // byte-identical pass-through. Best-effort: ANY vocab error falls back to
        // the raw transcript and never blocks dictation. The decode runs EXACTLY
        // ONCE on every path.
        let holder = VocabularyRescorerHolder.shared
        let samplesRef = samples

        // Phase 1: spotter (transcript-independent). Best-effort — a spotter
        // failure must never block dictation, so it resolves to `nil`.
        async let spotPayloadTask: VocabularyRescorerHolder.SpotPayload? = {
            do { return try await holder.spotDetections(audioSamples: samplesRef) }
            catch { return nil }
        }()

        // Decode (source of truth for fallback). Runs side-by-side with phase 1.
        let raw: String
        do {
            raw = try await nemotronBatch.transcribeOneShot(samples)
        } catch {
            // Surface the placeholder task so its result is awaited (the spotter
            // is cancellation-tolerant; we ignore its result on the error path).
            _ = await spotPayloadTask
            await ErrorLog.shared.error(component: "Transcriber", message: "Nemotron transcribe failed", context: ["sampleCount": String(samples.count), "error": ErrorLog.redactedAppleError(error)])
            throw TranscriberError.fluidAudio(error)
        }

        // Phase 2: placement + gate (only when phase 1 actually spotted).
        var text = raw
        var corrections: [VocabularyRescorerHolder.UXCorrection] = []
        if let payload = await spotPayloadTask {
            let gated = await holder.gateDetections(
                transcript: raw,
                payload: payload,
                language: language,
                recordsProvenance: recordsProvenance
            )
            text = gated.text
            corrections = gated.corrections
        }

        // v1.13.1: Nemotron emits clean native punctuation + casing.
        return TranscriptionResult(
            text: text,
            rawText: raw,
            duration: TimeInterval(samples.count) / AudioFormat.sampleRate,
            processingTime: Date().timeIntervalSince(started),
            confidence: 1.0,
            corrections: corrections
        )
    }

    /// True while a `transcribe(_:)` call is in flight. Exposed so the
    /// recorder can surface "transcribing" state without racing the actor.
    public var busy: Bool { isTranscribing }

    /// True once Parakeet is loaded on the ANE and ready to infer.
    /// Callers (RecorderController) check this before awaiting transcribe so
    /// that a hung first-time `AsrModels.load` (see Apple Developer Forum
    /// thread 770529 on the iOS 26.4 espresso/BNNS load-path hang) can't park
    /// the recorder in `.transcribing` forever. Pre-warm at launch
    /// (`AppDelegate.applicationDidFinishLaunching`) is what keeps this true
    /// during steady-state; a hotkey pressed before pre-warm finishes falls
    /// through to a fast user-visible "model still loading" error.
    public var isReady: Bool {
        switch modelID {
        case .nemotron_en:
            return nemotronBatch != nil
        case .qwen3_multilingual, .nemotron_multilingual, .nemotron_multilingual_latin:
            // Neither loads through this wrapper.
            return false
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming,
             .tdt_0_6b_v3_eou_streaming:
            return manager != nil
        }
    }

    /// Decode a WAV file at `url` (assumed already in the canonical
    /// 16 kHz mono Float32 format Jot's `AudioCapture` writes) and run it
    /// through the same `transcribe(_:)` path as a live capture. Used by
    /// the Library's "Re-transcribe" action so existing rows can be rerun
    /// without the mic.
    ///
    /// If the file's PCM format ever drifts from target (e.g. imported from
    /// elsewhere), we resample on the fly via `AVAudioConverter`.
    ///
    /// - Parameter recordsProvenance: forwarded to `transcribe(_:recordsProvenance:)`.
    ///   The Library detail re-transcribe passes `true` (it commits the fresh
    ///   gate proposals under the same recording id); the list-row re-transcribe
    ///   passes `false` (it only rewrites the transcript text, never commits).
    public func transcribeFile(
        _ url: URL,
        recordsProvenance: Bool = false
    ) async throws -> TranscriptionResult {
        try await ensureLoaded()

        let file = try AVAudioFile(forReading: url)
        let samples = try Self.readMono16kFloat(file: file)
        return try await transcribe(samples, recordsProvenance: recordsProvenance)
    }

    /// Read `file` into `[Float]` at `AudioFormat.target`. Fast path when the
    /// file already matches target format (which WAVs written by
    /// `AudioCapture` always do); otherwise runs a one-shot converter.
    private static func readMono16kFloat(file: AVAudioFile) throws -> [Float] {
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        let processingFormat = file.processingFormat

        if processingFormat.sampleRate == AudioFormat.sampleRate,
           processingFormat.channelCount == AudioFormat.channelCount,
           processingFormat.commonFormat == .pcmFormatFloat32,
           !processingFormat.isInterleaved {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: frameCount
            ) else {
                throw TranscriberError.fluidAudio(
                    NSError(domain: "Jot.Transcriber", code: -1)
                )
            }
            try file.read(into: buffer)
            return Self.floats(from: buffer)
        }

        // Slow path: convert into target format in one shot.
        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Transcriber", code: -2)
            )
        }
        try file.read(into: inBuffer)

        guard let converter = AVAudioConverter(
            from: processingFormat,
            to: AudioFormat.target
        ) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Transcriber", code: -3)
            )
        }

        let ratio = AudioFormat.sampleRate / processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: AudioFormat.target,
            frameCapacity: outCapacity
        ) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Transcriber", code: -4)
            )
        }

        var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inBuffer
        }

        switch status {
        case .error:
            if let convertError { throw TranscriberError.fluidAudio(convertError) }
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Transcriber", code: -5)
            )
        default:
            break
        }

        return Self.floats(from: outBuffer)
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }
}
