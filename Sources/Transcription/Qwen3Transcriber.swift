@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import os.log

/// Jot's wrapper around FluidAudio's `Qwen3AsrManager` (Qwen3-ASR 0.6B int8),
/// the engine behind the three experimental languages Parakeet can't do:
/// Mandarin (`zh`), Cantonese (`yue`), and Vietnamese (`vi`).
///
/// This is a SIBLING `Transcribing` conformer to `Transcriber` — selected
/// ONLY when the active model is `.qwen3_multilingual` (i.e. the user picked
/// one of the three new languages). It does NOT touch the existing
/// English/Japanese/Parakeet-v3/Nemotron paths.
///
/// Design notes:
/// - **Single in-flight** like `Transcriber`: overlapping calls throw `.busy`.
/// - **No live preview.** Qwen3 is autoregressive/batch; there is no
///   `PreviewScheduler` integration initially (treated like JA/Nemotron at the
///   factory level — but unlike those, this engine doesn't even drive a
///   batch-pseudo-stream yet). The pill simply shows the recording state with
///   no rolling preview text.
/// - **No custom vocabulary.** The CTC-110M spotter / rescorer is
///   Latin/English-oriented, so the vocab gate is intentionally skipped here
///   (mirrors how `.nemotron_en` advertises no-custom-vocab). `corrections`
///   is always empty.
/// - **Language hint** is the per-call ISO string (`"zh"`/`"yue"`/`"vi"`) from
///   `LanguageChoice.qwen3Language`, bound at construction.
/// - Gated `@available(macOS 15, *)` because `Qwen3AsrManager` is. Jot's
///   deployment target is already macOS 15, so this is the compiler-required
///   annotation only — no runtime hiding is needed.
///
/// Actor-isolated. Safe to hold one instance for the lifetime of the app.
@available(macOS 15, *)
public actor Qwen3Transcriber: Transcribing {
    private let log = Logger(subsystem: "com.jot.Jot", category: "Qwen3Transcriber")

    /// Directory holding the downloaded Qwen3-ASR int8 bundle
    /// (`qwen3_asr_audio_encoder_v2.mlmodelc`,
    /// `qwen3_asr_decoder_stateful.mlmodelc`, `qwen3_asr_embeddings.bin`,
    /// `vocab.json`).
    private let bundleDirectory: URL

    /// ISO language hint passed to `Qwen3AsrManager.transcribe`
    /// (`"zh"`/`"yue"`/`"vi"`). `nil` falls back to the model's automatic
    /// language detection — but in production this is always one of the three.
    private let languageHint: String?

    /// `true` for Mandarin/Cantonese (CJK, no inter-word spaces). Drives the
    /// final whitespace collapse: Qwen3 emits clean spaceless CJK already, so
    /// this only guards against stray separators. Vietnamese is `false`
    /// (space-separated Latin), so its spaces are preserved.
    private let spaceless: Bool

    private var manager: Qwen3AsrManager?
    private var isTranscribing: Bool = false

    public init(bundleDirectory: URL, languageHint: String?, spaceless: Bool) {
        self.bundleDirectory = bundleDirectory
        self.languageHint = languageHint
        self.spaceless = spaceless
    }

    /// Load the Qwen3-ASR models onto the ANE if not already loaded.
    /// Idempotent.
    public func ensureLoaded() async throws {
        if manager != nil { return }

        do {
            let mgr = Qwen3AsrManager()
            try await mgr.loadModels(from: bundleDirectory)
            manager = mgr
            log.info("Qwen3-ASR loaded")
        } catch {
            await ErrorLog.shared.error(
                component: "Qwen3Transcriber",
                message: "Qwen3-ASR load failed",
                context: ["error": ErrorLog.redactedAppleError(error)]
            )
            throw TranscriberError.fluidAudio(error)
        }
    }

    /// Expose the loaded `Qwen3AsrManager` so a sibling preview engine
    /// (`Qwen3StreamingTranscriber`) can reuse the SAME on-device model instance
    /// instead of triggering a second multi-hundred-MB CoreML load. Loads on
    /// demand (idempotent) and hands back the shared actor reference. The
    /// streaming preview and the batch final never run concurrently within one
    /// recording (preview is quiesced/cancelled at stop before the batch final),
    /// so a single shared manager is safe.
    func sharedManager() async throws -> Qwen3AsrManager {
        try await ensureLoaded()
        guard let manager else { throw TranscriberError.modelNotLoaded }
        return manager
    }

    /// Drop the in-memory model. No-op if nothing is loaded.
    public func unload() {
        manager = nil
    }

    public var busy: Bool { isTranscribing }

    public var isReady: Bool { manager != nil }

    /// Transcribe a 16 kHz mono Float32 buffer. Throws `.busy` if a previous
    /// call is still running.
    ///
    /// `recordsProvenance` is accepted to satisfy the `Transcribing` surface
    /// but is INERT here: the custom-vocabulary gate (which owns the
    /// provenance slot) does not run on the Qwen3 path, so there is nothing to
    /// record. The saving path still clears any stale pending proposals so a
    /// later `commit` from a different transcription can't mis-attribute.
    public func transcribe(
        _ samples: [Float],
        recordsProvenance: Bool = false
    ) async throws -> TranscriptionResult {
        guard !isTranscribing else { throw TranscriberError.busy }
        guard samples.count >= Int(AudioFormat.sampleRate) else {
            throw TranscriberError.audioTooShort
        }

        // Vocab gate is OFF for Qwen3, so there are no proposals to record.
        // But a saving caller still owns the shared pending slot for THIS
        // transcription id — clear any stale proposals so a prior dictation's
        // pending set can't leak into this row's commit.
        if recordsProvenance {
            await CorrectionProvenance.shared.clearPending()
        }

        guard let manager else { throw TranscriberError.modelNotLoaded }

        isTranscribing = true
        defer { isTranscribing = false }

        let started = Date()
        let raw: String
        do {
            raw = try await manager.transcribe(
                audioSamples: samples,
                language: languageHint
            )
        } catch {
            await ErrorLog.shared.error(
                component: "Qwen3Transcriber",
                message: "Qwen3-ASR transcribe failed",
                context: ["sampleCount": String(samples.count), "error": ErrorLog.redactedAppleError(error)]
            )
            throw TranscriberError.fluidAudio(error)
        }

        // Qwen3 emits clean native punctuation + casing (and spaceless CJK for
        // zh/yue). For CJK collapse any stray internal whitespace; for
        // Vietnamese leave the word spacing intact. No vocab, no v2-style
        // regex chain — the model's text is the result.
        let text: String
        if spaceless {
            text = raw
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined()
        } else {
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return TranscriptionResult(
            text: text,
            rawText: raw,
            duration: TimeInterval(samples.count) / AudioFormat.sampleRate,
            processingTime: Date().timeIntervalSince(started),
            confidence: 1.0,
            corrections: []
        )
    }

    /// Decode a WAV file at `url` and run it through the same `transcribe`
    /// path. Mirrors `Transcriber.transcribeFile` (Library re-transcribe /
    /// Wizard TestStep / the DEBUG harness).
    public func transcribeFile(
        _ url: URL,
        recordsProvenance: Bool = false
    ) async throws -> TranscriptionResult {
        try await ensureLoaded()
        let file = try AVAudioFile(forReading: url)
        let samples = try Self.readMono16kFloat(file: file)
        return try await transcribe(samples, recordsProvenance: recordsProvenance)
    }

    // MARK: - WAV reading (mirrors Transcriber.readMono16kFloat)

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
                    NSError(domain: "Jot.Qwen3Transcriber", code: -1)
                )
            }
            try file.read(into: buffer)
            return Self.floats(from: buffer)
        }

        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Qwen3Transcriber", code: -2)
            )
        }
        try file.read(into: inBuffer)

        guard let converter = AVAudioConverter(
            from: processingFormat,
            to: AudioFormat.target
        ) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Qwen3Transcriber", code: -3)
            )
        }

        let ratio = AudioFormat.sampleRate / processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: AudioFormat.target,
            frameCapacity: outCapacity
        ) else {
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Qwen3Transcriber", code: -4)
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

        if status == .error {
            if let convertError { throw TranscriberError.fluidAudio(convertError) }
            throw TranscriberError.fluidAudio(
                NSError(domain: "Jot.Qwen3Transcriber", code: -5)
            )
        }

        return Self.floats(from: outBuffer)
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }
}
