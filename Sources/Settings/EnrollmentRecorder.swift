@preconcurrency import AVFoundation
import Foundation
import os.log

/// Lightweight in-process audio recorder used by Speaker Labels
/// enrollment. Unlike Jot's main `AudioCapture`, this one:
///
/// * Records to memory only — no WAV file on disk. Enrollment clips live
///   inside SwiftData (`EnrolledIdentity.voiceClips`), not on the
///   filesystem, so a recorded clip just needs to land as a `[Float]`.
/// * Doesn't depend on the global `RecorderController` / `HotkeyRouter`
///   plumbing. Enrollment runs from the Settings sheet, never via a
///   hotkey, and shouldn't interfere with the dictation pipeline.
/// * Uses `AVAudioEngine` (high-level) instead of the CoreAudio AUHAL
///   path. Enrollment is a deliberate fixed-purpose 30-second capture;
///   the AUHAL device-pinning machinery is overkill.
///
/// Format: 16 kHz mono Float32, matching Sortformer's input expectation
/// and the rest of Jot's transcription pipeline. The system input is
/// resampled via `AVAudioConverter` on the install-tap callback (which
/// runs on a real-time audio thread; conversion is hopped onto a writer
/// queue so AVAudioConverter never crosses thread boundaries).
@MainActor
final class EnrollmentRecorder: ObservableObject {

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case stopped(durationSec: Double, sampleCount: Int)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: Double = 0

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.jot.Jot", category: "EnrollmentRecorder")

    /// Writer queue + the buffer/converter it owns. Audio-tap callbacks
    /// hop here; the main actor reads `queueState.samples` via
    /// `writerQueue.sync` at stop time.
    private let writerQueue = DispatchQueue(label: "com.jot.EnrollmentRecorder.writer", qos: .userInitiated)
    private let queueState = QueueState()

    private var startedAt: Date?
    private var elapsedTimer: Timer?

    func start() {
        cleanup()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.channelCount > 0 else {
            state = .failed(message: "No microphone input is available.")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            state = .failed(message: "Could not configure the audio format converter.")
            return
        }

        let queueState = self.queueState
        let writerQueue = self.writerQueue
        let target = Self.targetFormat
        writerQueue.sync {
            queueState.converter = converter
            queueState.samples.removeAll(keepingCapacity: true)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            // Hop into the writer queue. AVAudioConverter is not
            // documented as thread-safe; serialize all touches.
            writerQueue.async { [weak queueState] in
                guard let queueState else { return }
                queueState.convertAndAppend(buffer: buffer, target: target)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            state = .failed(message: "Could not start audio capture: \(error.localizedDescription)")
            return
        }

        let start = Date()
        startedAt = start
        state = .recording(startedAt: start)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .recording(let startedAt) = self.state else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }

    /// Stop the engine and return the captured samples. State transitions
    /// to `.stopped` with the duration + count. Returns the captured
    /// `[Float]` or `nil` if not recording.
    @discardableResult
    func stop() -> [Float]? {
        guard case .recording(let startedAt) = state else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        let queueState = self.queueState
        let samples = writerQueue.sync { queueState.samples }
        let duration = Date().timeIntervalSince(startedAt)
        state = .stopped(durationSec: duration, sampleCount: samples.count)
        return samples
    }

    func cancel() {
        if case .recording = state {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        cleanup()
        state = .idle
        elapsedSeconds = 0
    }

    private func cleanup() {
        startedAt = nil
        let queueState = self.queueState
        writerQueue.sync {
            queueState.converter = nil
            queueState.samples.removeAll(keepingCapacity: false)
        }
    }
}

/// Writer-queue-confined audio state for `EnrollmentRecorder`. All
/// reads/writes happen on the recorder's `writerQueue`; `@unchecked
/// Sendable` because we serialize access at the queue boundary.
private final class QueueState: @unchecked Sendable {
    var converter: AVAudioConverter?
    var samples: [Float] = []

    func convertAndAppend(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outCapacity
        ) else { return }

        var error: NSError?
        var provided = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if !provided {
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil,
              let channelData = outBuffer.floatChannelData?.pointee,
              outBuffer.frameLength > 0 else { return }

        let count = Int(outBuffer.frameLength)
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: count))
    }
}
