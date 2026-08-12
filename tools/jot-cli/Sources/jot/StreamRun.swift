import AVFoundation
import FluidAudio
import Foundation

/// `jot --stream` — live transcription for pipe-driven callers (Call Assist).
///
/// Interface (matches the caller's spawn contract exactly):
///
///     jot --stream --language <en|zh> --rate 16000 --encoding s16le
///
///   stdin   raw PCM, mono, s16le, at --rate (16 kHz only, checked)
///   stdout  one JSON object per line: {"type":"partial"|"final","text":"…"}
///   stderr  human-readable progress/logs, never JSON
///
/// Engines (FluidAudio 0.15.4 — same pin as the app; the app's
/// `NemotronStreamingTranscriber` / `NemotronMultilingualStreamingTranscriber`
/// are the reference for this usage):
///   en  StreamingNemotronAsrManager, 1120 ms chunks (the trained chunk; ms560 fails CoreML load on this box).
///   zh  StreamingNemotronMultilingualAsrManager, language pinned to zh-CN
///       (auto-detect off — a call must not free-associate languages).
///
/// Utterance finals, two modes (`--endpoint`):
///
///   auto    (default) RNN-T decoders emit nothing on non-speech, so "partial
///           unchanged for chunkMs + `silenceMarginMs` while non-empty" IS the
///           end-of-utterance signal. Self-contained, but slow: ≈1.8 s of audio
///           must pass before the final lands, which is dead air on a phone
///           call.
///   caller  The caller owns turn-taking (it already runs VAD / a turn model)
///           and tells us when to close the utterance by sending SIGUSR1. The
///           final then lands one decode later instead of ~1.8 s later. The
///           auto rule stays armed at a long `callerSafetyNetMs` so a caller
///           that stops signalling still gets its text.
///
/// Closing an utterance is the same work either way: `finish()` (decodes +
/// clears accumulation) → emit final → `reset()` → continue. Models
/// auto-download on first run (stderr progress).
///
/// SIGUSR1 is delivered out-of-band, so it can overtake audio still sitting in
/// the stdin pipe. That is harmless in practice — a caller signals only after
/// its own VAD has already seen silence, so the audio it races is silence —
/// and it is why the flush is queued through the same stream as the audio
/// rather than acted on inside the signal handler: everything already read is
/// fed to the engine before the flush runs.
enum StreamRun {
    static let supportedRate = 16_000
    /// Audio-time with no transcript growth beyond the engine's own decode
    /// cadence that closes an utterance. The engine only updates partials per
    /// PROCESSED CHUNK (1120 ms en / 2240 ms zh), so the effective window is
    /// chunkMs + this margin — a bare sub-chunk window fires false finals
    /// between decodes (observed on the first bring-up run).
    static let silenceMarginMs = 700
    /// `--endpoint caller`: how long the auto rule waits before finalizing on
    /// its own. Long enough that it never races a signalling caller, short
    /// enough that a caller which dies mid-call still yields its transcript.
    static let callerSafetyNetMs = 8_000
    /// Stdin read granularity: 100 ms of 16 kHz s16le.
    static let readChunkBytes = 3_200

    /// Who decides an utterance is over.
    enum Endpointing: String {
        case auto
        case caller
    }

    static func run(language: String, rate: Int, encoding: String, endpoint: Endpointing) async -> Int32 {
        guard rate == supportedRate else {
            log("only --rate 16000 is supported (got \(rate))")
            return 2
        }
        guard encoding == "s16le" else {
            log("only --encoding s16le is supported (got \(encoding))")
            return 2
        }
        claimStdout()
        if endpoint == .caller {
            // Disarm SIGUSR1 before the (multi-second) model load, not with the
            // rest of the stream setup after it: audio — and therefore the
            // caller's VAD stops — starts flowing the moment we're spawned, and
            // the default disposition for SIGUSR1 is to terminate the process.
            // Nothing consumes the signal until the source below is resumed;
            // ignoring an early flush is correct, since there is no utterance
            // yet to close.
            signal(SIGUSR1, SIG_IGN)
        }
        do {
            let engine: any StreamEngine
            switch language {
            case "en":
                engine = try await NemotronEnEngine.load()
            case "zh":
                engine = try await NemotronMultilingualEngine.load(languageCode: "zh-CN")
            default:
                log("unsupported --language \(language) (supported: en, zh)")
                return 2
            }
            try await pump(engine: engine, endpoint: endpoint)
        } catch {
            log("fatal: \(error)")
            return 1
        }
        return 0
    }

