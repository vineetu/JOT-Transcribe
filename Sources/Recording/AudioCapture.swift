@preconcurrency import AVFoundation
import Foundation
import os.log

/// Errors surfaced by `AudioCapture` when the audio engine path fails in a
/// way the caller needs to distinguish. Device/driver errors are wrapped
/// rather than swallowed so `RecorderController` can render a message.
public enum AudioCaptureError: Error, Sendable {
    case alreadyRunning
    case notRunning
    case converterUnavailable
    case engineStart(Error)
    case fileCreate(Error)
    case conversion(Error)
}

/// Owns the `AVAudioEngine` microphone tap for a single recording session.
///
/// - Installs a tap at the input node's hardware format (CoreAudio requires
///   the tap format to match the node's output format).
/// - Runs each tapped buffer through an `AVAudioConverter` that resamples to
///   `AudioFormat.target` (16 kHz mono Float32, non-interleaved).
/// - Appends the converted Float32 samples to an in-memory `[Float]` buffer
///   *and* writes them incrementally to a WAV file on disk, so the buffer is
///   ready for Parakeet the moment `stop()` returns.
/// - Rebuilds the converter on the fly if the input node's format changes
///   mid-session (e.g. the user switches microphones).
///
/// Actor-isolated because the engine + file + buffer state must not be
/// touched concurrently.
public actor AudioCapture {
    private let log = Logger(subsystem: "com.jot.Jot", category: "AudioCapture")

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var audioFile: AVAudioFile?
    private var samples: [Float] = []
    private var fileURL: URL?
    private var startedAt: Date?

    private let recordingsDirectory: URL

    public init(recordingsDirectory: URL = AudioCapture.defaultRecordingsDirectory) {
        self.recordingsDirectory = recordingsDirectory
    }

    /// `~/Library/Application Support/Jot/Recordings/`. Created lazily on
    /// first use. Phase 4 Library will add retention / cleanup; for now we
    /// just keep every WAV so re-transcription is possible.
    public static var defaultRecordingsDirectory: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Jot/Recordings", isDirectory: true)
    }

    // MARK: - Start / Stop

    public func start() throws {
        guard engine == nil else { throw AudioCaptureError.alreadyRunning }

        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let url = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        let file: AVAudioFile
        do {
            // Persist at the post-conversion format so the file on disk is
            // already what Parakeet wants — no second conversion step when
            // we re-transcribe later.
            file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormat.target.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioCaptureError.fileCreate(error)
        }

        guard let converter = Self.makeConverter(from: hardwareFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        self.engine = engine
        self.converter = converter
        self.converterInputFormat = hardwareFormat
        self.audioFile = file
        self.fileURL = url
        self.samples = []
        self.startedAt = Date()

        // Tap buffer size: 4096 frames is a good middle ground — small enough
        // to keep latency low, large enough to avoid tap overhead dominating.
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy the buffer payload out of the audio thread before hopping
            // into the actor. `AVAudioPCMBuffer` is reference-type and the
            // engine reuses the underlying storage, so a snapshot is
            // mandatory to avoid reading overwritten frames.
            guard let snapshot = buffer.copy() as? AVAudioPCMBuffer else { return }
            Task {
                await self.append(snapshot)
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            self.converter = nil
            self.audioFile = nil
            self.fileURL = nil
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.engineStart(error)
        }
    }

    public func stop() throws -> AudioRecording {
        guard let engine, let url = fileURL, let startedAt else {
            throw AudioCaptureError.notRunning
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let captured = samples
        let duration = TimeInterval(captured.count) / AudioFormat.sampleRate
        let recording = AudioRecording(
            samples: captured,
            fileURL: url,
            duration: duration,
            createdAt: startedAt
        )

        resetState()
        return recording
    }

    public func cancel() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        if let url = fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        resetState()
    }

    // MARK: - Tap handling

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile else { return }

        let incomingFormat = buffer.format
        if converterInputFormat != incomingFormat {
            // Input format flipped mid-session (mic switch, sample-rate
            // change). Rebuild the converter rather than dropping audio.
            guard let rebuilt = Self.makeConverter(from: incomingFormat) else {
                log.error("Failed to rebuild converter for new input format")
                return
            }
            converter = rebuilt
            converterInputFormat = incomingFormat
        }

        guard let converter else { return }

        // Allocate an output buffer sized for the ratio between input and
        // target sample rates, with a safety margin for internal converter
        // framing. Overshooting is cheap; undershooting causes `.endOfStream`
        // from the converter mid-chunk.
        let ratio = AudioFormat.sampleRate / incomingFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: AudioFormat.target,
                frameCapacity: estimatedFrames
            )
        else {
            log.error("Failed to allocate output buffer")
            return
        }

        var suppliedOnce = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if suppliedOnce {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedOnce = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .error:
            if let error { log.error("AudioConverter error: \(error.localizedDescription)") }
            return
        case .inputRanDry, .haveData, .endOfStream:
            break
        @unknown default:
            break
        }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let channelData = outBuffer.floatChannelData else { return }

        let channelPtr = channelData[0]
        samples.append(contentsOf: UnsafeBufferPointer(start: channelPtr, count: frameCount))

        do {
            try audioFile.write(from: outBuffer)
        } catch {
            log.error("AVAudioFile write failed: \(error.localizedDescription)")
        }
    }

    private func resetState() {
        engine = nil
        converter = nil
        converterInputFormat = nil
        audioFile = nil
        fileURL = nil
        startedAt = nil
        samples = []
    }

    // MARK: - Helpers

    private static func makeConverter(from input: AVAudioFormat) -> AVAudioConverter? {
        AVAudioConverter(from: input, to: AudioFormat.target)
    }
}
