import FluidAudio
import Foundation

/// Streams the CTC keyword-spotter's expensive log-prob computation ACROSS the
/// recording instead of one-shotting it after stop, so the 2–3 s spotter pass
/// is mostly done by the time the user stops talking.
///
/// FluidAudio's `spotKeywordsWithLogProbs` is one-shot, but its internal
/// `computeLogProbsChunked` processes audio in **independent** 15 s chunks
/// (`maxModelSamples`) with a 2 s overlap (`chunkOverlapSamples`), concatenating
/// per-chunk log-probs with a log-sum-exp overlap average. We replicate that
/// exact chunking here using only PUBLIC FluidAudio API:
///   - per chunk → `spotKeywordsWithLogProbs(chunk)` exposes `.logProbs` +
///     `.frameDuration` (we discard its detections),
///   - at stop → `spotKeywordsFromLogProbs(accumulated)` runs the cheap DP.
/// Because the chunk boundaries + overlap merge match FluidAudio exactly, the
/// final log-probs (and thus detections) are **identical** to the one-shot —
/// for clips under 15 s it's literally a single chunk, i.e. the same call. The
/// only difference is *when* the heavy chunks run: during recording, not after.
///
/// A `class` with a lock-based continuation (mirroring
/// `NemotronStreamingTranscriber`) so `enqueue` never hops an actor on the
/// audio thread; the consumer task serializes chunk processing in order.
final class StreamingCtcSpotter: @unchecked Sendable {

    // FluidAudio chunking constants (public: ASRConstants / CtcKeywordSpotter).
    private static let chunkSize = ASRConstants.maxModelSamples       // 240_000 (15 s @ 16 kHz)
    private static let overlapSamples = 32_000                        // 2 s
    private static var stride: Int { chunkSize - overlapSamples }     // 208_000

    private let spotter: CtcKeywordSpotter
    private let vocabulary: CustomVocabularyContext
    private let log = ErrorLog.shared

    private let box = CtcContinuationBox()
    private var consumerTask: Task<Void, Never>?

    // Consumer-owned state (only touched inside `consumerTask`).
    private var buffer: [Float] = []
    private var nextChunkStart = 0
    private var accumulated: [[Float]] = []
    private var frameDuration: Double = 0
    /// True if any chunk inference threw — finish() then falls back to a clean
    /// one-shot so a streaming bug can never corrupt detections.
    private var failed = false

    init(spotter: CtcKeywordSpotter, vocabulary: CustomVocabularyContext) {
        self.spotter = spotter
        self.vocabulary = vocabulary
    }

    /// Begin consuming. Call once before the first `enqueue`.
    func begin() {
        var holder: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { holder = $0 }
        box.set(holder)
        consumerTask = Task.detached { [weak self] in
            guard let self else { return }
            for await samples in stream {
                if Task.isCancelled { break }
                await self.ingest(samples)
            }
        }
    }

