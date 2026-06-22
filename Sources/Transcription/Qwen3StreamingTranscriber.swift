import FluidAudio
import Foundation

/// Actor wrapping FluidAudio's `Qwen3StreamingManager` to drive a **live
/// preview only** for the experimental Qwen3-ASR languages (Mandarin /
/// Cantonese / Vietnamese).
///
/// Mirrors `NemotronStreamingTranscriber`'s control surface (`start` /
/// `enqueue` / `finish` / `cancel` / `ensureLoaded` / `isReady`) so it can slot
/// into `DualPipelineTranscriber` the same way — but its role is different:
///
/// - **Preview-only.** `Qwen3StreamingManager` is a re-transcribe sliding-window
///   streamer with a 30 s window and a 512-token decode cap, which degrades long
///   dictations. So Jot uses it ONLY to surface partial text in the recording
///   pill while speaking. At stop the stream is quiesced/cancelled and the
///   authoritative transcript comes from a fresh batch `Qwen3Transcriber` pass
///   over the FULL audio (exactly how JA / v3 keep batch authoritative and
///   discard the pseudo-stream preview). `DualPipelineTranscriber.finishStreaming()`
///   for this case returns `nil` so the caller runs the batch final.
///
/// - **No double model load.** The manager is borrowed from the SAME batch
///   `Qwen3Transcriber` instance that produces the final transcript
///   (`sharedManager()`), so the multi-hundred-MB CoreML pipeline is loaded once.
///   Preview and batch final never run concurrently within one recording — the
///   preview is fenced off at stop before the batch pass runs.
///
/// `@available(macOS 15, *)` because `Qwen3StreamingManager` /
/// `Qwen3AsrManager` are. Jot's deployment target is already macOS 15, so this
/// is the compiler-required annotation only — no runtime hiding is needed.
@available(macOS 15, *)
final actor Qwen3StreamingTranscriber {

    /// The batch transcriber whose loaded `Qwen3AsrManager` we borrow. Holding
    /// the batch instance (not a bare manager) keeps the single-load contract:
    /// whichever side loads first warms the shared manager and the other reuses
    /// it.
    private let batch: Qwen3Transcriber

    /// Qwen3-ASR ISO language hint (`"zh"` / `"yue"` / `"vi"` …) bound at
    /// construction. Resolved to a `Qwen3AsrConfig.Language` for the streaming
    /// config; an unknown / nil hint falls back to the manager's automatic
    /// language detection.
    private let languageHint: String?

    /// `true` for spaceless CJK (Mandarin / Cantonese). Used to collapse any
    /// stray whitespace in the partials before they reach the pill, matching the
    /// batch transcriber's final whitespace handling. Vietnamese is `false`
    /// (space-separated Latin), so its partials keep their word spacing.
    private let spaceless: Bool

    private var streaming: Qwen3StreamingManager?
    private var activeGeneration: UInt64?
    private let continuationBox = Qwen3ContinuationBox()
    private var consumerTask: Task<Void, Never>?

    init(batch: Qwen3Transcriber, languageHint: String?, spaceless: Bool) {
        self.batch = batch
        self.languageHint = languageHint
        self.spaceless = spaceless
    }

    var isReady: Bool { streaming != nil }

    /// Borrow the shared batch manager (loading it on demand) and wrap it in a
    /// `Qwen3StreamingManager` configured for the bound language. Idempotent.
    func ensureLoaded() async throws {
        if streaming != nil { return }
        let manager = try await batch.sharedManager()
        let language = languageHint.flatMap { Qwen3AsrConfig.Language(from: $0) }
        let config = Qwen3StreamingConfig(
            // Surface a first partial quickly, then re-transcribe on a short
            // cadence so the pill tracks speech without hammering the ANE.
            minAudioSeconds: 1.0,
            chunkSeconds: 1.5,
            maxAudioSeconds: 30.0,
            language: language
        )
        let mgr = Qwen3StreamingManager(asrManager: manager, config: config)
        streaming = mgr
    }

    /// Begin a live preview session. Spins up a detached consumer that loads the
    /// streaming manager, drains queued audio chunks through `addAudio`, and
    /// forwards each non-empty partial transcript to `onPartial` tagged with the
    /// session `generation`. Best-effort: load / decode failures are logged and
    /// the consumer exits silently (the pill simply shows no preview text — the
    /// batch final is unaffected).
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

        let spaceless = self.spaceless
        consumerTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureLoaded()
            } catch {
                await ErrorLog.shared.error(
                    component: "Qwen3StreamingTranscriber",
                    message: "ensureLoaded failed in consumer (skipping partials)",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
                return
            }
            guard let mgr = await self.activeStreaming() else { return }
            await mgr.reset()

            for await samples in stream {
                if Task.isCancelled { break }
                guard !samples.isEmpty else { continue }
                do {
                    if let result = try await mgr.addAudio(samples) {
                        let partial = Self.normalize(result.transcript, spaceless: spaceless)
                        if !partial.isEmpty {
                            onPartial(partial, generation)
                        }
                    }
                } catch {
                    await ErrorLog.shared.error(
                        component: "Qwen3StreamingTranscriber",
                        message: "addAudio failed",
                        context: ["error": ErrorLog.redactedAppleError(error)]
                    )
                }
            }
        }
    }

    private func activeStreaming() -> Qwen3StreamingManager? { streaming }

    nonisolated func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuationBox.yield(samples)
    }

    /// Quiesce the preview. The returned partial is **discarded** by
    /// `DualPipelineTranscriber.finishStreaming()` — Qwen3's authoritative
    /// transcript is the batch pass over the full audio, not this 30 s-windowed
    /// preview. Returning the last partial only mirrors the
    /// `NemotronStreamingTranscriber.finish()` shape; the caller ignores it.
    @discardableResult
    func finish() async -> String? {
        continuationBox.finish()
        await drainConsumerWithTimeout(seconds: 2)
        let last: String?
        if let mgr = streaming {
            // `finish()` runs one more decode over the trailing buffer and
            // resets. We don't use this for the final transcript, but draining
            // it leaves the manager clean for the next session.
            do {
                let result = try await mgr.finish()
                last = Self.normalize(result.transcript, spaceless: spaceless)
            } catch {
                last = nil
            }
        } else {
            last = nil
        }
        activeGeneration = nil
        return last
    }

    /// Abandon the preview immediately (cancel path). No final decode.
    func cancel() async {
        continuationBox.finish()
        consumerTask?.cancel()
        consumerTask = nil
        activeGeneration = nil
        if let mgr = streaming {
            await mgr.reset()
        }
    }

    private func drainConsumerWithTimeout(seconds: TimeInterval) async {
        guard let task = consumerTask else { return }
        consumerTask = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
        if !task.isCancelled {
            task.cancel()
        }
    }

    /// Collapse stray whitespace for spaceless CJK partials; trim otherwise.
    /// Mirrors `Qwen3Transcriber`'s final whitespace handling so the live
    /// preview reads the same way the committed transcript will.
    private static func normalize(_ raw: String, spaceless: Bool) -> String {
        if spaceless {
            return raw
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined()
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe holder for the per-session audio continuation, identical in shape
/// to `NemotronContinuationBox`. Lets the `nonisolated` `enqueue(samples:)` sink
/// hand chunks to the consumer without hopping the actor on the audio path.
@available(macOS 15, *)
private final class Qwen3ContinuationBox: @unchecked Sendable {
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
