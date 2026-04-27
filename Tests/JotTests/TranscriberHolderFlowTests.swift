import Foundation
import Testing
@testable import Jot

/// Phase 3 F4 verification (`docs/plans/multi-language-readiness.md` F4 +
/// `docs/plans/agentic-testing.md` §0.4).
///
/// **Scope:** confirm the holder is reachable through `services`,
/// reflects the default model id on a fresh harness, that a dictate
/// call leaves the holder's `primaryModelID` unchanged, and (Phase 4)
/// that `setPrimary(.tdt_0_6b_ja)` mid-flow successfully swaps the
/// inner `Transcribing` instance and the next dictate runs through
/// the swapped instance.
@MainActor
@Suite(.serialized)
struct TranscriberHolderFlowTests {

    @Test func transcriberHolder_exposedAndStableAcrossDictate() async throws {
        let harness = try await JotHarness(seed: .default)

        #expect(harness.services.transcriberHolder.primaryModelID == .tdt_0_6b_v3)

        let samples = [Float](repeating: 0, count: 16_000)
        let result = try await harness.dictate(audio: .samples(samples))
        #expect(result.transcript == "hello world")

        // Holder still reports the default after the flow ran.
        #expect(harness.services.transcriberHolder.primaryModelID == .tdt_0_6b_v3)
    }

    /// Phase 4 (`docs/plans/japanese-support.md` §A "Single-model
    /// invariant"): verify the holder swaps cleanly between two
    /// dictations. The harness's `transcriberFactory` is captured to
    /// always return the same `StubTranscriber` instance — model swaps
    /// on the stub are no-ops at the ASR-call level, but the holder's
    /// observable state must still flip and persist to the suite-scoped
    /// `UserDefaults`. The second dictate succeeds, proving
    /// `transcriber` is hot after the swap.
    @Test func transcriberHolder_swapBetweenDictations() async throws {
        let harness = try await JotHarness(seed: .default)

        #expect(harness.services.transcriberHolder.primaryModelID == .tdt_0_6b_v3)

        let samples = [Float](repeating: 0, count: 16_000)
        let first = try await harness.dictate(audio: .samples(samples))
        #expect(first.transcript == "hello world")

        await harness.services.transcriberHolder.setPrimary(.tdt_0_6b_ja)
        #expect(harness.services.transcriberHolder.primaryModelID == .tdt_0_6b_ja)

        // The swap must also re-run the inner transcriber's
        // `ensureLoaded()` — otherwise the next dictate call would
        // throw `TranscriberError.modelNotLoaded` on the stub.
        let second = try await harness.dictate(audio: .samples(samples))
        #expect(second.transcript == "hello world")
        #expect(harness.services.transcriberHolder.primaryModelID == .tdt_0_6b_ja)
    }
}
