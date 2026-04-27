import Combine
import Foundation
@testable import Jot

extension JotHarness {

    /// Drive the chatbot voice-input flow end-to-end through the live
    /// `ChatbotVoiceInput` graph. Used by Phase 1.6 + the I1 regression
    /// test (`cancelAfter: .condensing`).
    ///
    /// Spec source: `docs/plans/agentic-testing.md` §0.2 +
    /// `cleanup-roadmap.md` I1.
    ///
    /// **Construction note:** `ChatbotVoiceInput` isn't part of
    /// `AppServices` (Phase 0.1 only seamed the OS boundary; the
    /// chatbot voice surface is a per-view product). The harness mints
    /// one per call, threading the harness's `pipeline` + `recorder` +
    /// `StubAppleIntelligence` through it. This mirrors what `Ask Jot`'s
    /// SwiftUI surface does at runtime.
    func askJotVoice(
        audio: AudioSource,
        condense: Bool = true,
        cancelAfter: AskJotPhase? = nil,
        transcript: String? = nil,
        condenserOverride: (any ChatbotCondenser)? = nil
    ) async throws -> AskJotResult {
        let testStart = Date()

        // 1. Pre-warm the transcriber. `ChatbotVoiceInput` reads
        //    `transcriber.isReady` indirectly via
        //    `pipeline.stopAndTranscribe(token)` — without this the
        //    pipeline reports `modelMissing` and the flow errors out
        //    before reaching condensation.
        try await services.pipeline.ensureTranscriberLoaded()

        // 2. Queue the audio + the canned transcript. Default is
        //    long enough (≥15 words) that
        //    `ChatbotVoiceInput.shouldSkipCondensation(...)` returns
        //    false and the flow enters `.condensing`. Tests that
        //    want to exercise the short-input skip path pass an
        //    explicit `transcript:` of <15 words.
        let samples = try Self.decodedSamples(from: audio)
        await stubAudioCapture.enqueue(audio: .samples(samples))
        let cannedTranscript = transcript ?? """
            How do I change the dictation hotkey to something other than \
            the default and where does Jot store my recordings on disk so \
            I can find them later
            """
        await stubTranscriber.enqueue(asrSeed: StubTranscriber.canned(text: cannedTranscript))

        // 3. Construct `ChatbotVoiceInput` with the harness's seams.
        //    Condenser selection (in order):
        //      a) `condenserOverride` — caller-provided (e.g. the I1
        //         test's `StubCondenser` with a known sleep duration)
        //      b) `AppleIntelligenceCondenser(client: stubAppleIntelligence)` —
        //         routes through the AppleIntelligence seam, so
        //         `seed.appleIntelligence` controls behavior
        //         (`.stub` / `.unavailable` / `.blocksUntilCancelled`)
        let condenser: any ChatbotCondenser = condenserOverride
            ?? AppleIntelligenceCondenser(client: stubAppleIntelligence)
        let voice = ChatbotVoiceInput(
            pipeline: services.pipeline,
            recorder: services.recorder,
            pill: nil,
            condenser: condenser
        )

        // 4. Launch `capture()` on its own Task — it blocks until
        //    `stop()` (or `cancel()`) resolves the awaiting
        //    continuation.
        let captureTask = Task { @MainActor in
            try await voice.capture()
        }

        // 5. Drive the phases.
        try await Self.awaitMicState(voice, predicate: { state in
            if case .recording = state { return true }
            return false
        }, timeout: .seconds(5))

        if cancelAfter == .audioCapture {
            await voice.cancel()
            captureTask.cancel()
            return await Self.assembleAskJotResult(
                transcript: nil,
                condensed: nil,
                voice: voice,
                stubAppleIntelligence: stubAppleIntelligence,
                stubCondenser: condenserOverride as? StubCondenser,
                logSink: capturingLogSink,
                testStart: testStart
            )
        }

        // Stop → transcribe → condense
        voice.stop()

        // For the I1 test (`cancelAfter == .condensing`), wait for
        // state to reach `.condensing`, then cancel before the
        // condenser returns. With `StubAppleIntelligence(.stub)`,
        // condensation completes synchronously and we'd race past
        // `.condensing` — the I1 test seeds `.blocksUntilCancelled`
        // so the stub's `articulate(...)` suspends, holding the flow
        // in `.condensing` long enough to cancel.
        if cancelAfter == .condensing {
            try await Self.awaitMicState(voice, predicate: { state in
                state == .condensing
            }, timeout: .seconds(5))

            await voice.cancel()

            // Wait a SHORT window — much less than the 10s
            // `condenseIfEligible` budget timer — to observe whether
            // the user-initiated `cancel()` propagated promptly.
            //
            // With the I1 bug present, `cancel()` doesn't propagate
            // → the stub never sees cancellation in this short
            // window → flag stays `false`. (Eventually the 10s
            // budget timer DOES cancel the group's children, which
            // would set the flag — but by then we've already
            // observed the failure window.)
            //
            // With the bug fixed (Phase 2), cancellation propagates
            // immediately → flag flips `true` within ms.
            try await Self.awaitArticulateCancellation(
                stubAppleIntelligence,
                timeout: .milliseconds(500)
            )

            captureTask.cancel()
            return await Self.assembleAskJotResult(
                transcript: nil,
                condensed: nil,
                voice: voice,
                stubAppleIntelligence: stubAppleIntelligence,
                stubCondenser: condenserOverride as? StubCondenser,
                logSink: capturingLogSink,
                testStart: testStart
            )
        }

        // Happy path — let `capture()` complete and return the final
        // text.
        let finalText: String?
        do {
            finalText = try await captureTask.value
        } catch {
            finalText = nil
        }

        return await Self.assembleAskJotResult(
            transcript: finalText,
            condensed: finalText,
            voice: voice,
            stubAppleIntelligence: stubAppleIntelligence,
            stubCondenser: condenserOverride as? StubCondenser,
            logSink: capturingLogSink,
            testStart: testStart
        )
    }

