import Combine
import Foundation
@testable import Jot

extension RecorderController {

    /// Test-only helper: suspend until `state` reaches `.idle` or `.error`,
    /// or `timeout` elapses. Subscribes to `$state` rather than busy-polling
    /// so it returns within one main-actor hop after the recorder settles.
    ///
    /// The dictation flow's terminal states are `.idle` (happy path —
    /// `RecorderController.runFlow` drops back to `.idle` after delivery)
    /// and `.error(...)` (any of the 6 surfaces in `runFlow` that set
    /// `state = .error(...)`). `.recording` / `.transcribing` /
    /// `.transforming` are non-terminal; this helper does not return on
    /// those.
    func awaitTerminalState(timeout: Duration) async throws {
        if isTerminal(state) { return }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            // Settled-state branch — completes `true` once the recorder
            // hits `.idle` or `.error`.
            group.addTask { @MainActor [weak self] in
                guard let self else { return true }
                var iterator = self.$state.values.makeAsyncIterator()
                while let next = await iterator.next() {
                    if Self.isTerminal(next) { return true }
                }
                return true
            }

            // Timeout branch — completes `false` after `timeout` elapses.
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

    private static func isTerminal(_ state: State) -> Bool {
        switch state {
        case .idle, .error: return true
        case .recording, .transcribing, .transforming: return false
        }
    }

    private func isTerminal(_ state: State) -> Bool {
        Self.isTerminal(state)
    }
}

/// Surface the harness uses for its own timeout failures. Distinct from
/// production errors so test assertions can match precisely.
enum HarnessTimeoutError: Error, Equatable {
    case timedOut
}

extension ArticulateController {

    /// Test-only helper: suspend until `state` reaches `.idle` or `.error`,
    /// or `timeout` elapses. Same shape as the `RecorderController`
    /// version above — Phase 1.5 articulate flows are driven through
    /// `controller.toggle()` (custom) and `controller.articulate()`
    /// (fixed); both produce a terminal `.idle` (success) or `.error`
    /// (failure) once the LLM call lands.
    func awaitTerminalState(timeout: Duration) async throws {
        if Self.isTerminal(state) { return }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return true }
                var iterator = self.$state.values.makeAsyncIterator()
                while let next = await iterator.next() {
                    if Self.isTerminal(next) { return true }
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

    private static func isTerminal(_ state: ArticulateState) -> Bool {
        switch state {
        case .idle, .error: return true
        case .capturing, .recording, .transcribing, .rewriting: return false
        }
    }
}
