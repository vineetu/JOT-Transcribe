import Foundation
import os.log

/// Batch pseudo-streaming live-preview engine (canonical plan:
/// `docs/batch-pseudo-streaming/design.md`). Ported from jot-mobile's
/// `PreviewScheduler` (the iPhone batch-only-streaming worktree).
///
/// Drives the recording pill's live preview by **re-running the batch
/// `Transcriber` over a trailing audio window** on a cadence — instead of a
/// dedicated streaming ASR model (EOU). Each tick decodes with a **fresh
/// `TdtDecoderState`** (no carried state); that fresh-per-call + trailing-overlap
/// approach tracks the final full-file pass to ~1.3% divergence, versus ~10.9%
/// for FluidAudio's carried-state `SlidingWindowAsrManager` (design §8). The
/// saved/pasted transcript is untouched — it is always the full-file batch pass
/// on stop; this engine only fills the preview surface.
///
/// ## Cadence (pause is the trigger; timer + cap are fallbacks)
///
/// - **Pause** (energy gate, ~0.7 s below threshold): COMMIT — transcribe the
///   window `[lastCommit … now]` and fold it into the committed prefix. Safe at a
///   pause because the window is a completed utterance *with* its left context.
/// - **Timer** (5 s without a trigger): VOLATILE refresh — same window, text not
///   committed, so the next tick re-derives it. Keeps text flowing for a no-pause
///   talker.
/// - **Cap** (window ≥ 15 s): COMMIT + slide, the runaway guard.
/// - **First-tick-fast** (~2 s, no preview yet): VOLATILE refresh, so short
///   dictations show text early instead of staring at an empty pill for 5 s.
///
/// "Commit" is a TEXT-ASSEMBLY concept (stop re-transcribing locked audio), not a
/// visual one — the whole preview stays visually volatile until the stop-pass
/// replaces it, exactly like the EOU preview today.
///
/// ## Concurrency shape
///
/// One `PreviewScheduler` per recording slice (mirrors `StreamingTranscriber`'s
/// lifecycle). A single consumer task drains chunks in mic order from a
/// lock-protected `AsyncStream` (the FIFO pattern `StreamingTranscriber` uses);
/// ticks run as fire-and-forget actor tasks, single-flight via
/// `inFlight` + `pendingTrigger` (latest-wins, commit outranks volatile).
///
/// `quiesce()` is the **stop fence**: it blocks new ticks and awaits the
/// in-flight one before `DualPipelineTranscriber.finishStreaming()` returns, so a
/// preview decode never overlaps the final batch pass on the module-global
/// `sharedMLArrayCache` (design §4.3.1).
actor PreviewScheduler {

    enum Trigger {
        case volatileRefresh   // timer / first-tick: re-derive volatile tail
        case commit            // pause or cap: fold window into prefix
    }

    // MARK: Tunables (canonical plan §2.2 / §6 — jot-mobile's tuned values)

    private static let sampleRate = 16_000
    /// Silence run that counts as a pause.
    private static let pauseSilenceSamples = Int(0.7 * Double(sampleRate))
    /// Volatile-refresh fallback when no pause fires.
    private static let timerSamples = Int(5.0 * Double(sampleRate))
    /// Runaway window guard.
    private static let capSamples = Int(15.0 * Double(sampleRate))
    /// Energy gate: chunk RMS below this is "silence". iPhone-tuned (0.005);
    /// the macOS-mic validation corpus is a Phase-3 deliverable (design §6).
    private static let silenceRMS: Float = 0.005
    /// Global minimum spacing between ticks: the STRUCTURAL inference
    /// duty-cycle bound (≤ one tick per 2 s regardless of which trigger fires).
    private static let minTickSpacingSamples = Int(2.0 * Double(sampleRate))
    /// Don't transcribe windows shorter than this (the model needs ≥ 1 s;
    /// `Transcriber.previewTranscribe` also guards).
    private static let minWindowSamples = Int(1.0 * Double(sampleRate))
    /// First-tick-fast: when NO preview exists yet, fire the first volatile
    /// refresh as soon as the window reaches this instead of waiting the full
    /// 5 s timer. Still ≥ `minTickSpacingSamples`.
    private static let firstTickSamples = Int(2.0 * Double(sampleRate))
    /// Trailing ring keeps cap + margin so the window is always available.
    private static let ringCapacity = capSamples + Int(5.0 * Double(sampleRate))

    // MARK: Dependencies

    /// The SAME batch `Transcriber` that produces the final transcript — shared
    /// by reference so the preview re-uses the loaded `AsrModels` (no second
    /// model load). The routing/factory layer is responsible for passing the
    /// shared instance (design §4.5).
    private let transcriber: Transcriber

    /// Publish callback + generation token, wired per session by `begin`.
    /// Identical contract to the EOU engine's `onPartial` — the closure itself
    /// performs the MainActor hop into `StreamingPartialStore`.
    private var onPartial: (@Sendable (String, UInt64) -> Void)?
    private var generation: UInt64 = 0

    // MARK: Audio plumbing (FIFO drain — mirrors StreamingTranscriber)

    private let continuationBox = ContinuationBox()
    private var consumerTask: Task<Void, Never>?

    // MARK: Ring + windowing state

    /// Trailing audio. `ring[0]` is absolute sample index `ringStartTotal`.
    private var ring: [Float] = []
    private var ringStartTotal = 0
    private var totalSamples = 0

    /// Text locked at commits — audio before `windowStartTotal` is never
    /// re-transcribed again.
    private var committedText = ""
    /// Last published volatile tail.
    private var volatileTail = ""
    private var windowStartTotal = 0

    private var silenceRun = 0
    private var pauseFiredThisRun = false
    /// Absolute sample index of the most recent above-threshold chunk.
    /// "Has speech arrived in the current window" = `lastSpeechTotal >
    /// windowStartTotal` — an index comparison so speech landing DURING a tick
    /// (belonging to the next window) isn't wiped by the commit.
    private var lastSpeechTotal = -1
    private var lastTickTotal = 0
    /// Consecutive commit ticks whose window transcribed to nothing despite
    /// containing speech. Drives the give-up valve (see `runTick`).
    private var emptyRetries = 0

    private var inFlight = false
    private var pendingTrigger: Trigger?
    /// Set when the recording stopped (drain ended / quiesce / cancel). Gates
    /// trigger scheduling so no zombie inference starts after stop.
    private var stopped = false
    /// In-flight tick task — awaited by `quiesce()` so the final pass starts
    /// only after the last preview tick has finished decoding.
    private var tickTask: Task<Void, Never>?

    private let log = Logger(subsystem: "com.jot.Jot", category: "preview-scheduler")

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
    }

    // MARK: Session lifecycle

    /// Begin a streaming session. Resets all per-session state, then spawns the
    /// single consumer task that drains chunks (yielded via `enqueue`) in mic
    /// order. Returns immediately; the first chunk can arrive before this hop
    /// completes — it accumulates in the unbounded stream and is drained in
    /// order, so nothing is lost.
    func begin(
        generation: UInt64,
        onPartial: @escaping @Sendable (String, UInt64) -> Void
    ) {
        // Reset session state (one scheduler may be reused across slices).
        self.generation = generation
        self.onPartial = onPartial
        ring = []
        ringStartTotal = 0
        totalSamples = 0
        committedText = ""
        volatileTail = ""
        windowStartTotal = 0
        silenceRun = 0
        pauseFiredThisRun = false
        lastSpeechTotal = -1
        lastTickTotal = 0
        emptyRetries = 0
        inFlight = false
        pendingTrigger = nil
        stopped = false
        tickTask = nil

        var holder: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { holder = $0 }
        continuationBox.set(holder)

        consumerTask = Task { [weak self] in
            for await chunk in stream {
                if Task.isCancelled { break }
                await self?.ingest(chunk)
            }
            // Stream finished == end of capture. Block any further ticks.
            await self?.markStopped()
        }
    }

    /// Synchronous, nonisolated. Called from the audio capture writer queue
    /// (already FIFO) for each converted 16 kHz mono Float32 chunk. Yields into
    /// the per-session stream — the consumer task drains in order — so the
    /// writer queue never blocks on an actor hop. Identical contract to
    /// `StreamingTranscriber.enqueue`.
    nonisolated func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        continuationBox.yield(samples)
    }

    private func markStopped() {
        stopped = true
    }

    /// Stop fence. Closes the stream, awaits the consumer drain, then awaits the
    /// in-flight tick (if any) — with rescheduling disabled via `stopped`.
    /// `DualPipelineTranscriber.finishStreaming()` MUST call this before the
    /// final batch `transcribe`, so a preview decode never contends with the
    /// final pass on the module-global `sharedMLArrayCache` (design §4.3.1).
    func quiesce() async {
        stopped = true
        continuationBox.finish()
        await consumerTask?.value
        await tickTask?.value
    }

    /// Abandon the session (Esc / cancel). Drops queued audio and stops ticks
    /// WITHOUT awaiting — a slow in-flight decode must not block cancel
    /// responsiveness (mirrors `StreamingTranscriber.cancel`). Any result the
    /// in-flight tick produces is discarded because `onPartial` is cleared.
    func cancel() async {
        stopped = true
        continuationBox.finish()
        consumerTask?.cancel()
        tickTask?.cancel()
        onPartial = nil
    }

    // MARK: Ingestion + triggers

    private func ingest(_ chunk: [Float]) {
        ring.append(contentsOf: chunk)
        totalSamples += chunk.count
        if ring.count > Self.ringCapacity {
            let drop = ring.count - Self.ringCapacity
            ring.removeFirst(drop)
            ringStartTotal += drop
        }

        // Energy gate.
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
        if rms < Self.silenceRMS {
            silenceRun += chunk.count
        } else {
            silenceRun = 0
            pauseFiredThisRun = false
            lastSpeechTotal = totalSamples
        }

        guard !stopped else { return }
        let windowLen = totalSamples - windowStartTotal
        let speechInWindow = lastSpeechTotal > windowStartTotal

        // EVERY trigger is gated on speech-in-window: a pure-silence window must
        // never run inference (else a long silent stretch hits the cap on every
        // chunk and burns back-to-back full-window passes).
        guard speechInWindow else { return }
        // Structural duty-cycle bound: no two ticks closer than 2 s, regardless
        // of trigger. Pairs with retry-not-discard in `runTick`.
        guard totalSamples - lastTickTotal >= Self.minTickSpacingSamples else { return }

        // Trigger priority: pause > cap > first-tick-fast > timer.
        if silenceRun >= Self.pauseSilenceSamples,
           !pauseFiredThisRun,
           windowLen >= Self.minWindowSamples {
            pauseFiredThisRun = true
            schedule(.commit)
        } else if windowLen >= Self.capSamples {
            schedule(.commit)
        } else if committedText.isEmpty, volatileTail.isEmpty,
                  windowLen >= Self.firstTickSamples {
            // First-tick-fast: show SOMETHING at ~2 s rather than after the full
            // 5 s timer. Subsequent ticks fall through to the normal cadence.
            schedule(.volatileRefresh)
        } else if totalSamples - lastTickTotal >= Self.timerSamples,
                  windowLen >= Self.minWindowSamples {
            schedule(.volatileRefresh)
        }
    }

    /// Latest-wins coalescing: never more than one tick in flight; a trigger
    /// arriving mid-tick is remembered (commit outranks volatile) and fired once
    /// the current tick returns.
    private func schedule(_ trigger: Trigger) {
        guard !stopped else { return }
        lastTickTotal = totalSamples
        if inFlight {
            if case .commit = trigger { pendingTrigger = .commit }
            else if pendingTrigger == nil { pendingTrigger = .volatileRefresh }
            return
        }
        inFlight = true
        let windowStart = windowStartTotal
        let windowEnd = totalSamples
        tickTask = Task { await self.runTick(trigger, windowStart: windowStart, windowEnd: windowEnd) }
    }

    private func runTick(_ trigger: Trigger, windowStart: Int, windowEnd: Int) async {
        defer {
            inFlight = false
            // No reschedule after stop — a pending trigger must not start a
            // zombie inference while the saving stop-pass runs.
            if !stopped, let next = pendingTrigger {
                pendingTrigger = nil
                schedule(next)
            }
        }

        // Snapshot the window out of the ring (indices are absolute).
        let lo = max(windowStart - ringStartTotal, 0)
        let hi = min(windowEnd - ringStartTotal, ring.count)
        guard hi > lo else {
            // Degenerate window (fully trimmed); advance on commit so the cap
            // can't re-fire on the same dead range.
            if case .commit = trigger { windowStartTotal = max(windowStartTotal, windowEnd) }
            return
        }
        if windowStart - ringStartTotal < 0 {
            // Window head fell off the trailing ring (a > 5 s tick let the
            // window outgrow the margin). Preview-only loss; log it.
            log.notice("preview window head trimmed — windowStart=\(windowStart) ringStart=\(self.ringStartTotal)")
        }
        let window = Array(ring[lo..<hi])

        // Lean decode on the shared batch Transcriber actor. Never throws.
        let text = await transcriber.previewTranscribe(window)

        switch trigger {
        case .commit:
            if let text, !text.isEmpty {
                committedText = Self.join(committedText, text)
                windowStartTotal = max(windowStartTotal, windowEnd)
                emptyRetries = 0
            } else {
                // NEVER advance past speech on an empty result — keep the window
                // and retry with MORE audio (the model wants more context, not
                // less). Runaway is bounded by `minTickSpacingSamples`. Give-up
                // valve: persistent garbage at cap length is skipped (the
                // stop-pass still transcribes that audio for the saved note).
                emptyRetries += 1
                if emptyRetries >= 3, windowEnd - windowStartTotal >= Self.capSamples {
                    log.notice("preview window gave up after \(self.emptyRetries) empty ticks")
                    windowStartTotal = max(windowStartTotal, windowEnd)
                    emptyRetries = 0
                }
            }
            volatileTail = ""
        case .volatileRefresh:
            guard let text, !text.isEmpty else { return }
            volatileTail = text
        }

        let display = trigger == .commit
            ? committedText
            : Self.join(committedText, volatileTail)
        guard !display.isEmpty else { return }
        // Publish via the EOU-style callback (it performs its own MainActor hop).
        onPartial?(display, generation)
    }

    private static func join(_ a: String, _ b: String) -> String {
        let lhs = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        return lhs + " " + rhs
    }
}

/// Lock-protected wrapper around `AsyncStream.Continuation`, so the nonisolated
/// `enqueue(samples:)` reaches the continuation without an actor hop, preserving
/// FIFO from the audio writer queue end-to-end. (Same pattern as the private box
/// in `StreamingTranscriber.swift`.)
private final class ContinuationBox: @unchecked Sendable {
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
