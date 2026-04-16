import AVFoundation
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
/// - Apply `PostProcessing` to the decoded text and expose both raw and
///   cleaned strings on `TranscriptionResult`.
///
/// Actor-isolated. Safe to hold one instance for the lifetime of the app.
public actor Transcriber {
    private let log = Logger(subsystem: "com.jot.Jot", category: "Transcriber")

    private let cache: ModelCache
    private let modelID: ParakeetModelID

    private var manager: AsrManager?
    private var isTranscribing: Bool = false

    public init(cache: ModelCache = .shared, modelID: ParakeetModelID = .tdt_0_6b_v3) {
        self.cache = cache
        self.modelID = modelID
    }

    /// Load Parakeet into memory if it isn't already. Idempotent — safe to
    /// call from the UI layer speculatively (e.g. right after the model
    /// download finishes) to front-load the ANE warm-up.
    public func ensureLoaded() async throws {
        if manager != nil { return }

        let directory = cache.cacheURL(for: modelID)
        guard cache.isCached(modelID) else {
            throw TranscriberError.modelMissing
        }

        do {
            let models = try await AsrModels.load(
                from: directory,
                version: modelID.fluidAudioVersion
            )
            let manager = AsrManager()
            try await manager.loadModels(models)
            self.manager = manager
            log.info("Parakeet loaded")
        } catch let error as TranscriberError {
            throw error
        } catch {
            throw TranscriberError.fluidAudio(error)
        }
    }

    /// Drop the in-memory model. No-op if nothing is loaded. Phase 2 doesn't
    /// wire this to any policy — Phase 4 will decide when to evict (e.g. on
    /// long idle periods to free ANE memory).
    public func unload() {
        manager = nil
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
        guard let manager else { throw TranscriberError.modelNotLoaded }
        guard samples.count >= Int(AudioFormat.sampleRate) else {
            throw TranscriberError.audioTooShort
        }

        isTranscribing = true
        defer { isTranscribing = false }

        let result: ASRResult
        do {
            result = try await manager.transcribe(samples, source: .microphone)
        } catch {
            throw TranscriberError.fluidAudio(error)
        }

        let cleaned = PostProcessing.apply(result.text)
        return TranscriptionResult(
            text: cleaned,
            rawText: result.text,
            duration: result.duration,
            processingTime: result.processingTime,
            confidence: result.confidence
        )
    }

    /// True while a `transcribe(_:)` call is in flight. Exposed so the
    /// recorder can surface "transcribing" state without racing the actor.
    public var busy: Bool { isTranscribing }

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
