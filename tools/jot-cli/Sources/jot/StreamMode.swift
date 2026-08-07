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

        func process(_ buffer: AVAudioPCMBuffer) async throws {
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
    /// revised. If a revision is ever observed, we warn ONCE on stderr and
    /// resynchronize by adopting the new hypothesis wholesale (the divergent
    /// tail is dropped rather than emitted as garbled overlap; already-printed
    /// text cannot be retracted in a finals-only protocol).
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
                resynchronize(to: partial)
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
        func finishSession(finalText: String) {
            lock.lock()
            defer { lock.unlock() }
            if finalText.hasPrefix(emitted) {
                let tailStart = finalText.index(finalText.startIndex, offsetBy: emitted.count)
                commit(String(finalText[tailStart...]))
                emitted = finalText
            } else {
                warnRevisionOnce()
                // Conservative: emit nothing rather than re-emit overlapping
                // text the consumer already committed to.
            }
        }

        private func commit(_ segment: String) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let corrected = vocab?.correct(trimmed) ?? trimmed
            NDJSON.emitFinal(corrected)
        }

        private func resynchronize(to partial: String) {
            warnRevisionOnce()
            emitted = partial
        }

        private func warnRevisionOnce() {
            guard !warnedRevision else { return }
            warnedRevision = true
            FileHandle.standardError.write(Data(
                "jot: warning: engine revised committed text (append-only assumption violated — see design R11); resynchronized, some words may be dropped\n"
                    .utf8))
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

        // SIGINT finalizes exactly like EOF: flush the engine, emit the tail,
        // exit 0. Guarded so a second Ctrl-C during finalization is ignored
        // (the default disposition would kill us mid-flush).
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            Task { await finalize(engine: engine, emitter: emitter) }
        }
        sigintSource.resume()

        let reader = StdinAudioReader(encoding: options.encoding)
        for await samples in reader.chunks() {
            guard let buffer = makeBuffer(samples) else {
                fail("internal error: could not create audio buffer (\(samples.count) samples)")
            }
            do {
                try await engine.process(buffer)
            } catch {
                // FAIL LOUDLY (requirement 7): no log-and-continue, no
                // degraded deaf agent. Crash; the caller handles a dead process.
                fail("streaming transcription failed: \(error)")
            }
        }

        await finalize(engine: engine, emitter: emitter)
    }

    // Once-guard for the two finalize entry points (EOF and SIGINT); both run
    // on the main actor's task tree, so plain state is race-free in practice
    // and the worst case is a benign double-finish the engine rejects.
    nonisolated(unsafe) private static var finalizing = false

    private static func finalize(engine: Engine, emitter: FinalEmitter) async -> Never {
        // Best-effort once-guard; both call sites hop through the main actor
        // hierarchy so a race is a benign double-finish attempt that the
        // engine rejects, not corruption.
        if finalizing { exit(0) }
        finalizing = true
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
