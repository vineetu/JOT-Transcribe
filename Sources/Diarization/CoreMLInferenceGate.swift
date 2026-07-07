import Foundation

/// Shared cross-pipeline serialization primitive (design D6).
///
/// FluidAudio issue #661: running the ASR (`Transcriber`) and the offline
/// diarizer (`DiarizerHolder`) CoreML graphs concurrently corrupts shared
/// BNNS state (`EXC_BAD_ACCESS`). `Transcriber.isTranscribing` alone is
/// insufficient — it's a private flag inside the `Transcriber` actor that
/// only prevents overlapping *transcriptions*; it does nothing to stop a
/// diarize call from racing a live transcription.
///
/// `CoreMLInferenceGate` is a single, process-wide mutual-exclusion lock
/// that BOTH `Transcriber.transcribe(_:)` and `DiarizerHolder.process(_:)`
/// acquire around their `predict` calls, so at most one of the two CoreML
/// graphs ever runs at a time.
///
/// Implemented as a simple FIFO async semaphore of capacity 1. Ownership is
/// handed directly from `release()` to the next waiter (rather than
/// resetting `isLocked = false` and letting a fresh `acquire()` race the
/// resumed waiter) so there's no window where a third caller could slip in
/// between a release and its intended next-in-line waiter.
actor CoreMLInferenceGate {
    static let shared = CoreMLInferenceGate()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Acquire the gate, waiting FIFO if another CoreML graph is currently
    /// running. Always pair with `release()` (prefer `withLock(_:)`).
    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Release the gate. If a waiter is queued, ownership transfers
    /// directly to it (the lock stays held); otherwise the gate goes idle.
    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }

    /// Run `body` with the gate held, releasing it on every exit path
    /// (success, throw, or cancellation).
    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
