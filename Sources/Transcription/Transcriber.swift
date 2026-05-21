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

    private var manager: AsrManager?
    private var nemotronBatch: NemotronStreamingTranscriber?
    private var isTranscribing: Bool = false

    public init(cache: ModelCache = .shared, modelID: ParakeetModelID = .tdt_0_6b_v3) {
        self.cache = cache
        self.modelID = modelID
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

        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming:
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
    public func transcribe(_ samples: [Float]) async throws -> TranscriptionResult {
        guard !isTranscribing else { throw TranscriberError.busy }
        guard samples.count >= Int(AudioFormat.sampleRate) else {
            throw TranscriberError.audioTooShort
        }

        isTranscribing = true
        defer { isTranscribing = false }

        switch modelID {
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming:
            guard let manager else { throw TranscriberError.modelNotLoaded }
            return try await transcribeWithAsrManager(samples, manager: manager)

        case .nemotron_en:
            guard let nemotronBatch else { throw TranscriberError.modelNotLoaded }
            return try await transcribeWithNemotron(samples, nemotronBatch: nemotronBatch)
        }
    }

    private func transcribeWithAsrManager(
        _ samples: [Float],
        manager: AsrManager
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
            // SDK's source of truth. Language hint is intentionally
            // unused: it's silently ignored for tdtJa (Japanese is always
            // kept) and Jot doesn't surface a per-call language switch
            // for v3 either.
            var decoderState = TdtDecoderState.make(
                decoderLayers: modelID.fluidAudioVersion.decoderLayers
            )
            result = try await manager.transcribe(samples, decoderState: &decoderState)
        } catch {
            await ErrorLog.shared.error(component: "Transcriber", message: "FluidAudio transcribe failed", context: ["sampleCount": String(samples.count), "error": ErrorLog.redactedAppleError(error)])
            throw TranscriberError.fluidAudio(error)
        }

        // Vocabulary boosting pass — best-effort. Any failure (rescorer
        // not ready, CTC bundle missing, model throws) falls through to
        // the raw TDT transcript so a broken rescorer can never regress
        // the user-visible result. tokenTimings is required by the
        // rescorer's public API; if FluidAudio ever returns nil here
        // the rescorer is skipped.
        var transcriptText = result.text
        if let timings = result.tokenTimings {
            do {
                if let rescored = try await VocabularyRescorerHolder.shared.rescore(
                    transcript: result.text,
                    tokenTimings: timings,
                    audioSamples: samples
                ) {
                    transcriptText = rescored
                }
            } catch {
                log.error("vocabulary rescore failed — falling back to raw: \(error.localizedDescription)")
                await ErrorLog.shared.warn(component: "Transcriber", message: "Vocabulary rescore failed, fell back to raw", context: ["error": ErrorLog.redactedAppleError(error)])
            }
        }

        // Post-transcription cleanup chain (ParagraphSegmenter →
        // FillerWordCleaner → NumberNormalizer) is gated to Parakeet v2
        // only. v3 and newer models (v3 default, v3 int4, v3+Nemotron,
        // Japanese, Nemotron-only) already produce well-cased,
        // filler-trimmed, paragraph-aware transcripts natively from
        // their RNN-T/TDT heads — running the regex chain on top
        // double-edits and occasionally regresses correct casing.
        // v2 still benefits because its training is older and emits
        // rawer text.
        let processedText: String
        if modelID == .tdt_0_6b_v2_en_streaming {
            let segmented: String
            if let timings = result.tokenTimings {
                segmented = ParagraphSegmenter.segment(
                    rescoredText: transcriptText,
                    tokenTimings: timings
                )
            } else {
                segmented = transcriptText
            }
            let dedupped = FillerWordCleaner.clean(segmented)
            processedText = NumberNormalizer.normalize(dedupped)
        } else {
            processedText = transcriptText
        }
        let cleaned = PostProcessing.apply(processedText, language: modelID)
        return TranscriptionResult(
            text: cleaned,
            rawText: result.text,
            duration: result.duration,
            processingTime: result.processingTime,
            confidence: result.confidence
        )
    }

    private func transcribeWithNemotron(
        _ samples: [Float],
        nemotronBatch: NemotronStreamingTranscriber
    ) async throws -> TranscriptionResult {
        let started = Date()
        let raw: String
        do {
            raw = try await nemotronBatch.transcribeOneShot(samples)
        } catch {
            await ErrorLog.shared.error(component: "Transcriber", message: "Nemotron transcribe failed", context: ["sampleCount": String(samples.count), "error": ErrorLog.redactedAppleError(error)])
            throw TranscriberError.fluidAudio(error)
        }

        // Nemotron emits native punctuation + capitalization and is
        // trained on cleaner text — the regex cleanup chain (filler
        // strip + number normalization) is redundant here and can hurt
        // proper casing. Only PostProcessing's language-specific rules
        // run.
        let cleaned = PostProcessing.apply(raw, language: modelID)
        return TranscriptionResult(
            text: cleaned,
            rawText: raw,
            duration: TimeInterval(samples.count) / AudioFormat.sampleRate,
            processingTime: Date().timeIntervalSince(started),
            confidence: 1.0
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
        case .tdt_0_6b_v3,
             .tdt_0_6b_v3_int4,
             .tdt_0_6b_ja,
             .tdt_0_6b_v2_en_streaming,
             .tdt_0_6b_v3_nemotron_streaming:
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
    public func transcribeFile(_ url: URL) async throws -> TranscriptionResult {
        try await ensureLoaded()

        let file = try AVAudioFile(forReading: url)
        let samples = try Self.readMono16kFloat(file: file)
        return try await transcribe(samples)
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
