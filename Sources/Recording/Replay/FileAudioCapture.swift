#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import os.log

/// DEBUG-only `AudioCapturing` conformer that plays a recording file into the
/// dictation pipeline as if it were the microphone. Used by the headless
/// dictation replay harness (`DictationReplay`).
///
/// It mirrors `AudioCapture`'s delivery path rather than handing the pipeline
/// 16 kHz samples directly: the file is first rendered to a device-rate mono
/// Float32 buffer (48 kHz by default), then a render queue slices it into
/// AUHAL-sized callbacks (512 frames by default) at real-time pace (or
/// `speed`× faster). Each slice goes to a serial writer queue that runs the
/// same `AVAudioConverter` → append-to-`samples` → streaming-sink snapshot →
/// `AVAudioFile.write` sequence as `AudioCapture.convertAndWrite`, with the
/// same >64-outstanding backpressure drop. A 48 kHz / 512-frame device
/// therefore produces the same ~170-sample 16 kHz chunks the live mic does.
final class FileAudioCapture: AudioCapturing, @unchecked Sendable {
    struct Stats: Sendable {
        var callbacks = 0
        var droppedCallbacks = 0
        var deliveredSamples16k = 0
        var sinkChunks = 0
        var minChunk = Int.max
        var maxChunk = 0
    }

    private let log = Logger(subsystem: "com.jot.Jot", category: "FileAudioCapture")
    private let recordingsDirectory: URL
    private let speed: Double
    private let deviceRate: Double
    private let framesPerCallback: Int
    private let deviceFormat: AVAudioFormat

    private let lock = NSLock()
    private var preparedSource: [Float]?
    private var session: Session?
    private var sink: (@Sendable ([Float]) -> Void)?
    private var lastStats = Stats()

    private let writerQueue = DispatchQueue(label: "com.jot.FileAudioCapture.writer", qos: .userInitiated)
    private let renderQueue = DispatchQueue(label: "com.jot.FileAudioCapture.render", qos: .userInteractive)
    private static let outstandingLimit = 64

    /// Writer-queue-only state, the replay twin of `AudioCapture.QueueState`.
    private final class QueueState: @unchecked Sendable {
        var samples: [Float] = []
        var audioFile: AVAudioFile?
        var converter: AVAudioConverter?
        var streamingSink: (@Sendable ([Float]) -> Void)?
        var stats = Stats()
    }

    private final class Session: @unchecked Sendable {
        let deviceSamples: [Float]
        let fileURL: URL
        let startedAt: Date
        let queueState: QueueState
        let timer: DispatchSourceTimer
        // Render-queue-only.
        var cursor = 0
        var stopping = false
        var playbackStart: DispatchTime = .now()
        // Guarded by `outstandingLock`.
        let outstandingLock = OSAllocatedUnfairLock(initialState: 0)
        // Guarded by the capture's `lock`.
        var exhaustedWaiters: [CheckedContinuation<Void, Never>] = []
        var exhausted = false

        init(deviceSamples: [Float], fileURL: URL, queueState: QueueState, timer: DispatchSourceTimer) {
            self.deviceSamples = deviceSamples
            self.fileURL = fileURL
            self.startedAt = Date()
            self.queueState = queueState
            self.timer = timer
        }
    }

