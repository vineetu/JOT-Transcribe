import Foundation

/// Shared streaming interface for the Nemotron engines — English
/// (`NemotronStreamingTranscriber`) and multilingual
/// (`NemotronMultilingualStreamingTranscriber`). Both are actors with
/// identical streaming control flow (ensure-load → start → enqueue → finish,
/// plus a one-shot path), so `DualPipelineTranscriber` holds either behind
/// this protocol and keeps a single set of engine switch arms instead of
/// duplicating each one per concrete type.
protocol NemotronStreamingEngine: Sendable {
    var isReady: Bool { get async }
    func ensureLoaded() async throws
    func start(generation: UInt64, onPartial: @escaping @Sendable (String, UInt64) -> Void) async
    nonisolated func enqueue(samples: [Float])
    func finish() async throws -> String
    func transcribeOneShot(_ samples: [Float]) async throws -> String
    func cancel() async
}
