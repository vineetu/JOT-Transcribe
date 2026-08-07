import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// `jot --stream` — the machine streaming mode (design doc §15).
///
/// Raw PCM on stdin → NDJSON finals on stdout. Nemotron 3.5 streaming only
/// (English or Multilingual ship by `--language`). Finals are derived from
/// Nemotron's append-only partial hypothesis: each stable extension is
/// committed as soon as it lands, held back only to the last whitespace
/// boundary so a token in progress is never split across two finals.
///
/// Error philosophy is the INVERSE of the app's wrappers: any engine error is
/// fatal (stderr + non-zero exit). A silently deaf agent is the worst failure
/// mode; a dead process is detected and handled by the caller (requirement 7).
enum StreamMode {

    struct Options {
        var language: CLILanguage
        var encoding: PCMEncoding
        var modelDirOverride: String?
        var vocab: VocabularyApplier?
    }

    // MARK: - Engine seam

    /// Both FluidAudio streaming managers expose the identical control
    /// surface (`reset` / `setPartialCallback` / `process` / `finish`); this
    /// tiny seam lets one run loop drive either. It is the CLI-local stand-in
    /// for the app's `NemotronStreamingEngine` protocol until the JotEngine
    /// extraction (design §9) gives both binaries one shared wrapper.
    private enum Engine {
        case english(StreamingNemotronAsrManager)
        case multilingual(StreamingNemotronMultilingualAsrManager)

        static func make(
            options: Options, bundleDir: URL, useMultilingualManager: Bool
        ) async throws -> Engine {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            if useMultilingualManager {
                let mgr = StreamingNemotronMultilingualAsrManager(configuration: config)
                try await mgr.loadModels(from: bundleDir)
                await mgr.setLanguage(options.language.nemotronCode)
                await mgr.reset()
                return .multilingual(mgr)
            } else {
                let mgr = StreamingNemotronAsrManager(
                    configuration: config, requestedChunkSize: .ms1120)
                try await mgr.loadModels(from: bundleDir)
                await mgr.reset()
                return .english(mgr)
            }
        }

        func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {
            switch self {
            case .english(let mgr): await mgr.setPartialCallback(callback)
            case .multilingual(let mgr): await mgr.setPartialCallback(callback)
            }
        }

        /// `sending`: the buffer is created fresh per call in `run` and never
        /// touched after; the keyword lets region analysis transfer it into
        /// the manager actor (the app creates its buffer in the same scope as
        /// the process call, so it never needed the annotation — this seam
        /// does).
        func process(_ buffer: sending AVAudioPCMBuffer) async throws {
            switch self {
            case .english(let mgr): _ = try await mgr.process(audioBuffer: buffer)
            case .multilingual(let mgr): _ = try await mgr.process(audioBuffer: buffer)
            }
        }

        func finish() async throws -> String {
            switch self {
            case .english(let mgr): return try await mgr.finish()
            case .multilingual(let mgr): return try await mgr.finish()
            }
        }
    }

    // MARK: - Final derivation

    /// Turns the cumulative partial hypothesis into committed NDJSON finals.
    ///
    /// Invariant this rides on (design §17 R11, asserted by the owner and to
    /// be verified against FluidAudio 0.15.4): Nemotron partials are
    /// APPEND-ONLY — the hypothesis only ever grows, committed text is never
    /// revised. If a revision is ever observed we warn ONCE on stderr and
    /// recover conservatively (see the per-site comments); already-printed
    /// text cannot be retracted in a finals-only protocol.
    ///
    /// Lock-based `@unchecked Sendable` because the partial callback arrives
    /// on FluidAudio's internal executor while EOF finalization runs on the
    /// main task — the same shape as the app's continuation boxes.
    final class FinalEmitter: @unchecked Sendable {
        private let lock = NSLock()
        /// The prefix of the cumulative hypothesis already written to stdout.
        private var emitted = ""
        private var warnedRevision = false
        private let vocab: VocabularyApplier?

        init(vocab: VocabularyApplier?) {
            self.vocab = vocab
        }

        func acceptPartial(_ partial: String) {
            lock.lock()
            defer { lock.unlock() }
            guard partial.hasPrefix(emitted) else {
                // Mid-stream revision: adopt the new hypothesis wholesale.
                // The divergent tail is dropped rather than emitted as
                // garbled overlap.
                warnRevisionOnce()
                emitted = partial
                return
            }
            // Hold back the trailing in-progress token: only commit through
            // the last whitespace so a word is never split across finals.
            let pendingStart = partial.index(partial.startIndex, offsetBy: emitted.count)
            let pending = partial[pendingStart...]
            guard let boundary = pending.lastIndex(where: { $0.isWhitespace }) else { return }
            commit(String(pending[..<boundary]))
            emitted = String(partial[..<partial.index(after: boundary)])
        }

        /// EOF/SIGINT: `finish()` returned the whole-session transcript —
        /// emit whatever it carries beyond the committed prefix.
        ///
        /// `emitted` always ends at a committed whitespace boundary, and the
        /// engine's final text typically does NOT carry that trailing
        /// whitespace — so the prefix comparison runs on the right-trimmed
        /// committed prefix (verified by simulation: without this, every
        /// clean session ends in a spurious revision warning).
        ///
        /// If `finish()` diverges INSIDE committed text (re-casing or
        /// re-punctuating the transcript), the tail beyond the committed
        /// length is still emitted, snapped back to the previous word
        /// boundary — bounded duplication of at most one word beats silently
        /// losing the call's last utterance (review finding: the flush is the
        /// whole point of finalization).
        func finishSession(finalText: String) {
            lock.lock()
            defer { lock.unlock() }
            var base = emitted
            while let last = base.last, last.isWhitespace { base.removeLast() }

            if finalText.hasPrefix(base) {
                let tailStart = finalText.index(finalText.startIndex, offsetBy: base.count)
                commit(String(finalText[tailStart...]))
            } else {
                warnRevisionOnce()
                guard finalText.count > base.count else {
                    emitted = finalText
                    return
                }
                var start = finalText.index(finalText.startIndex, offsetBy: base.count)
                while start > finalText.startIndex {
                    let prev = finalText.index(before: start)
                    if finalText[prev].isWhitespace { break }
                    start = prev
                }
                commit(String(finalText[start...]))
            }
            emitted = finalText
        }

