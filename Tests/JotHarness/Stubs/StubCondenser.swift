import Foundation
@testable import Jot

/// Test-only `ChatbotCondenser` conformer that records start /
/// completion / cancellation. Used by the I1 regression test to
/// detect whether `ChatbotVoiceInput.cancel()` actually propagates
/// cancellation into the in-flight condensation Task.
///
/// **Why this stub instead of `StubAppleIntelligence`?** The
/// `ChatbotCondenser` protocol sits one level above the
/// `AppleIntelligenceClienting` seam — it's the abstraction
/// `ChatbotVoiceInput` calls directly. Stubbing at this layer
/// means the test asserts on the I1 surface (cancel propagation
/// to condensation) without going through the production
/// condenser's prompt/wrapper logic.
///
/// `condense(raw:)` does an interruptible `Task.sleep` followed by
/// an explicit `Task.checkCancellation()`. With the I1 bug present,
/// the parent `stopAndProcess()` Task is never stored / cancelled,
/// so the sleep completes and outcome lands as `.completed`. With
/// the bug fixed (Phase 2), cancel propagates → sleep throws →
/// outcome lands as `.cancelled`.
final class StubCondenser: ChatbotCondenser, @unchecked Sendable {

    enum Outcome: Sendable, Equatable {
        case completed(String)
        case cancelled
        case threw
    }

    private let lock = NSLock()
    private var _outcome: Outcome?

    /// The recorded outcome, or `nil` if `condense(raw:)` hasn't
    /// completed yet.
    var outcome: Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return _outcome
    }

    let cannedOutput: String
    let sleepDuration: Duration

    init(cannedOutput: String, sleepDuration: Duration = .milliseconds(50)) {
        self.cannedOutput = cannedOutput
        self.sleepDuration = sleepDuration
    }

    func condense(raw: String) async throws -> String {
        do {
            try await Task.sleep(for: sleepDuration)
            try Task.checkCancellation()
            lock.lock()
            _outcome = .completed(cannedOutput)
            lock.unlock()
            return cannedOutput
        } catch is CancellationError {
            lock.lock()
            _outcome = .cancelled
            lock.unlock()
            throw CancellationError()
        } catch {
            lock.lock()
            _outcome = .threw
            lock.unlock()
            throw error
        }
    }
}