    // MARK: - Core loop, engine-agnostic

    private static func pump(engine: any StreamEngine, endpoint: Endpointing) async throws {
        var lastText = ""
        var stableMs = 0
        let finalizeMs = (endpoint == .caller)
            ? max(callerSafetyNetMs, engine.chunkMs + silenceMarginMs)
            : engine.chunkMs + silenceMarginMs

        for await event in events(endpoint: endpoint) {
            switch event {
            case .flush:
                // The caller's turn detector says the utterance is over. An
                // empty result means it heard speech we didn't (its VAD fires
                // on any voiced audio, the decoder only on words) — emit
                // nothing rather than a blank final.
                let final = try await engine.finishUtterance()
                if !final.isEmpty { emit("final", final) }
                lastText = ""
                stableMs = 0

            case .audio(let samples):
                try await engine.feed(samples)
                let text = engine.partialText()
                let chunkMs = samples.count * 1000 / supportedRate
                if text != lastText {
                    lastText = text
                    stableMs = 0
                    if !text.isEmpty { emit("partial", text) }
                } else if !text.isEmpty {
                    stableMs += chunkMs
                    if stableMs >= finalizeMs {
                        let final = try await engine.finishUtterance()
                        emit("final", final.isEmpty ? text : final)
                        lastText = ""
                        stableMs = 0
                    }
                }
            }
        }
        // EOF: flush whatever is buffered as a last final.
        let tail = try await engine.finishUtterance()
        if !tail.isEmpty { emit("final", tail) }
    }

    // MARK: - Output

    /// The fd the JSON protocol is written to. Not fd 1 — see `claimStdout()`.
    private nonisolated(unsafe) static var jsonFD: Int32 = 1

    /// Take exclusive ownership of the protocol channel.
    ///
    /// CoreML/E5RT writes diagnostics straight to fd 1, below anything Swift
    /// controls — e.g. "E5RT encountered an STL exception… zero shape error",
    /// observed on every run's final decode. The caller parses stdout strictly
    /// (a line that isn't our JSON means the interface contract is broken, so
    /// it fails the call), which makes one stray library line enough to hang up
    /// on someone. So: keep a private duplicate of the real stdout for JSON,
    /// and point fd 1 at stderr, where noise is merely noise.
    private static func claimStdout() {
        let real = dup(1)
        guard real >= 0 else { return }
        dup2(2, 1)
        jsonFD = real
    }

    private static func emit(_ type: String, _ text: String) {
        let obj: [String: String] = ["type": type, "text": text]
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(contentsOf: [UInt8(ascii: "\n")])
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(jsonFD, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return  // pipe closed: the caller is gone, nothing to say
                }
            }
        }
    }

    private static func log(_ s: String) {
        FileHandle.standardError.write(Data("\(programName) --stream: \(s)\n".utf8))
    }

    // MARK: - Input events

    /// What the pump consumes: audio to feed, and (in `--endpoint caller`) the
    /// caller's end-of-utterance signal. Both arrive on one stream so the
    /// single consumer processes them in the order they were produced.
    private enum PumpEvent {
        case audio([Float])
        case flush
    }

    /// The signal source has to outlive `events(...)` or ARC tears it down and
    /// SIGUSR1 goes back to killing the process. One stream per run.
    private nonisolated(unsafe) static var flushSignalSource: DispatchSourceSignal?

    private static func events(endpoint: Endpointing) -> AsyncStream<PumpEvent> {
        AsyncStream { continuation in
            if endpoint == .caller {
                // SIG_IGN first: the default disposition for SIGUSR1 is
                // terminate, and DispatchSource only observes what the default
                // handler no longer consumes.
                signal(SIGUSR1, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: SIGUSR1, queue: .global(qos: .userInitiated))
                source.setEventHandler { continuation.yield(.flush) }
                source.resume()
                flushSignalSource = source
                log("endpoint: caller-driven (send SIGUSR1 to pid \(ProcessInfo.processInfo.processIdentifier) to close an utterance)")
            }
            stdinReader(continuation)
        }
    }

    // MARK: - Stdin

    /// Blocking stdin reader on a background thread feeding the event stream.
    /// EOF closes the stream; the loop then flushes a last final.
    private static func stdinReader(_ continuation: AsyncStream<PumpEvent>.Continuation) {
        Thread {
            let input = FileHandle.standardInput
            while true {
                let data = input.readData(ofLength: readChunkBytes)
                if data.isEmpty { break }
                var floats = [Float](repeating: 0, count: data.count / 2)
                data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let int16s = raw.bindMemory(to: Int16.self)
                    for i in 0..<floats.count {
                        floats[i] = Float(Int16(littleEndian: int16s[i])) / 32768.0
                    }
                }
                continuation.yield(.audio(floats))
            }
            continuation.finish()
        }.start()
    }

    static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(supportedRate),
                channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0], !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in dst.update(from: src.baseAddress!, count: samples.count) }
        }
        return buffer
    }
}

