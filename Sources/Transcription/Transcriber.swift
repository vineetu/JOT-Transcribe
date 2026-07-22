@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import JotTextPipeline
import JotVocabCore
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

        case .nemotron_multilingual, .nemotron_multilingual_latin:
            // Not an `AsrManager` model; loads through a dedicated streaming
            // transcriber built by `JotComposition.transcriberFactory`
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
        try await transcribe(samples, recordsProvenance: recordsProvenance, progress: nil)
    }

    /// Progress-aware entry point (docs/transcription-progress/design.md).
    /// Deliberately a SEPARATE overload from `transcribe(_:recordsProvenance:)`
    /// above rather than a third defaulted parameter on it: `Transcribing`
    /// requires the exact 2-parameter signature, and Swift protocol-witness
    /// matching does NOT use default argument values to bridge an arity
    /// mismatch — a 3-parameter method (even with the 3rd defaulted) does
    /// NOT satisfy a 2-parameter protocol requirement. Keeping the original
    /// 2-param method (which just forwards `progress: nil`) preserves
    /// `Transcriber: Transcribing` conformance; this overload is the one
    /// `FileTranscriptionIngest` reaches via an `as? Transcriber` downcast
    /// (see that file) since `any Transcribing`-typed callers can't see it.
    ///
    /// - Parameter progress: fraction-complete callback (0...1). Only fired
    ///   on the Parakeet (`AsrManager`) path, and only for audio long enough
    ///   that FluidAudio actually emits a stream (`ASRConstants.maxModelSamples`,
    ///   ~15s) — see `transcribeWithAsrManager`. The Nemotron path never
    ///   calls this closure (`transcribeWithNemotron` doesn't accept it).
    ///   Passing `nil` here is identical to calling the 2-param overload.
    func transcribe(
        _ samples: [Float],
        recordsProvenance: Bool,
        progress: (@Sendable (Double) -> Void)?
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

        // Design D6: serialize against the offline diarizer so the two CoreML
        // graphs never run concurrently (FluidAudio #661). Acquired before `isTranscribing`
        // flips so a diarize call already holding the gate is waited out
        // rather than racing this transcription's own busy-flag.
        await CoreMLInferenceGate.shared.acquire()

        isTranscribing = true
        defer {
            isTranscribing = false
            Task { await CoreMLInferenceGate.shared.release() }
        }

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
                recordsProvenance: recordsProvenance,
                progress: progress
            )

        case .nemotron_en:
            guard let nemotronBatch else { throw TranscriberError.modelNotLoaded }
            // `progress` is intentionally NOT forwarded here — Nemotron never
            // exposes a progress stream (design §1), so the UI falls back to
            // the indeterminate + elapsed-time treatment for this path.
            return try await transcribeWithNemotron(
                samples,
                nemotronBatch: nemotronBatch,
                recordsProvenance: recordsProvenance
            )

        case .nemotron_multilingual, .nemotron_multilingual_latin:
            // Never reached: routes through its own streaming transcriber, not
            // this `AsrManager` wrapper.
            throw TranscriberError.modelNotLoaded
        }
    }

    private func transcribeWithAsrManager(
        _ samples: [Float],
        manager: AsrManager,
        recordsProvenance: Bool,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let result: ASRResult

        // File-transcription progress (docs/transcription-progress/design.md
        // §3.1). `AsrManager.transcriptionProgressStream` is a shared,
        // one-session-at-a-time actor resource (FluidAudio's
        // `ProgressEmitter`): reading it calls `ensureSession()`, and if
        // nothing ever calls `finishSession()`/`failSession()` afterward
        // (which is exactly what happens for audio ≤ `maxModelSamples` —
        // `AsrManager.transcribe`'s own `shouldEmitProgress` guard skips both),
        // that session's stream is left open forever and the NEXT caller's
        // `ensureSession()` would hand back the same stale, already-consumed
        // stream instead of a fresh one. So we only ever touch the stream
        // when we already know this call will cross that threshold — the
        // same gate FluidAudio itself uses internally — which both matches
        // the design ("emitted automatically for audio > 15s") and avoids
        // ever creating a session that risks going unfinished.
        var progressTask: Task<Void, Never>?
        defer { progressTask?.cancel() }
        if let progress, samples.count > ASRConstants.maxModelSamples {
            let stream = await manager.transcriptionProgressStream
            progressTask = Task {
                do {
                    for try await fraction in stream {
                        if Task.isCancelled { break }
                        progress(fraction)
                    }
                } catch {
                    // Stream failed (e.g. `failSession` on a decode error) or
                    // was cancelled — no percentage left to report; the
                    // caller's own do/catch around `manager.transcribe` below
                    // is what actually surfaces the failure.
                }
            }
        }

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
        // Nemotron emits plain text with NO timings, so `tokenTimings` is nil
        // and it remains a single block (deterministic-only by design).
        //
        // The deterministic cleanup chain now runs for EVERY model, in one code
        // path (owner directive, v1.18.x) — with per-language gating in
        // `applyLanguageCleanup`: the full English chain (FillerWordCleaner +
        // NumberNormalizer) for English, filler-cleaning ONLY for es/fr/de/it/pt
        // (per-language hesitation lists in the shared pipeline), nothing for
        // the rest. NumberNormalizer stays English-only — its rules are
        // English-hardcoded and would mis-convert other languages.
        // ParagraphSegmenter is pause-based and language-agnostic (runs
        // wherever token timings exist), and PostProcessing keeps its own
        // per-script routing (JA/CJK passthrough) internally.
        var segmented = transcriptText
        if let timings = result.tokenTimings {
            // Bridge FluidAudio word timings into the engine-neutral
            // TokenTiming the shared text pipeline consumes ($0 infers as
            // FluidAudio's type; the package type is module-qualified).
            segmented = ParagraphSegmenter.segment(
                rescoredText: segmented,
                tokenTimings: timings.map {
                    JotTextPipeline.TokenTiming(
                        token: $0.token, startTime: $0.startTime, endTime: $0.endTime
                    )
                }
            )
        }
        let cleaned = PostProcessing.apply(applyLanguageCleanup(segmented), language: modelID)
        return TranscriptionResult(
            text: cleaned,
            rawText: result.text,
            duration: result.duration,
            processingTime: result.processingTime,
            confidence: result.confidence,
            corrections: corrections,
            tokenTimings: result.tokenTimings
        )
    }

    /// Language-gated cleanup for the word-driven stages of the chain
    /// (fillers + spelled-out numbers).
    ///
    /// - English (or `nil` language): `FillerWordCleaner` + `NumberNormalizer`,
    ///   unchanged. A `nil` active language means the English v2/Nemotron
    ///   fallback (`fluidAudioLanguage == nil` for English), so it counts as
    ///   English.
    /// - es/fr/de/it/pt: `FillerWordCleaner.clean(_:language:)` ONLY — the
    ///   shared pipeline's per-language lists are non-lexical hesitation sounds
    ///   (jot-shared docs/multilingual-itn-options.md §5), so stripping them is
    ///   safe outside English. `NumberNormalizer` stays STRICTLY English: its
    ///   spelled-cardinal rules would mis-convert Romance output (e.g. French
    ///   "six cents" = 600 → "6¢").
    /// - Japanese + every other language: untouched (no filler lists exist).
    private func applyLanguageCleanup(_ text: String) -> String {
        guard modelID != .tdt_0_6b_ja else { return text }
        let fillerCode: String?
        if let language {
            fillerCode = language.fillerLanguageCode
        } else {
            fillerCode = "en" // nil = English v2/Nemotron fallback
        }
        guard let fillerCode else { return text }
        if fillerCode == "en" {
            return NumberNormalizer.normalize(FillerWordCleaner.clean(text))
        }
        return FillerWordCleaner.clean(text, language: fillerCode)
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

        case .nemotron_multilingual, .nemotron_multilingual_latin:
            // Nemotron multilingual drives its own streaming preview; it does
            // not route through this wrapper.
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

        // Same cleanup chain as the final path (one code path for every model;
        // language-gated filler/number stages), so the live preview matches the
        // delivered transcript. NO vocabulary rescore (vocab only runs on the
        // final stop pass).
        var segmented = result.text
        if let timings = result.tokenTimings {
            segmented = ParagraphSegmenter.segment(
                rescoredText: segmented,
                tokenTimings: timings.map {
                    JotTextPipeline.TokenTiming(
                        token: $0.token, startTime: $0.startTime, endTime: $0.endTime
                    )
                }
            )
        }
        return PostProcessing.apply(applyLanguageCleanup(segmented), language: modelID)
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

        // Scrub tokenizer `<unk>` artifacts FIRST so the number/filler stages
        // see clean text (the multilingual tokenizer has no %/€/$ tokens —
        // `PostProcessing.scrubModelArtifacts`). Then the same cleanup chain as
        // every other model, language-gated in `applyLanguageCleanup` (full
        // English chain for English; filler-cleaning only for es/fr/de/it/pt).
        // Nemotron emits clean native punctuation + casing but leaves spoken
        // numbers spelled out; FillerWordCleaner (abbreviation-aware recap,
        // safe on cased text) + NumberNormalizer handle fillers/numbers for
        // English, and PostProcessing does the final whitespace pass. No token
        // timings on this path, so paragraph segmentation is not possible here.
        let scrubbed = PostProcessing.scrubModelArtifacts(text)
        let normalized = PostProcessing.apply(applyLanguageCleanup(scrubbed), language: modelID)
        return TranscriptionResult(
            text: normalized,
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
        case .nemotron_multilingual, .nemotron_multilingual_latin:
            // Does not load through this wrapper.
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
        try await transcribeFile(url, recordsProvenance: recordsProvenance, progress: nil)
    }

    /// Progress-aware entry point — same rationale as the
    /// `transcribe(_:recordsProvenance:progress:)` overload above (a
    /// separate overload, not a 3rd defaulted parameter on the protocol-
    /// conforming method, to preserve `Transcriber: Transcribing`
    /// conformance's exact 2-parameter arity match). `FileTranscriptionIngest`
    /// reaches this via an `as? Transcriber` downcast.
    ///
    /// - Parameter progress: forwarded to
    ///   `transcribe(_:recordsProvenance:progress:)` unchanged.
    func transcribeFile(
        _ url: URL,
        recordsProvenance: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptionResult {
        try await ensureLoaded()

        let file = try AVAudioFile(forReading: url)
        let samples = try Self.readMono16kFloat(file: file)
        return try await transcribe(samples, recordsProvenance: recordsProvenance, progress: progress)
    }

    /// Read `file` into `[Float]` at `AudioFormat.target`. Fast path when the
    /// file already matches target format (which WAVs written by
    /// `AudioCapture` always do); otherwise runs a one-shot converter.
    ///
    /// Internal (not `private`) so `DualPipelineTranscriber.transcribeFile`'s
    /// multilingual-Nemotron branch can decode an imported file into the same
    /// canonical buffer without duplicating the converter logic.
    static func readMono16kFloat(file: AVAudioFile) throws -> [Float] {
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
