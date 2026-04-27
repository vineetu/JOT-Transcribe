import Foundation
@testable import Jot

extension JotHarness {

    // MARK: - Fixed-prompt articulate

    /// Drive the v1.5 fixed-prompt articulate path
    /// (`ArticulateController.articulate()`). Pre-primes the stub
    /// pasteboard with `selection` (so `captureSelection`'s synthetic
    /// ⌘C guard sees a `changeCount` bump), enqueues the provider's
    /// canned response on `StubURLProtocol`, invokes the controller,
    /// and snapshots the result.
    ///
    /// Spec source: `docs/plans/agentic-testing.md` §0.2.
    func articulate(
        selection: String,
        provider: ProviderSeed
    ) async throws -> ArticulateResult {
        let testStart = Date()

        // 0. Drain any chat/completions responses left over from a
        //    prior harness run. `removeMatching` (not `reset()`)
        //    keeps the standalone `stubURLProtocol_servesCannedResponse`
        //    smoke test's `"example.com"` enqueue intact when it
        //    runs in parallel.
        StubURLProtocol.removeMatching("chat/completions")

        // 1. LLM provider config. Cloud providers require an API key
        //    that lives in the **real** macOS keychain (KeychainHelper
        //    isn't behind the KeychainStoring seam yet — Phase 3 B1).
        //    For the harness we route through Ollama (no key required)
        //    regardless of which provider the seed names — the
        //    StubURLProtocol intercepts every URL anyway, so the on-
        //    the-wire endpoint doesn't matter for the test.
        configureForArticulate(seedProvider: provider)

        // 2. Enqueue the canned HTTP response.
        Self.enqueueProviderResponse(provider, on: services.urlSession)

        // 3. Pre-arm the stub pasteboard: when the controller posts a
        //    synthetic ⌘C inside `captureSelection`, the stub's
        //    `postCommandC()` writes `selection` to the pasteboard
        //    (bumping `changeCount`) so the controller's
        //    "did the copy actually move data?" guard passes. Phase 0.7
        //    + Phase 1.5 closure: synthetic key events route through
        //    the `Pasteboarding` seam now, no timing race.
        stubPasteboard.simulatedExternalSelection = selection

        // 4. Drive the controller. The first `articulate()` call
        //    schedules `runFixed` as a Task, so the controller's
        //    `state` may still read `.idle` when we return. Wait for
        //    the state to leave `.idle` first, then for terminal —
        //    otherwise `awaitTerminalState` short-circuits on the
        //    pre-flow `.idle` reading.
        await services.articulateController.articulate()
        try await Self.awaitArticulateLeavesIdle(services.articulateController, timeout: .seconds(2))
        try await services.articulateController.awaitTerminalState(timeout: .seconds(10))

        // 5. Snapshot.
        let log = await capturingLogSink.entries(since: testStart)
        let pillError = Self.derivePillError(from: services.articulateController.state)
        let pastedText = Self.lastPasteAfterStart(in: stubPasteboard.history, sinceTestStart: testStart)
        return ArticulateResult(
            pastedText: pastedText,
            pillError: pillError,
            log: log
        )
    }

    // MARK: - Custom (voice-driven) articulate

    /// Drive the v1.4 custom-instruction articulate path
    /// (`ArticulateController.toggle()`). The voice instruction is
    /// captured via the stub `AudioCapture`, transcribed via the stub
    /// `Transcriber`, and then routed to the LLM through the same
    /// `StubURLProtocol` interception path as the fixed flow.
    ///
    /// Phase 1.5 acceptance: a happy-path run with selection
    /// "hello world" + provider `.openai(.respondsWith("HELLO WORLD"))`
    /// (or any successful canned response) returns a result whose
    /// `pasteboardHistory` contains "HELLO WORLD".
    func articulateCustom(
        selection: String,
        instruction: AudioSource,
        provider: ProviderSeed
    ) async throws -> ArticulateResult {
        let testStart = Date()

        // Drain leftover chat/completions URL responses — same
        // rationale as `articulate(selection:provider:)`.
        StubURLProtocol.removeMatching("chat/completions")

        configureForArticulate(seedProvider: provider)
        Self.enqueueProviderResponse(provider, on: services.urlSession)

        // Pre-warm the transcriber. Production calls
        // `ensureTranscriberLoaded` from `AppDelegate.prewarmTranscriber`
        // and again as a `Task.detached` inside `RecorderController.runFlow`;
        // articulate's `runCustom` doesn't prewarm. Without this the
        // pipeline reports `modelMissing` and the controller surfaces
        // the "Transcription model is still loading" error.
        try await services.pipeline.ensureTranscriberLoaded()

        // Decode the voice-instruction audio and queue it on the stub
        // capture. Stub Transcriber will return canned text — Phase 1.5
        // doesn't care about the instruction's content, only that the
        // pipeline reaches the rewrite step.
        let samples = try Self.decodedSamples(from: instruction)
        await stubAudioCapture.enqueue(audio: .samples(samples))

        if await !stubTranscriberHasQueuedResponseSentinelHack() {
            await stubTranscriber.enqueue(asrSeed: StubTranscriber.canned(text: "make it shorter"))
        }

        // Pre-arm the stub pasteboard with `selection` (same shape as
        // fixed flow — see comment there). Custom flow's
        // `captureSelection` happens before recording, so this is in
        // place when the controller's `postCommandC()` fires.
        stubPasteboard.simulatedExternalSelection = selection

        // Drive: first toggle starts the flow, wait for `.recording`
        // (which happens AFTER captureSelection completes and pipeline
        // recording starts), second toggle stops recording → transcribe
        // → LLM → paste.
        await services.articulateController.toggle()
        try await Self.awaitArticulateRecording(services.articulateController, timeout: .seconds(5))

        await services.articulateController.toggle()
        try await services.articulateController.awaitTerminalState(timeout: .seconds(15))

        let log = await capturingLogSink.entries(since: testStart)
        let pillError = Self.derivePillError(from: services.articulateController.state)
        let pastedText = Self.lastPasteAfterStart(in: stubPasteboard.history, sinceTestStart: testStart)
        return ArticulateResult(
            pastedText: pastedText,
            pillError: pillError,
            log: log
        )
    }