    /// Feed audio (16 kHz mono). Safe to call from the audio thread — no await.
    nonisolated func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        box.yield(samples)
    }

    /// Stop, process the final (partial) chunk, and run the cheap keyword DP.
    /// Returns the same `SpotPayload` the one-shot would, or `nil` if streaming
    /// failed (caller falls back to the one-shot `spotDetections`).
    func finish() async -> VocabularyRescorerHolder.SpotPayload? {
        box.finish()
        await drainConsumer()
        if failed { return nil }

        // Final chunk: [nextChunkStart, end] — mirrors computeLogProbsChunked's
        // terminating chunk (end >= total). Skip only if the last full chunk
        // already reached the end.
        if nextChunkStart < buffer.count {
            let tail = Array(buffer[nextChunkStart..<buffer.count])
            do {
                try await processChunk(tail, isFirst: accumulated.isEmpty)
            } catch {
                await log.warn(
                    component: "StreamingCtcSpotter",
                    message: "final chunk failed; falling back to one-shot",
                    context: ["error": ErrorLog.redactedAppleError(error)])
                return nil
            }
        }

        guard !accumulated.isEmpty, frameDuration > 0 else {
            // No usable frames (e.g. empty/too-short audio) — treat as no
            // detections rather than forcing a redundant one-shot.
            return VocabularyRescorerHolder.SpotPayload(
                detections: [],
                totalAudioDuration: TimeInterval(buffer.count) / 16_000)
        }

        let result = spotter.spotKeywordsFromLogProbs(
            logProbs: accumulated,
            frameDuration: frameDuration,
            customVocabulary: vocabulary,
            minScore: nil)
        return VocabularyRescorerHolder.makeSpotPayload(
            spotResult: result,
            vocabulary: vocabulary,
            totalSamples: buffer.count)
    }

    func cancel() {
        box.finish()
        consumerTask?.cancel()
        consumerTask = nil
    }

    // MARK: - Consumer

    private func ingest(_ samples: [Float]) async {
        guard !failed else { return }
        buffer.append(contentsOf: samples)
        // Process every full, NON-final chunk that's now available. A chunk is
        // safe to process the moment `chunkSize` samples past its start exist;
        // the terminating (possibly-partial) chunk is handled in `finish()`.
        while buffer.count >= nextChunkStart + Self.chunkSize {
            let chunk = Array(buffer[nextChunkStart..<(nextChunkStart + Self.chunkSize)])
            do {
                try await processChunk(chunk, isFirst: accumulated.isEmpty)
            } catch {
                failed = true
                await log.warn(
                    component: "StreamingCtcSpotter",
                    message: "chunk failed; will fall back to one-shot at finish",
                    context: ["error": ErrorLog.redactedAppleError(error)])
                return
            }
            nextChunkStart += Self.stride
        }
    }

    /// Run one chunk through the spotter for its log-probs and merge into the
    /// accumulator with FluidAudio's overlap log-sum-exp average.
    private func processChunk(_ chunk: [Float], isFirst: Bool) async throws {
        let r = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: chunk, customVocabulary: vocabulary, minScore: nil)
        let logProbs = r.logProbs
        guard !logProbs.isEmpty else { return }
        if frameDuration == 0 { frameDuration = r.frameDuration }

        if isFirst || accumulated.isEmpty {
            accumulated.append(contentsOf: logProbs)
            return
        }
        let overlapFrames = frameDuration > 0
            ? Int(Double(Self.overlapSamples) / 16_000 / frameDuration) : 0
        let overlapCount = min(overlapFrames, accumulated.count, logProbs.count)
        if overlapCount > 0 {
            let base = accumulated.count - overlapCount
            for i in 0..<overlapCount {
                accumulated[base + i] = Self.mergeOverlapFrame(
                    existing: accumulated[base + i], incoming: logProbs[i])
            }
        }
        if overlapCount < logProbs.count {
            accumulated.append(contentsOf: logProbs.suffix(from: overlapCount))
        }
    }

    /// Verbatim port of FluidAudio's `mergeOverlapFrame` (log-sum-exp average).
    private static func mergeOverlapFrame(existing: [Float], incoming: [Float]) -> [Float] {
        let v = min(existing.count, incoming.count)
        if v == 0 { return existing }
        let log2: Float = 0.69314718
        var out = [Float](repeating: 0, count: v)
        for j in 0..<v {
            let a = existing[j], b = incoming[j]
            let m = max(a, b)
            out[j] = m == -Float.infinity ? -Float.infinity
                : m + logf(expf(a - m) + expf(b - m)) - log2
        }
        return out
    }

    private func drainConsumer() async {
        guard let task = consumerTask else { return }
        consumerTask = nil
        await task.value
    }
}

private final class CtcContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?
    func set(_ c: AsyncStream<[Float]>.Continuation?) {
        lock.lock(); let prev = continuation; continuation = c; lock.unlock(); prev?.finish()
    }
    func yield(_ samples: [Float]) {
        lock.lock(); let c = continuation; lock.unlock(); c?.yield(samples)
    }
    func finish() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.finish()
    }
}
