import Foundation
@testable import Jot

// MARK: - Top-level seed

/// Configuration handed to `JotHarness.init(seed:)`. Seeds are pure
/// `Sendable` value types — they describe what each stub seam should do,
/// but they don't carry production state. Tests compose seeds for the
/// flow they're exercising and pass the result in.
///
/// `agentic-testing.md` §0.2 is the authoritative spec for these types.
public struct HarnessSeed: Sendable {
    public var audio: AudioSeed
    public var network: NetworkSeed
    public var appleIntelligence: AppleIntelligenceSeed
    public var permissions: PermissionGrants
    public var keychain: KeychainSeed
    public var clock: ClockSeed

    public init(
        audio: AudioSeed = .liveStub,
        network: NetworkSeed = .stub,
        appleIntelligence: AppleIntelligenceSeed = .stub,
        permissions: PermissionGrants = .allGranted,
        keychain: KeychainSeed = .empty,
        clock: ClockSeed = .controlled
    ) {
        self.audio = audio
        self.network = network
        self.appleIntelligence = appleIntelligence
        self.permissions = permissions
        self.keychain = keychain
        self.clock = clock
    }

    public static let `default` = HarnessSeed()
}

// MARK: - Per-seam seeds

/// `StubAudioCapture` playback mode. The audio *content* is supplied
/// per-flow via `AudioSource` (passed to `dictate(audio:)`,
/// `articulateCustom(instruction:)`, etc.); this seed only picks how the
/// stub reacts to `start()` / `stop()`.
public enum AudioSeed: Sendable {
    /// In-memory stub that replays whatever the test passes to the flow's
    /// `audio:` parameter. The default for happy-path tests.
    case liveStub
    /// Replays a `.wav` from `Tests/JotHarness/Fixtures/audio/` as the
    /// per-stub default when the flow doesn't override it.
    case file(URL)
    /// Synthetic silence of the given duration as the per-stub default.
    /// Drives the "audio too short" rejection paths.
    case silence(duration: Duration)
    /// Raw 16 kHz mono Float32 PCM samples as the per-stub default.
    case samples([Float])
    /// `start()` always throws `AudioCaptureError.engineStart(...)`. Drives
    /// flow tests for the "engine refused to start" pill state without
    /// needing a per-call `enqueue(failure:)` setup. (Phase 1.5 engine-
    /// failure flows.)
    case alwaysFailsToStart
    /// `start()` always throws `AudioCaptureError.engineStartTimeout`.
    /// Drives the "coreaudiod wedged" pill state — the branch that
    /// surfaces `AudioCapture.engineStartTimeoutMessage`.
    case timesOutOnStart
}

/// `StubURLProtocol` response queue mode. Cloud HTTP calls (LLMClient,
/// chat streams, Flavor1Client) are intercepted via `URLProtocol`; this
/// seed picks the queue's behavior. Per-call canned responses are
/// enqueued by the flow method via its `provider:` parameter.
public enum NetworkSeed: Sendable {
    /// In-process URLProtocol stub — returns whatever the flow method
    /// enqueued. Default for happy-path tests.
    case stub
}

/// Apple Intelligence (`FoundationModels`) seam stub mode.
public enum AppleIntelligenceSeed: Sendable {
    /// Default stub — returns canned strings for `transform` /
    /// `articulate`. Per-call canned strings are enqueued by the flow
    /// method via `ProviderSeed.appleIntelligence`.
    case stub
    /// Stub reports `isAvailable == false`. Tests cloud-fallback paths.
    case unavailable
    /// Stub blocks `articulate(...)` until the harness cancels the
    /// in-flight task. Required by the I1 ChatbotVoiceInput regression
    /// (`askJotVoice(cancelAfter: .condensing)`) — without a way to
    /// outlive the cancel signal, no other case exposes
    /// `condensationTaskWasCancelled == true`.
    case blocksUntilCancelled
}

/// Permission grant matrix the stub returns. Maps to the four
/// `Capability` cases in `Sources/Permissions/Capability.swift`.
public enum PermissionGrants: Sendable {
    /// All four capabilities granted. Default for happy-path tests.
    case allGranted
    /// Microphone denied; everything else granted.
    case micDenied
    /// Input Monitoring denied; mic + accessibility granted.
    case inputMonitoringDenied
    /// Accessibility post-events denied; mic + input monitoring granted.
    /// Tests the "clipboard-only" delivery fallback.
    case accessibilityDenied
    /// Per-capability override matrix. Use when an F-row test needs an
    /// exact mix the named cases above don't cover.
    case custom([Capability: PermissionStatus])
}

/// Pre-loaded entries the stub Keychain reports. Tests can precondition
/// stored API keys for flows that read them.
public enum KeychainSeed: Sendable {
    case empty
    /// Pre-populated entries (`account` → `value`). Ordered list rather
    /// than a dict so tests reading deterministic insertion order get it.
    case populated([(account: String, value: String)])
    /// Stub throws `KeychainError.osStatus(...)` on every `load`. Tests
    /// the F2 "Keychain throws" failure path
    /// (`agentic-testing.md` §0.5 F2 row).
    case throwsOnLoad
}

/// Virtual clock mode for timeout-sensitive flows. `.controlled` lets
/// the harness advance time deterministically; `.real` uses
/// `ContinuousClock.now`.
public enum ClockSeed: Sendable {
    case controlled
    case real
}

// MARK: - Audio source

