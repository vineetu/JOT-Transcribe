import Foundation
@testable import Jot

/// Harness conformer for `LogSink`. Appends every `info` / `warn` /
/// `error` call to an in-memory `[LogEntry]` so flow methods can
/// surface the captured stream as `*Result.log` for assertions.
///
/// `entries(since:)` returns the slice strictly newer than the given
/// timestamp — flow methods snapshot a "test start" `Date` and read
/// only entries logged during the run, so cross-test pollution can't
/// leak into a result.
actor CapturingLogSink: LogSink {
    private var entries: [LogEntry] = []

    init() {}

    /// All captured entries, in arrival order.
    func all() -> [LogEntry] { entries }

    /// Entries logged strictly after `since`. Flow methods use this
    /// to scope captured output to the test window.
    func entries(since: Date) -> [LogEntry] {
        entries.filter { $0.timestamp > since }
    }

    /// Drop every captured entry. Used by flow-method `tearDown`.
    func reset() {
        entries.removeAll()
    }

    // MARK: - LogSink

    func info(component: String, message: String, context: [String: String]) async {
        entries.append(LogEntry(
            timestamp: Date(),
            level: .info,
            component: component,
            message: message,
            context: context
        ))
    }

    func warn(component: String, message: String, context: [String: String]) async {
        entries.append(LogEntry(
            timestamp: Date(),
            level: .warn,
            component: component,
            message: message,
            context: context
        ))
    }

    func error(component: String, message: String, context: [String: String]) async {
        entries.append(LogEntry(
            timestamp: Date(),
            level: .error,
            component: component,
            message: message,
            context: context
        ))
    }
}