// MARK: - Engine abstraction

/// The tiny surface the pump needs; both managers fit behind it.
protocol StreamEngine: Sendable {
    /// The engine's decode-chunk duration — partials cannot update faster than
    /// this, so the finalize window is computed from it.
    var chunkMs: Int { get }
    /// Append and process one chunk of 16 kHz mono float samples.
    func feed(_ samples: [Float]) async throws
    /// Latest cumulative partial for the current utterance (from the manager's
    /// partial callback; empty when nothing has been decoded yet).
    func partialText() -> String
    /// Decode + clear the current utterance, reset for the next one.
    func finishUtterance() async throws -> String
}

/// Thread-safe latest-partial holder — the managers' callbacks are @Sendable
/// closures that may fire off-actor.
final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func set(_ t: String) {
        lock.lock()
        text = t
        lock.unlock()
    }
    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
    func clear() { set("") }
}

// MARK: - English

final class NemotronEnEngine: StreamEngine, @unchecked Sendable {
    let chunkMs = 1120
    private let manager: StreamingNemotronAsrManager
    private let box = PartialBox()

    private init(manager: StreamingNemotronAsrManager) {
        self.manager = manager
    }

    static func load() async throws -> NemotronEnEngine {
        FileHandle.standardError.write(
            Data("\(programName) --stream: loading Nemotron streaming (en, 1120 ms chunks; downloads on first run)…\n".utf8))
        // ms1120 — the trained chunk and the app's own choice. The ms560 tier
        // failed CoreML load on this machine (MIL "zero shape" at E5RT compile,
        // 2026-08-08); do not lower without re-verifying on-device.
        let manager = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        try await manager.loadModels()
        let engine = NemotronEnEngine(manager: manager)
        await manager.setPartialCallback { [box = engine.box] text in box.set(text) }
        FileHandle.standardError.write(Data("\(programName) --stream: ready (en)\n".utf8))
        return engine
    }

    func feed(_ samples: [Float]) async throws {
        guard let buffer = StreamRun.pcmBuffer(samples) else { return }
        _ = try await manager.process(audioBuffer: buffer)
    }

    func partialText() -> String {
        box.get().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finishUtterance() async throws -> String {
        let text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        await manager.reset()
        box.clear()
        return text
    }
}

// MARK: - Mandarin (multilingual manager, language pinned)

final class NemotronMultilingualEngine: StreamEngine, @unchecked Sendable {
    let chunkMs = 2240
    private let manager: StreamingNemotronMultilingualAsrManager
    private let box = PartialBox()

    private init(manager: StreamingNemotronMultilingualAsrManager) {
        self.manager = manager
    }

    static func load(languageCode: String) async throws -> NemotronMultilingualEngine {
        FileHandle.standardError.write(
            Data("\(programName) --stream: loading Nemotron multilingual streaming (\(languageCode); downloads on first run)…\n".utf8))
        let variantDir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: languageCode)
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: variantDir)
        // Pin the language: auto-detect per chunk is off — a call must not
        // free-associate into another language mid-utterance (same reasoning
        // as the app's dictation wrapper).
        await manager.setLanguage(languageCode)
        let engine = NemotronMultilingualEngine(manager: manager)
        await manager.setPartialCallback { [box = engine.box] text in box.set(text) }
        FileHandle.standardError.write(Data("\(programName) --stream: ready (\(languageCode))\n".utf8))
        return engine
    }

    func feed(_ samples: [Float]) async throws {
        _ = try await manager.process(samples: samples)
    }

    func partialText() -> String {
        box.get().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finishUtterance() async throws -> String {
        let text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        await manager.reset()
        box.clear()
        return text
    }
}