    // MARK: - Helpers (articulate-specific)

    /// Sentinel for "transcriber has been seeded by the caller". The
    /// stub's queue is internal; the harness assumes "always reseed if
    /// this returns false". Mirrors the `dictate` flow's same-named
    /// helper. The body is the same `false` placeholder — convention
    /// is "if you wanted control, you enqueued before calling".
    private func stubTranscriberHasQueuedResponseSentinelHack() async -> Bool {
        false
    }

    /// Configure the per-harness `LLMConfiguration` for the articulate
    /// run. Always routes through `.ollama` regardless of which
    /// provider the seed names — see top-of-method note in
    /// `articulate(...)` for why. Also flips off Transform so the
    /// dictation flow's auto-cleanup path doesn't fire (articulate has
    /// its own cleanup gate).
    @MainActor
    func configureForArticulate(seedProvider: ProviderSeed) {
        services.llmConfiguration.provider = .ollama
    }

    /// Translate a `ProviderSeed` into a `StubURLProtocol` enqueue.
    /// Matches against the Ollama base URL substring — the test
    /// harness always routes via `.ollama` (see
    /// `configureForArticulate`), so a single matcher covers every
    /// provider seed shape we care about for Phase 1.5.
    static func enqueueProviderResponse(_ seed: ProviderSeed, on session: URLSession) {
        // Match the LLM chat-completion path specifically — NOT every
        // HTTP request. The Jot graph also boots Sparkle (which fetches
        // the appcast on a timer), so a wildcard matcher would let
        // Sparkle consume the queued LLM response when test suites
        // interleave. `"chat/completions"` is the path segment the
        // OpenAI-compatible providers (OpenAI, Ollama, Anthropic via
        // shape-compat) use; Apple Intelligence bypasses HTTP and
        // Flavor1 hits a different path.
        let matcher = "chat/completions"
        switch seed {
        case .openai(let s): enqueueOpenAILike(seed: s, matcher: matcher)
        case .anthropic(let s):
            enqueueOpenAILike(seed: openAIShape(from: s), matcher: matcher)
        case .gemini(let s):
            enqueueOpenAILike(seed: openAIShape(from: s), matcher: matcher)
        case .ollama(let s):
            enqueueOpenAILike(seed: openAIShape(from: s), matcher: matcher)
        case .appleIntelligence:
            // Apple Intelligence bypasses HTTP entirely; tests routing
            // through this case use `StubAppleIntelligence` directly.
            break
        case .flavor1:
            // Out of Phase 1.5 scope.
            break
        }
    }

