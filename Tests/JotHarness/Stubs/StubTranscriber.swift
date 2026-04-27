import Foundation
@testable import Jot

/// Harness conformer for `Transcribing`. Returns canned
/// `TranscriptionResult` values from a FIFO queue — no FluidAudio, no
/// CoreML, no model files.
///
/// **Queue semantics:** flow methods call `enqueue(asrSeed:)` once per
/// expected `transcribe(_:)` / `transcribeFile(_:)` call. Calls beyond
/// the queue depth throw `TranscriberError.busy` (matches the live
/// actor's overflow guard).
///
/// **Readiness:** `isReady` is `true` after `ensureLoaded()` is called
/// at least once, mirroring the live actor's "loaded once, hot
/// thereafter" semantics.
actor StubTranscriber: Transcribing {
    private var responses: [Result<TranscriptionResult, Error>]
    private var loaded = false

    init(responses: [TranscriptionResult] = []) {
        self.responses = responses.map { .success($0) }
    }

    /// Enqueue a canned response for the next `transcribe(_:)` /
    /// `transcribeFile(_:)` call.
    func enqueue(asrSeed: TranscriptionResult) {
        responses.append(.success(asrSeed))
    }

    /// Enqueue an error for the next call. Lets flow tests exercise the
    /// "model missing" / "audio too short" paths.
    func enqueue(failure: Error) {
        responses.append(.failure(failure))
    }

    /// Convenience: build a happy-path `TranscriptionResult` from a
    /// transcript string.
    static func canned(text: String) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            rawText: text,
            duration: 1.0,
            processingTime: 0.05,
            confidence: 0.95
        )
    }

    // MARK: - Transcribing

    func ensureLoaded() async throws {
        loaded = true
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptionResult {
        guard loaded else { throw TranscriberError.modelNotLoaded }
        return try dequeue()
    }

    func transcribeFile(_ url: URL) async throws -> TranscriptionResult {
        try await ensureLoaded()
        return try dequeue()
    }

    var isReady: Bool { loaded }

    // MARK: - Helpers

    private func dequeue() throws -> TranscriptionResult {
        guard !responses.isEmpty else {
            // Mirrors the live actor's overflow guard — refusing to
            // queue beyond the in-flight bound.
            throw TranscriberError.busy
        }
        let next = responses.removeFirst()
        switch next {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }
}
