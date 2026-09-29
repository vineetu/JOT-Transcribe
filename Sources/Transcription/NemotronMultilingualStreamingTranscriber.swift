import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import JotVocabCore

/// One canonical vocabulary term and its decode-time bias weight (the base
/// `vocabularyBiasWeight`, or the learned strength once the user has corrected
/// toward it — learn from edits, D5).
struct NemotronBiasTerm: Equatable, Sendable {
    let text: String
    let weight: Float
}

/// **Pair-targeted learned bias.** Hands the store's learned `(original → term)`
/// pairs to the fork's `setLearnedPairs(_:)`, which pushes the term only where
/// the decoder is spelling the original (see
/// docs/vocabulary-learn-from-edits/design.md).
enum NemotronLearnedPairsBridge {
    static func apply(
        _ pairs: [CorrectionStore.LearnedPair],
        to manager: StreamingNemotronMultilingualAsrManager
    ) async {
        await manager.setLearnedPairs(
            pairs.map { NemotronLearnedPair(original: $0.original, term: $0.term) })
    }
}

/// Actor wrapping FluidAudio's `StreamingNemotronMultilingualAsrManager`
/// (Nemotron 3.5 Multilingual 0.6B). The multilingual sibling of
/// `NemotronStreamingTranscriber`: same streaming control flow, but the
/// manager takes a per-language prompt selected via `setLanguage(_:)` after
/// load, and the on-disk bundle is a `latin/<chunkMs>ms` or
/// `multilingual/<chunkMs>ms` variant (FluidAudio's `languageDirectory(for:)`
/// routes en/es/fr/it/pt/de → "latin", everything else → "multilingual").
///
/// `bundleDirectory` is the resolved variant directory (the value
/// `StreamingNemotronMultilingualAsrManager.downloadVariant(...)` returns and
/// `ModelCache` mirrors). `languageCode` is the FluidAudio language hint
/// (e.g. `"en-US"`, `"es-ES"`, `"ko-KR"`); `nil` lets the model auto-detect.
final actor NemotronMultilingualStreamingTranscriber: NemotronStreamingEngine {

    private var manager: StreamingNemotronMultilingualAsrManager?
    /// Single-flight load. Every caller — the launch prewarm / integrity
    /// probe, the session consumer, the one-shot — awaits this ONE task, so
    /// the actor never builds a second manager. (Awaiting the load before
    /// assigning `manager` let the prewarm and the first session's consumer
    /// each build one: audio fed one, `finish()` read the other → empty or
    /// partial text.) A model switch builds a new actor; this one's manager
    /// is released with it.
    private var loadTask: Task<StreamingNemotronMultilingualAsrManager, Error>?
    private let bundleDirectory: URL
    private let languageCode: String?
    private var activeGeneration: UInt64?
    private let continuationBox = NemotronMultilingualContinuationBox()
    private var consumerTask: Task<Result<NemotronStreamedFinal, Error>, Never>?
    /// The last work that drove `manager` (a session consumer or a one-shot).
    /// The next one awaits it before its own `reset()`, so work on the shared
    /// manager is strictly ordered: a cancelled session's in-flight chunk can
    /// never land inside the next session.
    private var managerTail: Task<Void, Never>?
    /// The user's vocabulary (canonical spellings only, each with its bias
    /// weight; empty when boosting is off), read at each session boundary for
    /// decode-time bias.
    private let vocabularyProvider: (@Sendable () async -> [NemotronBiasTerm])?
    /// Learned `(original → term)` pairs from transcript edits, for
    /// pair-targeted bias (see `NemotronLearnedPairsBridge`).
    private let learnedPairsProvider: (@Sendable () async -> [CorrectionStore.LearnedPair])?
    /// The terms + weights last handed to the manager, so an unchanged
    /// vocabulary is not re-tokenized every session. Compared as (term,
    /// weight) — a weight-only change (a learned term) must still re-apply.
    private var appliedVocabulary: [NemotronBiasTerm] = []
    private var appliedPairs: [CorrectionStore.LearnedPair] = []

    /// Bias bonus for a vocabulary term's first token (continuations get
    /// 1.5× inside FluidAudio). Chosen on the public LibriSpeech rare-word
    /// biasing benchmark (docs/plans/vocabulary-evidence-and-decode-bias.md).
    static let vocabularyBiasWeight: Float = 3.5

    init(
        bundleDirectory: URL,
        languageCode: String?,
        vocabularyProvider: (@Sendable () async -> [NemotronBiasTerm])? = nil,
        learnedPairsProvider: (@Sendable () async -> [CorrectionStore.LearnedPair])? = nil
    ) {
        self.bundleDirectory = bundleDirectory
        self.languageCode = languageCode
        self.vocabularyProvider = vocabularyProvider
        self.learnedPairsProvider = learnedPairsProvider
    }

    /// Apply the current vocabulary to the manager. Called only between
    /// utterances (right after `reset()`), never mid-decode: FluidAudio drops
    /// an open speculation's bookkeeping on a vocabulary change.
    private func applyVocabulary(to manager: StreamingNemotronMultilingualAsrManager) async {
        guard let vocabularyProvider else { return }
        let terms = await vocabularyProvider()
        let vocabularyChanged = terms != appliedVocabulary
        if vocabularyChanged {
            appliedVocabulary = terms
            await manager.setCustomVocabulary(
                terms.map { CustomVocabularyTerm(text: $0.text, weight: $0.weight) }
            )
        }
        // Pairs after the terms they point at; re-sent on any vocabulary
        // change so a re-tokenized term list never leaves them stale.
        guard let learnedPairsProvider else { return }
        let pairs = await learnedPairsProvider()
        guard vocabularyChanged || pairs != appliedPairs else { return }
        appliedPairs = pairs
        await NemotronLearnedPairsBridge.apply(pairs, to: manager)
    }

    var isReady: Bool { manager != nil }

    func ensureLoaded() async throws {
        _ = try await loadedManager()
    }

    private func loadedManager() async throws -> StreamingNemotronMultilingualAsrManager {
        if let manager { return manager }
        let task: Task<StreamingNemotronMultilingualAsrManager, Error>
        if let loadTask {
            task = loadTask
        } else {
            let directory = bundleDirectory
            let languageCode = languageCode
            task = Task.detached {
                let config = MLModelConfiguration()
                config.computeUnits = .cpuAndNeuralEngine
                let mgr = StreamingNemotronMultilingualAsrManager(configuration: config)
                try await mgr.loadModels(from: directory)
                // Pin the language prompt once at load; the model otherwise
                // auto-detects per chunk, which the design avoids (a hard
                // language hint keeps a short dictation from free-associating
                // into another language mid-utterance).
                if let languageCode {
                    await mgr.setLanguage(languageCode)
                }
                return mgr
            }
            loadTask = task
        }
        do {
            let mgr = try await task.value
            manager = mgr
            return mgr
        } catch {
            // Forget only this failed attempt so the next caller (e.g. the
            // self-heal after a re-download) retries instead of replaying it.
            if loadTask == task { loadTask = nil }
            throw error
        }
    }

    func start(
        generation: UInt64,
        onPartial: @escaping @Sendable (String, UInt64) -> Void
    ) {
        activeGeneration = generation

        var holder: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { c in
            holder = c
        }
        continuationBox.set(holder)

        // The consumer owns the whole session on the manager: load, reset,
        // decode every chunk, then flush with `finish()`. Chunks captured
        // while it waits (for the load, or for the previous user of the
        // manager) accumulate in the unbounded stream, so the head is kept.
        let previous = managerTail
        let consumer = Task.detached { [weak self] () -> Result<NemotronStreamedFinal, Error> in
            await previous?.value
            guard let self else { return .failure(NemotronStreamingFailure.noSession) }
            let mgr: StreamingNemotronMultilingualAsrManager
            do {
                mgr = try await self.loadedManager()
            } catch {
                await ErrorLog.shared.error(
                    component: "NemotronMultilingualStreamingTranscriber",
                    message: "ensureLoaded failed in consumer (skipping partials)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
                return .failure(NemotronStreamingFailure.loadFailed)
            }

            await mgr.reset()
            await self.applyVocabulary(to: mgr)
            await mgr.setPartialCallback { partial in
                // Scrub tokenizer `<unk>` artifacts so the live pill never
                // flashes "25<unk>" mid-dictation (the final transcript is
                // scrubbed separately in `DualPipelineTranscriber` /
                // `Transcriber`). Cheap: a no-op `contains` check per partial
                // on the artifact-free fast path.
                onPartial(PostProcessing.scrubModelArtifacts(partial), generation)
            }

            var decodedSamples = 0
            var processFailed = false
            for await samples in stream {
                if Task.isCancelled { break }
                guard !samples.isEmpty,
                      let buffer = Self.makeBuffer(samples)
                else { continue }
                do {
                    _ = try await mgr.process(audioBuffer: buffer)
                    decodedSamples += samples.count
                } catch {
                    // `cancel()` interrupts the chunk in flight; that's the
                    // session ending, not a decode failure.
                    if Task.isCancelled { break }
                    processFailed = true
                    await ErrorLog.shared.error(
                        component: "NemotronMultilingualStreamingTranscriber",
                        message: "process failed",
                        context: ["error": ErrorLog.redactedAppleError(error)]
                    )
                }
            }
            if Task.isCancelled { return .failure(NemotronStreamingFailure.cancelled) }
            if processFailed { return .failure(NemotronStreamingFailure.processFailed) }
            do {
                let (text, timings) = try await mgr.finishWithTokenTimings()
                return .success(NemotronStreamedFinal(
                    text: text,
                    generation: generation,
                    decodedSampleCount: decodedSamples,
                    tokenTimings: timings
                ))
            } catch {
                return .failure(error)
            }
        }
        consumerTask = consumer
        managerTail = Task.detached { _ = await consumer.value }
    }

    nonisolated func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuationBox.yield(samples)
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

    /// Ends the session and returns what the stream decoded. Closing the
    /// stream lets the consumer drain the whole backlog and flush; this waits
    /// for exactly that, with no timeout, so the text covers every chunk that
    /// was enqueued. The consumer stays registered while it drains so a
    /// `cancel()` (user cancel, or the pipeline's stop watchdog abandoning a
    /// hung drain) can still end it.
    func finish() async throws -> NemotronStreamedFinal {
        continuationBox.finish()
        guard let generation = activeGeneration, let consumer = consumerTask else {
            throw NemotronStreamingFailure.noSession
        }
        let outcome = await consumer.value
        if consumerTask == consumer { consumerTask = nil }
        if activeGeneration == generation { activeGeneration = nil }
        return try outcome.get()
    }

    /// One-shot decode for paths without a live recording session feeding
    /// this actor (file import, Library re-transcribe, segment slicing, and
    /// the fallback when a live session could not supply its final). Mirrors
    /// the English Nemotron path: one buffer through `process` + `finish`.
    func transcribeOneShot(_ samples: [Float]) async throws -> String {
        try await transcribeOneShotWithTimings(samples).text
    }

    func transcribeOneShotWithTimings(_ samples: [Float]) async throws -> NemotronDecode {
        // Refuse while a live session owns the manager: a one-shot's
        // `reset()` + `process()` + `finish()` would cross-contaminate the
        // dictation's decoder state (it could paste empty/garbled text
        // SILENTLY). `activeGeneration` is non-nil from `start(...)` until
        // `finish()`/`cancel()` completes, and the recorder's stop path
        // awaits `finishStreaming()` before any fallback one-shot, so the
        // live dictation's own fallback can never trip this. Mirrors the
        // guard in `NemotronStreamingTranscriber.transcribeOneShot`. `.busy` is
        // already salvageable in `FileTranscriptionIngest` (import parks as
        // `.savedPending` and auto-recovers) and surfaces as a normal alert on
        // re-transcribe.
        guard activeGeneration == nil, consumerTask == nil else {
            throw TranscriberError.busy
        }
        let previous = managerTail
        let work = Task { () async throws -> NemotronDecode in
            await previous?.value
            let manager = try await self.loadedManager()
            await manager.reset()
            await self.applyVocabulary(to: manager)
            guard !samples.isEmpty else {
                throw TranscriberError.fluidAudio(
                    NSError(domain: "Jot.NemotronMultilingualStreamingTranscriber", code: -1)
                )
            }
            // Feed in whole-chunk slices and check for cancellation between
            // them, so a cancelled import (or re-transcribe) stops within one
            // slice instead of holding the manager — and any dictation queued
            // behind it on `managerTail` — for the whole decode. The manager
            // buffers across `process` calls, so slicing doesn't change the
            // output.
            var start = 0
            while start < samples.count {
                try Task.checkCancellation()
                let end = min(start + Self.oneShotSliceSamples, samples.count)
                guard let buffer = Self.makeBuffer(Array(samples[start..<end])) else {
                    throw TranscriberError.fluidAudio(
                        NSError(domain: "Jot.NemotronMultilingualStreamingTranscriber", code: -1)
                    )
                }
                _ = try await manager.process(audioBuffer: buffer)
                start = end
            }
            try Task.checkCancellation()
            let (text, timings) = try await manager.finishWithTokenTimings()
            return NemotronDecode(text: text, tokenTimings: timings)
        }
        managerTail = Task.detached { _ = try? await work.value }
        // `work` is unstructured, so forward the caller's cancellation to it.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// One-shot slice: 16 × the 1.12 s streaming chunk (~18 s of audio,
    /// ~0.4 s to decode), which bounds how long a cancelled one-shot keeps
    /// the manager.
    private static let oneShotSliceSamples = 17_920 * 16

    /// Abandons the session. There is deliberately no reset here: a
    /// fire-and-forget reset could land after the next session started and
    /// wipe its first tokens. The next consumer or one-shot awaits
    /// `managerTail` (which includes this cancelled consumer) and resets the
    /// manager itself, in order, before decoding.
    func cancel(generation: UInt64) async {
        guard activeGeneration == generation else { return }
        continuationBox.finish()
        consumerTask?.cancel()
        consumerTask = nil
        activeGeneration = nil
    }
}

private final class NemotronMultilingualContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?

    func set(_ c: AsyncStream<[Float]>.Continuation?) {
        lock.lock()
        let prev = continuation
        continuation = c
        lock.unlock()
        prev?.finish()
    }

    func yield(_ samples: [Float]) {
        lock.lock()
        let c = continuation
        lock.unlock()
        c?.yield(samples)
    }

    func finish() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.finish()
    }
}