    /// Translate an `OpenAISeed` (or shape-compatible sibling) into a
    /// `StubURLProtocol.CannedResponse` enqueue.
    static func enqueueOpenAILike(seed: OpenAISeed, matcher: String) {
        switch seed {
        case .respondsWith(let text):
            // OpenAI-compatible SSE format. `LLMClient.performLLMRequest`
            // streams every cloud provider through `bytes(for:)` (see
            // `shouldStream`); a non-SSE body would parse as zero
            // chunks → `LLMError.emptyResponse`. We emit one `data:`
            // chunk carrying the full text, then `data: [DONE]`.
            let chunkPayload = """
            {"choices":[{"delta":{"content":"\(escapeJSON(text))"}}]}
            """
            let body = """
            data: \(chunkPayload)

            data: [DONE]

            """
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(
                    statusCode: 200,
                    body: Data(body.utf8),
                    headers: ["Content-Type": "text/event-stream"]
                )
            )
        case .respondsWithStreamChunks:
            // Phase 1.5 happy paths use non-streamed responses; stream
            // shape lands when a flow specifically tests SSE. Empty
            // body so a misuse fails loudly with "empty response".
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(statusCode: 200, body: Data())
            )
        case .respondsWith400(let body):
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(statusCode: 400, body: Data(body.utf8))
            )
        case .respondsWith401:
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(statusCode: 401, body: Data("unauthorized".utf8))
            )
        case .respondsWithRateLimit:
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(statusCode: 429, body: Data("rate limited".utf8))
            )
        case .respondsWithToolCall:
            // Phase 1.5 doesn't drive Ask Jot tool-call paths.
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(statusCode: 200, body: Data())
            )
        case .timesOut(let after):
            StubURLProtocol.enqueue(
                matcher: matcher,
                response: .init(statusCode: 200, body: Data(), delay: after)
            )
        }
    }

    /// Shape-compat: `AnthropicSeed` and `GeminiSeed` mirror
    /// `OpenAISeed` case-by-case but are distinct types per Phase 1.2.
    /// Phase 1.5 routes them all through Ollama, so collapse onto the
    /// OpenAI shape for a single canned-response code path.
    static func openAIShape(from seed: AnthropicSeed) -> OpenAISeed {
        switch seed {
        case .respondsWith(let s): return .respondsWith(s)
        case .respondsWithStreamChunks(let s): return .respondsWithStreamChunks(s)
        case .respondsWith400(let s): return .respondsWith400(body: s)
        case .respondsWith401: return .respondsWith401
        case .respondsWithRateLimit: return .respondsWithRateLimit
        case .respondsWithToolCall(let f): return .respondsWithToolCall(featureID: f)
        case .timesOut(let after): return .timesOut(after: after)
        }
    }

    static func openAIShape(from seed: GeminiSeed) -> OpenAISeed {
        switch seed {
        case .respondsWith(let s): return .respondsWith(s)
        case .respondsWithStreamChunks(let s): return .respondsWithStreamChunks(s)
        case .respondsWith400(let s): return .respondsWith400(body: s)
        case .respondsWith401: return .respondsWith401
        case .respondsWithRateLimit: return .respondsWithRateLimit
        case .respondsWithToolCall(let f): return .respondsWithToolCall(featureID: f)
        case .timesOut(let after): return .timesOut(after: after)
        }
    }

    static func openAIShape(from seed: OllamaSeed) -> OpenAISeed {
        switch seed {
        case .respondsWith(let s): return .respondsWith(s)
        case .respondsWithStreamChunks(let s): return .respondsWithStreamChunks(s)
        case .respondsWith400(let s): return .respondsWith400(body: s)
        case .respondsWith401: return .respondsWith401
        case .respondsWithRateLimit: return .respondsWithRateLimit
        case .respondsWithToolCall(let f): return .respondsWithToolCall(featureID: f)
        case .timesOut(let after): return .timesOut(after: after)
        }
    }

    /// Escape a string for inclusion as a JSON string body. Naive but
    /// sufficient for the canned response strings tests pass in.
    private static func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Filter `history` to entries newer than the test-start `Date` and
    /// return the last paste's text — the rewrite landing on the
    /// pasteboard via `pasteReplacement(_:)`.
    static func lastPasteAfterStart(
        in history: [PasteEvent],
        sinceTestStart: Date
    ) -> String? {
        history.last { $0.timestamp >= sinceTestStart }?.text
    }

    /// Map `ArticulateController.ArticulateState` → harness `PillError`.
    /// Only `.error(message)` produces a non-nil result; the message
    /// is the user-facing pill string the controller would render.
    static func derivePillError(from state: ArticulateController.ArticulateState) -> PillError? {
        switch state {
        case .error(let message):
            return PillError(userMessage: message, severity: .transient)
        case .idle, .capturing, .recording, .transcribing, .rewriting:
            return nil
        }
    }

    /// Wait until `articulateController.state` leaves `.idle` so a
    /// subsequent `awaitTerminalState` doesn't short-circuit on the
    /// pre-flow `.idle` reading. Used by the fixed-prompt flow which
    /// goes `.idle → .capturing → .rewriting → .idle`.
    static func awaitArticulateLeavesIdle(
        _ controller: ArticulateController,
        timeout: Duration
    ) async throws {
        if case .idle = controller.state {} else { return }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                var iterator = controller.$state.values.makeAsyncIterator()
                while let next = await iterator.next() {
                    if case .idle = next { continue }
                    return true
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

    /// Wait until `articulateController.state == .recording(...)` so
    /// the second `toggle()` doesn't race the first one's transition
    /// from `.capturing → .recording`. Bounded poll on `$state`.
    static func awaitArticulateRecording(
        _ controller: ArticulateController,
        timeout: Duration
    ) async throws {
        if case .recording = controller.state { return }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                var iterator = controller.$state.values.makeAsyncIterator()
                while let next = await iterator.next() {
                    if case .recording = next { return true }
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
}
