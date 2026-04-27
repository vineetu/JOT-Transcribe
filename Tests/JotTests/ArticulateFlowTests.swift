import Foundation
import Testing
@testable import Jot

/// Phase 1.5 acceptance: drive `JotHarness.articulate(...)` and
/// `JotHarness.articulateCustom(...)` end-to-end through the live
/// `ArticulateController` graph. Two happy-path tests prove the
/// pipeline reaches the LLM and the rewrite lands on the stub
/// pasteboard. The third test (`i2_articulateLeaksHttpBody`) is the
/// failing regression for the I2 finding in `cleanup-roadmap.md`.
///
/// `.serialized` because all three tests share the
/// `StubURLProtocol.pending` class-level registry. Running them in
/// parallel races: one test's `enqueue()` can be consumed by another
/// test's URLSession that's mid-request. Sequential execution is
/// fast (each test is < 0.5s) and avoids the cross-pollution that
/// would otherwise require per-matcher uniqueness gymnastics.
@MainActor
@Suite(.serialized)
struct ArticulateFlowTests {

    // MARK: - Happy-path: fixed prompt

    @Test func articulateFixedHappyPath() async throws {
        let harness = try await JotHarness(seed: .default)
        let result = try await harness.articulate(
            selection: "hello world",
            provider: .ollama(.respondsWith("Articulated."))
        )

        #expect(result.pillError == nil)
        #expect(result.pastedText == "Articulated.")
    }

    // MARK: - Happy-path: custom voice instruction

    @Test func articulateCustomHappyPath() async throws {
        let harness = try await JotHarness(seed: .default)
        // 1 second of silence — `StubTranscriber` returns canned text
        // regardless of audio content (same convention as `dictate`).
        let instruction = AudioSource.samples([Float](repeating: 0, count: 16_000))
        let result = try await harness.articulateCustom(
            selection: "hello world",
            instruction: instruction,
            provider: .ollama(.respondsWith("HELLO WORLD"))
        )

        #expect(result.pillError == nil)
        #expect(result.pastedText == "HELLO WORLD")
    }

    // MARK: - I2 regression (currently FAILING — fixed in Phase 2)

    /// `cleanup-roadmap.md` I2: `LLMError.httpError`'s `errorDescription`
    /// interpolates the response body into the user-facing message,
    /// which `ArticulateController.runFixed`'s catch block (line 365)
    /// drops straight onto the pill via `state = .error(...)`.
    ///
    /// **This test FAILS today** — the sentinel `REDACT-ME-LEAK` makes
    /// it from a 400 response body all the way to
    /// `result.pillError?.userMessage`. Phase 2 fixes the leak by
    /// dropping `body` from the `errorDescription` interpolation; this
    /// test then passes.
    ///
    /// Wrapped in `withKnownIssue` so the suite stays green until
    /// Phase 2 lands. When the bug is fixed, `withKnownIssue` flips
    /// the suite red because the known issue cleared — that's the
    /// signal to remove the wrapper.
    @Test func i2_articulateNoHttpBodyLeak() async throws {
        let sentinel = "REDACT-ME-LEAK"
        let harness = try await JotHarness(seed: .default)

        let result = try await harness.articulate(
            selection: "Hello world.",
            provider: .ollama(.respondsWith400(body: sentinel))
        )

        // Phase 2 I2 fix landed: `LLMError.httpError.errorDescription`
        // no longer interpolates `body` into the user-facing message.
        // The body still gets recorded server-side via
        // `LLMClient.logLLMError → ErrorLog.redactedHTTPError`, which
        // captures only `bodyLength` (not contents).
        #expect(!(result.pillError?.userMessage.contains(sentinel) ?? false))
        #expect(!result.log.contains { $0.message.contains(sentinel) })
    }
}