        private func commit(_ segment: String) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let corrected = vocab?.correct(trimmed) ?? trimmed
            NDJSON.emitFinal(corrected)
        }

        private func warnRevisionOnce() {
            guard !warnedRevision else { return }
            warnedRevision = true
            FileHandle.standardError.write(Data(
                "jot: warning: engine revised committed text (append-only assumption violated — see design R11); recovered conservatively, adjacent words may repeat or drop\n"
                    .utf8))
        }
    }

    // MARK: - Shutdown coordination

    /// One gate shared by the stdin loop, EOF finalization, and the SIGINT
    /// handler. `requestStop` makes the read loop bail at the next chunk;
    /// `beginFinalize` is an atomic check-and-set so exactly one entry point
    /// flushes the engine — the loser parks until the winner exits the
    /// process (review finding: an `exit(0)` on second entry truncates the
    /// winner's tail write mid-flush).
    private final class ShutdownGate: @unchecked Sendable {
        private let lock = NSLock()
        private var stopRequested = false
        private var finalizing = false

        func requestStop() {
            lock.lock()
            stopRequested = true
            lock.unlock()
        }

        var shouldStop: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopRequested
        }

        /// Returns true exactly once, for the caller that owns finalization.
        func beginFinalize() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finalizing { return false }
            finalizing = true
            stopRequested = true
            return true
        }
    }

    // MARK: - Run loop

    static func run(_ options: Options) async -> Never {
        let root = ModelPaths.parakeetRoot(override: options.modelDirOverride)
        let fm = FileManager.default

        // Resolve which on-disk ship serves this stream. English prefers the
        // dedicated English bundle but falls back to the Multilingual "latin"
        // ship — the app folds English into that ship on Nemotron-eligible
        // Macs, so an English user may have latin-only on disk. Other latin
        // languages use the latin ship; everything else the full multilingual
        // ship. `useMultilingualManager` decides which FluidAudio manager
        // loads the resolved directory.
        let englishDir = ModelPaths.nemotronEnglishStreamingDir(root: root)
        let variantDir = ModelPaths.nemotronMultilingualDir(
            root: root, latin: options.language.usesLatinNemotronVariant)
        let bundleDir: URL
        let useMultilingualManager: Bool
        if options.language.isEnglish, fm.fileExists(atPath: englishDir.path) {
            bundleDir = englishDir
            useMultilingualManager = false
        } else if fm.fileExists(atPath: variantDir.path) {
            bundleDir = variantDir
            useMultilingualManager = true
        } else {
            fail("""
                streaming model not found (looked for \(options.language.isEnglish ? englishDir.path + " and " : "")\(variantDir.path)).
                Open Jot and complete setup (Settings → Transcription) to download it, then retry.
                """)
        }

        let engine: Engine
        do {
            engine = try await Engine.make(
                options: options, bundleDir: bundleDir,
                useMultilingualManager: useMultilingualManager)
        } catch {
            fail("failed to load streaming model from \(bundleDir.path): \(error)")
        }

        let emitter = FinalEmitter(vocab: options.vocab)
        await engine.setPartialCallback { partial in
            emitter.acceptPartial(partial)
        }

        // SIGINT finalizes exactly like EOF: stop the loop, flush the engine,
        // emit the tail, exit 0. A second Ctrl-C parks behind the gate while
        // the first finalization completes.
        let gate = ShutdownGate()
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            gate.requestStop()
            Task { await finalize(engine: engine, emitter: emitter, gate: gate) }
        }
        sigintSource.resume()

        let reader = StdinAudioReader(encoding: options.encoding)
        for await samples in reader.chunks() {
            if gate.shouldStop { break }
            guard let buffer = makeBuffer(samples) else {
                fail("internal error: could not create audio buffer (\(samples.count) samples)")
            }
            do {
                try await engine.process(buffer)
            } catch {
                // A process error AFTER finalization began belongs to the
                // shutdown path, not to us — don't let it flip the exit code.
                if gate.shouldStop { break }
                // FAIL LOUDLY (requirement 7): no log-and-continue, no
                // degraded deaf agent. Crash; the caller handles a dead process.
                fail("streaming transcription failed: \(error)")
            }
        }

        await finalize(engine: engine, emitter: emitter, gate: gate)
    }

    private static func finalize(
        engine: Engine, emitter: FinalEmitter, gate: ShutdownGate
    ) async -> Never {
        guard gate.beginFinalize() else {
            // Another entry point owns the flush; park until it exits the
            // process. Exiting here would truncate its tail write.
            while true {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        do {
            let finalText = try await engine.finish()
            emitter.finishSession(finalText: finalText)
        } catch {
            fail("failed to finalize stream: \(error)")
        }
        exit(0)
    }

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
                standardFormatWithSampleRate: 16_000,
                channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let dst = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                dst.update(from: base, count: samples.count)
            }
        }
        return buffer
    }
}