    init(recordingsDirectory: URL, speed: Double = 1, deviceRate: Double = 48_000, framesPerCallback: Int = 512) {
        self.recordingsDirectory = recordingsDirectory
        self.speed = max(0.01, speed)
        self.deviceRate = deviceRate
        self.framesPerCallback = framesPerCallback
        self.deviceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: deviceRate, channels: 1, interleaved: false)!
    }

    // MARK: - Source

    /// Decode `url` (any AVAudioFile-readable format) to device-rate mono
    /// Float32 for the NEXT `start()`. Done ahead of `start()` so the decode
    /// isn't charged to the dictation.
    func prepareSource(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioCaptureError.converterUnavailable
        }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: inFormat, to: deviceFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        let ratio = deviceRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 4096)
        guard let output = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.converterUnavailable
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? AudioCaptureError.converterUnavailable }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        lock.withLock { preparedSource = samples }
    }

    var stats: Stats { lock.withLock { lastStats } }

    /// Resolves once every callback of the current session has been handed to
    /// the writer queue (the "speaker stopped talking at end of file" moment).
    func waitUntilExhausted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard let session, !session.exhausted else {
                lock.unlock()
                continuation.resume()
                return
            }
            session.exhaustedWaiters.append(continuation)
            lock.unlock()
        }
    }

    // MARK: - AudioCapturing

    func start() async throws {
        let (samples, sinkAtStart): ([Float], (@Sendable ([Float]) -> Void)?) = try lock.withLock {
            guard session == nil else { throw AudioCaptureError.alreadyRunning }
            guard let source = preparedSource else { throw AudioCaptureError.notRunning }
            preparedSource = nil
            return (source, sink)
        }
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let url = recordingsDirectory.appendingPathComponent("\(UUID().uuidString).\(AudioFormat.storageFileExtension)")
        let queueState = QueueState()
        do {
            queueState.audioFile = try AVAudioFile(
                forWriting: url,
                settings: AudioFormat.storageSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioCaptureError.fileCreate(error)
        }
        guard let converter = AVAudioConverter(from: deviceFormat, to: AudioFormat.target) else {
            throw AudioCaptureError.converterUnavailable
        }
        queueState.converter = converter
        queueState.streamingSink = sinkAtStart

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
        let session = Session(deviceSamples: samples, fileURL: url, queueState: queueState, timer: timer)
        lock.withLock { self.session = session }

        // Tick every 5 ms and deliver every callback whose deadline has
        // passed, so `speed` > 1 and timer jitter both keep the true cadence.
        let period = Double(framesPerCallback) / deviceRate / speed
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.renderTick(session: session, period: period)
        }
        renderQueue.sync { session.playbackStart = .now() }
        timer.resume()
    }

    func stop() async throws -> AudioRecording {
        guard let session = lock.withLock({ self.session }) else { throw AudioCaptureError.notRunning }
        haltRender(session)
        // Same order as `AudioCapture.stop()`: snapshot under the writer
        // queue, which first drains every slice already dispatched to it.
        let captured = writerQueue.sync {
            let snapshot = session.queueState.samples
            session.queueState.audioFile = nil
            session.queueState.converter = nil
            session.queueState.samples.removeAll(keepingCapacity: false)
            return snapshot
        }
        finish(session)
        return AudioRecording(
            samples: captured,
            fileURL: session.fileURL,
            duration: TimeInterval(captured.count) / AudioFormat.sampleRate,
            createdAt: session.startedAt
        )
    }

    func cancel() async {
        guard let session = lock.withLock({ self.session }) else { return }
        haltRender(session)
        writerQueue.sync {
            session.queueState.audioFile = nil
            session.queueState.converter = nil
            session.queueState.samples.removeAll(keepingCapacity: false)
        }
        try? FileManager.default.removeItem(at: session.fileURL)
        finish(session)
    }

    func setAmplitudePublisher(_ publisher: AmplitudePublisher?) async {}

    func setStreamingSink(_ sink: (@Sendable ([Float]) -> Void)?) async {
        let session = lock.withLock { () -> Session? in
            self.sink = sink
            return self.session
        }
        if let queueState = session?.queueState {
            writerQueue.async { queueState.streamingSink = sink }
        }
    }

    // MARK: - Render + writer

    private func haltRender(_ session: Session) {
        renderQueue.sync {
            session.stopping = true
            session.timer.cancel()
        }
        markExhausted(session)
    }

    private func finish(_ session: Session) {
        let stats = writerQueue.sync { session.queueState.stats }
        lock.withLock {
            lastStats = stats
            if self.session === session { self.session = nil }
        }
    }

    private func markExhausted(_ session: Session) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !session.exhausted else { return [] }
            session.exhausted = true
            defer { session.exhaustedWaiters.removeAll() }
            return session.exhaustedWaiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Render-queue: the AUHAL input callback stand-in.
    private func renderTick(session: Session, period: Double) {
        guard !session.stopping else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - session.playbackStart.uptimeNanoseconds) / 1e9
        let due = Int(elapsed / period) + 1
        let total = session.deviceSamples.count
        while session.cursor < total, session.cursor / framesPerCallback < due {
            let count = min(framesPerCallback, total - session.cursor)
            deliverCallback(session: session, range: session.cursor..<(session.cursor + count))
            session.cursor += count
        }
        if session.cursor >= total {
            session.timer.cancel()
            markExhausted(session)
        }
    }

    private func deliverCallback(session: Session, range: Range<Int>) {
        guard let scratch = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: AVAudioFrameCount(range.count)) else { return }
        scratch.frameLength = AVAudioFrameCount(range.count)
        session.deviceSamples.withUnsafeBufferPointer { src in
            scratch.floatChannelData![0].update(from: src.baseAddress! + range.lowerBound, count: range.count)
        }
        let queueState = session.queueState
        let outstanding = session.outstandingLock.withLock { $0 }
        if outstanding > Self.outstandingLimit {
            writerQueue.async { queueState.stats.droppedCallbacks += 1 }
            return
        }
        session.outstandingLock.withLock { $0 += 1 }
        let lockRef = session.outstandingLock
        let log = self.log
        let sourceFormat = deviceFormat
        writerQueue.async {
            defer { lockRef.withLock { $0 -= 1 } }
            queueState.stats.callbacks += 1
            Self.convertAndWrite(scratch, sourceFormat: sourceFormat, queueState: queueState, log: log)
        }
    }

    /// Line-for-line twin of `AudioCapture.swift`'s `convertAndWrite`.
    private static func convertAndWrite(
        _ buffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat,
        queueState: QueueState,
        log: Logger
    ) {
        guard let audioFile = queueState.audioFile,
              let converter = queueState.converter
        else {
            return
        }

        let ratio = AudioFormat.sampleRate / sourceFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.target, frameCapacity: estimatedFrames) else {
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
        if status == .error {
            log.error("replay AudioConverter error")
            return
        }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let channelData = outBuffer.floatChannelData else { return }

        let channelPtr = channelData[0]
        queueState.samples.append(contentsOf: UnsafeBufferPointer(start: channelPtr, count: frameCount))
        queueState.stats.deliveredSamples16k += frameCount

        if let sink = queueState.streamingSink {
            let snapshot = Array(UnsafeBufferPointer(start: channelPtr, count: frameCount))
            queueState.stats.sinkChunks += 1
            queueState.stats.minChunk = min(queueState.stats.minChunk, frameCount)
            queueState.stats.maxChunk = max(queueState.stats.maxChunk, frameCount)
            sink(snapshot)
        }

        do {
            try audioFile.write(from: outBuffer)
        } catch {
            log.error("replay AVAudioFile write failed")
        }
    }
}
#endif