    // MARK: - Helpers

    static func assembleAskJotResult(
        transcript: String?,
        condensed: String?,
        voice: ChatbotVoiceInput,
        stubAppleIntelligence: StubAppleIntelligence,
        stubCondenser: StubCondenser? = nil,
        logSink: CapturingLogSink,
        testStart: Date
    ) async -> AskJotResult {
        // `condensationTaskWasCancelled` is the I1 invariant:
        //   - With `StubAppleIntelligence(.blocksUntilCancelled)`,
        //     the stub's `withTaskCancellationHandler` flips
        //     `lastArticulateWasCancelled = true` when cancellation
        //     reaches the suspended `articulate(...)` call.
        //   - With `condenserOverride: StubCondenser(...)`,
        //     `outcome == .cancelled` when the stub's
        //     `Task.checkCancellation()` throws because cancellation
        //     reached `condense(raw:)`.
        // Either path proves the production cancel propagation;
        // OR them so the harness's I1 result reflects whichever
        // path the test wired up.
        let viaAppleIntelligence = await stubAppleIntelligence.lastArticulateWasCancelled
        let viaCondenser = (stubCondenser?.outcome == .cancelled)
        let cancelled = viaAppleIntelligence || viaCondenser

        return AskJotResult(
            transcript: transcript,
            condensed: condensed,
            condensationTaskWasCancelled: cancelled,
            log: nil  // logSink.entries(since:) requires async — assemble synchronously
        )
    }

    /// Wait until `voice.state` matches `predicate` or `timeout`
    /// elapses. Bounded poll on `$state`.
    static func awaitMicState(
        _ voice: ChatbotVoiceInput,
        predicate: @MainActor @Sendable @escaping (ChatbotVoiceInput.MicState) -> Bool,
        timeout: Duration
    ) async throws {
        let initial = await MainActor.run { voice.state }
        if predicate(initial) { return }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                var iterator = voice.$state.values.makeAsyncIterator()
                while let next = await iterator.next() {
                    if predicate(next) { return true }
                }
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw HarnessTimeoutError.timedOut
            }
            group.cancelAll()
            if !first { throw HarnessTimeoutError.timedOut }
        }
    }

    /// Poll `stubAppleIntelligence.lastArticulateWasCancelled` until
    /// it flips `true` or `timeout` elapses. Used by the I1 test —
    /// returns successfully whether or not the flag flipped (the test
    /// asserts on the resulting value).
    static func awaitArticulateCancellation(
        _ stub: StubAppleIntelligence,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await stub.lastArticulateWasCancelled { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Don't throw — the I1 test wants to assert on the final
        // observed value (false today, true after Phase 2 fix).
    }
}

// Note: `ChatbotVoiceInput.MicState` doesn't conform to `Equatable` for
// `Sendable` / SwiftUI reasons, but its cases compare via `Equatable`
// `==`. The `predicate` closure pattern above sidesteps any need for
// direct equality comparison.

extension AskJotResult {
    /// Convenience init that allows the harness to populate `log` lazily
    /// from an async-actor sink. The synchronous assembly path passes
    /// `log: nil` and a follow-up `await` populates it; for now the
    /// harness leaves `log` as an empty array since the I1 test only
    /// asserts on `condensationTaskWasCancelled`.
    init(
        transcript: String?,
        condensed: String?,
        condensationTaskWasCancelled: Bool,
        log: [LogEntry]?
    ) {
        self.init(
            transcript: transcript,
            condensed: condensed,
            condensationTaskWasCancelled: condensationTaskWasCancelled,
            log: log ?? []
        )
    }
}
