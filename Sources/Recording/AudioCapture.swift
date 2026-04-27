@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.log
import SwiftUI

/// Errors surfaced by `AudioCapture` when the audio engine path fails in a
/// way the caller needs to distinguish. Device/driver errors are wrapped
/// rather than swallowed so `RecorderController` can render a message.
public enum AudioCaptureError: Error, Sendable {
    case alreadyRunning
    case notRunning
    case converterUnavailable
    case engineStart(Error)
    case engineStartTimeout
    case fileCreate(Error)
    case conversion(Error)

    /// User-facing message shown when we detect the CoreAudio subsystem is
    /// wedged. Callers that surface `engineStartTimeout` should show this
    /// as-is (no "Could not start recording:" prefix) and leave the
    /// follow-up instructions to the Help → Troubleshooting card.
    public static let engineStartTimeoutMessage =
        "Audio system isn't responding — see Help → Troubleshooting."
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
public actor AudioCapture: AudioCapturing {
    private let log = Logger(subsystem: "com.jot.Jot", category: "AudioCapture")

    nonisolated(unsafe) public weak var amplitudePublisher: AmplitudePublisher?

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

    public func setAmplitudePublisher(_ publisher: AmplitudePublisher?) {
        amplitudePublisher = publisher
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

    public func start() async throws {
        guard engine == nil else { throw AudioCaptureError.alreadyRunning }

        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let url = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let selectedUID = UserDefaults.standard.string(forKey: "jot.inputDeviceUID") ?? ""
        let publisher = self.amplitudePublisher

        let setup: EngineSetup
        do {
            setup = try await Self.configureEngineWithTimeout(
                capture: self,
                amplitudePublisher: publisher,
                selectedUID: selectedUID,
                url: url,
                seconds: 5
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            switch error {
            case AudioCaptureError.engineStartTimeout:
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "Audio engine setup timed out (>5s) — coreaudiod may be stuck; see Help → Troubleshooting") }
            case AudioCaptureError.engineStart(let inner):
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "AVAudioEngine.start failed", context: ["error": ErrorLog.redactedAppleError(inner)]) }
            case AudioCaptureError.fileCreate(let inner):
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "Recording file create failed", context: ["error": ErrorLog.redactedAppleError(inner)]) }
            case AudioCaptureError.converterUnavailable:
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "AVAudioConverter unavailable") }
            default:
                Task { await ErrorLog.shared.error(component: "AudioCapture", message: "Audio engine setup failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            }
            throw error
        }

        self.engine = setup.engine
        self.converter = setup.converter
        self.converterInputFormat = setup.hardwareFormat
        self.audioFile = setup.file
        self.fileURL = url
        self.samples = []
        self.startedAt = Date()
    }

    /// Bundle of engine + file + converter handed back from the
    /// background-queue setup closure. Marked `@unchecked Sendable` because
    /// the AVFoundation types are already treated as sendable via the
    /// `@preconcurrency` import at the top of the file, and the struct only
    /// crosses thread boundaries once (BG setup → actor).
    private struct EngineSetup: @unchecked Sendable {
        let engine: AVAudioEngine
        let file: AVAudioFile
        let converter: AVAudioConverter
        let hardwareFormat: AVAudioFormat
    }

    /// Runs the entire CoreAudio-touching setup sequence on a background
    /// GCD queue under a single timeout. On macOS, the following
    /// synchronous calls can each block indefinitely when `coreaudiod` is
    /// wedged (e.g. iOS Simulator holding audio hardware, Bluetooth glitch,
    /// sleep/wake race):
    ///   - `AudioObjectGetPropertyData{Size}` (HAL device enumeration when pinning)
    ///   - `engine.inputNode.auAudioUnit.setDeviceID(...)` (when pinning)
    ///   - `engine.inputNode` access (resolves default input)
    ///   - `input.outputFormat(forBus: 0)` (queries hardware format)
    ///   - `input.installTap(...)` (touches device)
    ///   - `engine.prepare()` + `engine.start()`
    ///
    /// The prior implementation only wrapped `prepare()` + `start()`, so a
    /// wedged `coreaudiod` would block `engine.inputNode` before the
    /// timeout had a chance to fire — locking up the `AudioCapture` actor's
    /// executor thread forever. Widening coverage to the full sequence
    /// ensures the caller always sees either a clean success or a clean
    /// `engineStartTimeout` after `seconds` elapsed.
    ///
    /// On timeout we abandon the engine reference. The background thread
    /// eventually unblocks (when the user runs `sudo killall coreaudiod` or
    /// restarts), and the orphan is reclaimed when its refcount drops to
    /// zero. File creation and `makeConverter` live inside the closure too
    /// so the actor owns nothing if setup fails.
    private static func configureEngineWithTimeout(
        capture: AudioCapture,
        amplitudePublisher: AmplitudePublisher?,
        selectedUID: String,
        url: URL,
        seconds: Double
    ) async throws -> EngineSetup {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<EngineSetup, Error>) in
            let lock = NSLock()
            var hasResumed = false
            func resumeOnce(_ result: Result<EngineSetup, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let v): cont.resume(returning: v)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let engine = AVAudioEngine()

                // Pin the input to the user's chosen device BEFORE reading the
                // hardware format and installing the tap. On macOS, AVAudioEngine
                // otherwise follows the system default. Empty UID means "system
                // default" — skip pinning.
                if !selectedUID.isEmpty {
                    if let deviceID = AudioCapture.audioDeviceID(forUID: selectedUID) {
                        do {
                            try engine.inputNode.auAudioUnit.setDeviceID(AUAudioObjectID(deviceID))
                            engine.reset()
                        } catch {
                            Task { await ErrorLog.shared.warn(component: "AudioCapture", message: "Input device pin failed, falling back to default", context: ["error": ErrorLog.redactedAppleError(error)]) }
                        }
                    } else {
                        Task { await ErrorLog.shared.warn(component: "AudioCapture", message: "Selected input UID not present, falling back to default") }
                    }
                }

                let input = engine.inputNode
                let hardwareFormat = input.outputFormat(forBus: 0)

                // Persist at the post-conversion format so the file on disk is
                // already what Parakeet wants — no second conversion step when
                // we re-transcribe later.
                let file: AVAudioFile
                do {
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: AudioFormat.target.settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                } catch {
                    resumeOnce(.failure(AudioCaptureError.fileCreate(error)))
                    return
                }

                guard let converter = AudioCapture.makeConverter(from: hardwareFormat) else {
                    resumeOnce(.failure(AudioCaptureError.converterUnavailable))
                    return
                }

                // Tap buffer size: 4096 frames is a good middle ground — small
                // enough to keep latency low, large enough to avoid tap overhead
                // dominating.
                input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak capture, weak amplitudePublisher] buffer, _ in
                    // LOAD-BEARING: RMS must be computed from the PRE-CONVERTER
                    // hardware-rate buffer here. Moving this computation after
                    // the AVAudioConverter step (in `append(_:)`) drops update
                    // cadence from ~11 Hz to ~3.9 Hz and the waveform will
                    // visibly stutter. Do not move.
                    let level = AmplitudePublisher.rms(from: buffer)
                    Task { @MainActor [weak amplitudePublisher] in
                        amplitudePublisher?.append(rms: level)
                    }
                    // Copy the buffer payload out of the audio thread before
                    // hopping into the actor. `AVAudioPCMBuffer` is reference-
                    // type and the engine reuses the underlying storage, so a
                    // snapshot is mandatory to avoid reading overwritten frames.
                    guard let snapshot = buffer.copy() as? AVAudioPCMBuffer else { return }
                    Task { [weak capture] in
                        await capture?.append(snapshot)
                    }
                }

                do {
                    engine.prepare()
                    try engine.start()
                    resumeOnce(.success(EngineSetup(
                        engine: engine,
                        file: file,
                        converter: converter,
                        hardwareFormat: hardwareFormat
                    )))
                } catch {
                    input.removeTap(onBus: 0)
                    resumeOnce(.failure(AudioCaptureError.engineStart(error)))
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                resumeOnce(.failure(AudioCaptureError.engineStartTimeout))
            }
        }
    }

    public func stop() async throws -> AudioRecording {
        guard let engine, let url = fileURL, let startedAt else {
            throw AudioCaptureError.notRunning
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drain any Tasks queued by the tap before we snapshot `samples`.
        // Actor scheduler processes Tasks in FIFO order, so awaiting a new Task
        // guarantees all previously-enqueued append Tasks have completed.
        await withCheckedContinuation { cont in
            Task { cont.resume() }
        }

        let captured = samples
        let duration = TimeInterval(captured.count) / AudioFormat.sampleRate
        let recording = AudioRecording(
            samples: captured,
            fileURL: url,
            duration: duration,
            createdAt: startedAt
        )

        resetState()
        let publisher = amplitudePublisher
        Task { @MainActor [weak publisher] in
            publisher?.reset()
        }
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
        let publisher = amplitudePublisher
        Task { @MainActor [weak publisher] in
            publisher?.reset()
        }
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

    /// Resolves a CoreAudio device UID string (e.g. "AppleHDAEngineInput:…"
    /// or "BuiltInMicrophoneDevice") to the current `AudioDeviceID`. The
    /// ID changes across reboots and reconnects, so we must look it up
    /// every time rather than caching. Returns nil if the device is not
    /// currently present (e.g. BT headset disconnected) — caller falls
    /// back to the system default.
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for deviceID in deviceIDs {
            // CoreAudio writes a retained CFString pointer into the
            // out-parameter. Phase 3 #12: store it through
            // `Unmanaged<CFString>?` (defined raw-pointer ABI) instead
            // of `CFString?` (which the Swift compiler flags because
            // forming `UnsafeMutableRawPointer` to a typed Optional of
            // an object reference is ambiguous about ARC ownership).
            // `takeRetainedValue()` matches the +1 retain CoreAudio
            // returns; no manual release needed.
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var deviceUID: Unmanaged<CFString>? = nil
            let uidStatus = AudioObjectGetPropertyData(
                deviceID, &uidAddress, 0, nil, &uidSize, &deviceUID
            )
            if uidStatus == noErr,
               let resolved = deviceUID?.takeRetainedValue() as String?,
               resolved == uid {
                return deviceID
            }
        }
        return nil
    }
}