/// What the stub `AudioCapture` should replay when the flow method
/// drives `start()` → records → `stop()`.
public enum AudioSource: Sendable {
    /// `.wav` file under `Tests/JotHarness/Fixtures/audio/`. The stub
    /// loads + decodes to 16 kHz mono Float32 (the canonical
    /// `AudioFormat` the live capture writes).
    case file(URL)
    /// Synthetic silence of the given duration. Used to exercise the
    /// "audio too short" / "below floor" rejection paths.
    case silence(duration: Duration)
    /// Raw 16 kHz mono Float32 PCM samples. The flow method passes
    /// these straight to `Transcriber.transcribe(_:)` (or its stub
    /// equivalent), bypassing AVFAudio decode.
    case samples([Float])
}

// MARK: - Provider seeds (cloud HTTP + Apple Intelligence)

/// LLM provider the flow method should route through. Each case carries
/// a per-provider response seed describing the canned answer the harness
/// should return for that call.
public enum ProviderSeed: Sendable {
    case openai(OpenAISeed)
    case anthropic(AnthropicSeed)
    case gemini(GeminiSeed)
    case ollama(OllamaSeed)
    case appleIntelligence(AppleIntelligenceSeed)
    case flavor1(Flavor1Seed)
}

/// OpenAI canned-response shapes. Mirrors the failure modes the harness
/// needs to drive — happy path, rate limit, 4xx with body (I2's
/// REDACT-ME-LEAK sentinel), tool-calling, stream chunking, timeout.
public enum OpenAISeed: Sendable {
    /// Single canned response body (non-streamed).
    case respondsWith(String)
    /// Streamed response — chunks are emitted as `data:` SSE lines.
    case respondsWithStreamChunks([String])
    /// HTTP 400 with the given body. Used by the I2 regression test to
    /// assert the body never reaches `result.pillError?.userMessage`.
    case respondsWith400(body: String)
    /// HTTP 401 — used by "missing/invalid API key" flow tests.
    case respondsWith401
    /// HTTP 429 — used by "rate limited" flow tests.
    case respondsWithRateLimit
    /// Streamed response containing a tool-call invocation for the given
    /// feature ID. Used by Ask Jot inline-tool-calling tests.
    case respondsWithToolCall(featureID: String)
    /// Returns no bytes for the given duration, then errors. Used by
    /// `firstByteOrTimeout` / streaming-stalled tests.
    case timesOut(after: Duration)
}

/// Anthropic canned-response shapes. Same shape as `OpenAISeed`;
/// distinct type so tests can compose-by-name.
public enum AnthropicSeed: Sendable {
    case respondsWith(String)
    case respondsWithStreamChunks([String])
    case respondsWith400(body: String)
    case respondsWith401
    case respondsWithRateLimit
    case respondsWithToolCall(featureID: String)
    case timesOut(after: Duration)
}

/// Gemini canned-response shapes.
public enum GeminiSeed: Sendable {
    case respondsWith(String)
    case respondsWithStreamChunks([String])
    case respondsWith400(body: String)
    case respondsWith401
    case respondsWithRateLimit
    case respondsWithToolCall(featureID: String)
    case timesOut(after: Duration)
}

/// Ollama canned-response shapes.
public enum OllamaSeed: Sendable {
    case respondsWith(String)
    case respondsWithStreamChunks([String])
    case respondsWith400(body: String)
    case respondsWith401
    case respondsWithRateLimit
    case respondsWithToolCall(featureID: String)
    case timesOut(after: Duration)
}

/// Sony PFB Enterprise (`JOT_FLAVOR_1`) canned-response shapes. JWT
/// behavior is modeled here so the auth-state flow tests (signed in /
/// signed out / 401 invalidate) can exercise the path.
public enum Flavor1Seed: Sendable {
    case respondsWith(String)
    /// Triggers `Flavor1Session.invalidate()` path.
    case respondsWith401
    case respondsWithSignedOutSentinel
    case timesOut(after: Duration)
}

// MARK: - Cleanup (Transform) seed

/// Seed for the cleanup / Transform pass in `dictate(audio:cleanup:)`.
/// Holds the canned LLM responses the cleanup pass should consume, plus
/// which provider routes the call.
public struct CleanupSeed: Sendable {
    /// Which provider routes the cleanup call. Defaults to
    /// `.appleIntelligence(.stub)` — the v1.5+ default for new installs.
    public var provider: ProviderSeed
    /// Canned responses the LLM stub should dequeue, one per cleanup
    /// call the flow makes. Most flows make exactly one call; longer
    /// lists are for retry / multi-call scenarios.
    public var responses: [String]
    /// `instruction` that `LLMClient.transform(transcript:)` would pass
    /// as the system prompt. nil leaves the live instruction in place.
    public var instructionOverride: String?

    public init(
        provider: ProviderSeed = .appleIntelligence(.stub),
        responses: [String],
        instructionOverride: String? = nil
    ) {
        self.provider = provider
        self.responses = responses
        self.instructionOverride = instructionOverride
    }

    /// Convenience for tests that just want a canned post-cleanup
    /// transcript via Apple Intelligence.
    public static func produces(_ transcript: String) -> CleanupSeed {
        CleanupSeed(
            provider: .appleIntelligence(.stub),
            responses: [transcript]
        )
    }
}

// MARK: - Ask Jot phase

/// Phase boundary inside `askJotVoice(...)` at which the harness can
/// cancel the in-flight task. Used by the I1 cancel-doesn't-cancel
/// regression (`cancelAfter: .condensing`).
public enum AskJotPhase: Sendable {
    /// Cancel during voice capture (before condensation begins).
    case audioCapture
    /// Cancel during condensation (the I1 target — Apple Intelligence
    /// `articulate` running over the spoken question).
    case condensing
    /// Cancel after the cloud streaming call has been issued.
    case cloudCall
    /// Cancel during the response stream from the cloud provider.
    case responseStream
}
