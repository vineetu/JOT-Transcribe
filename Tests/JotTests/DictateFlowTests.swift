import Foundation
import Testing
@testable import Jot

/// Phase 1.4 acceptance: drive the dictation flow end-to-end through the
/// live composition graph with the eight stub seams, and assert the
/// happy-path observable contract:
///   - `transcript == "hello world"` (the canned `StubTranscriber` value)
///   - `pasteboardHistory` contains the same text (the live
///     `DeliveryService` ran the clipboard sandwich against
///     `StubPasteboard`)
@MainActor
@Suite(.serialized)
struct DictateFlowTests {

    @Test func dictateHappyPath() async throws {
        // 1 second of silence at 16 kHz mono Float32. `StubTranscriber`
        // returns canned "hello world" regardless of sample content, so
        // silence is sufficient to drive the flow.
        let samples = [Float](repeating: 0, count: 16_000)

        let harness = try await JotHarness(seed: .default)
        let result = try await harness.dictate(audio: .samples(samples))

        #expect(result.transcript == "hello world")
        #expect(result.pasteboardHistory.contains { $0.text == "hello world" })
    }

    /// Phase 1 acceptance §3: the harness ships
    /// `Tests/JotHarness/Fixtures/audio/hello-world.wav` and can load
    /// it via `AudioSource.file(URL)`. This test resolves the fixture
    /// path off `#filePath` (PBXFileSystemSynchronizedRootGroup picks
    /// up Swift sources but not arbitrary resources, so `Bundle(for:)`
    /// can't see the wav — the source-tree path is the durable
    /// approach until Phase 3 adds a fileSystemSynchronizedExceptionSet
    /// entry).
    @Test func dictateHappyPathFromWavFixture() async throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()  // Tests/JotTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // <project root>
        let wav = projectRoot
            .appendingPathComponent("Tests/JotHarness/Fixtures/audio/hello-world.wav")

        let harness = try await JotHarness(seed: .default)
        let result = try await harness.dictate(audio: .file(wav))

        #expect(result.transcript == "hello world")
        #expect(result.pasteboardHistory.contains { $0.text == "hello world" })
    }
}

