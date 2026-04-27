import Foundation
@testable import Jot

// MARK: - Log primitives

/// Severity level for a captured `LogEntry`. Mirrors the `info` / `warn`
/// / `error` API exposed by `LogSink` in `Sources/App/LogSink.swift`.
public enum LogLevel: Sendable, Equatable {
    case info
    case warn
    case error
}

/// Severity bucket for a `PillError`. Production code distinguishes
/// transient/silent failures from the actionable kind that surface a
/// labeled affordance on the pill — keep that distinction so I2 / F-row
/// tests can assert against it.
public enum ErrorSeverity: Sendable, Equatable {
    /// Transient error that auto-dismisses with the standard linger
    /// (`PillViewModel.errorLinger`). No follow-up action.
    case transient
    /// Actionable error that lingers longer
    /// (`PillViewModel.actionableErrorLinger`) so a labeled button has
    /// time to be noticed and used.
    case actionable
}

/// Captured `LogSink` entry. The harness's `StubLogSink` records every
/// `info` / `warn` / `error` call as one of these; flow methods aggregate
/// the captured entries into `*Result.log` so I2-style regression tests
/// can assert "no leaked HTTP body in the log stream".
public struct LogEntry: Sendable, Equatable {
    public let timestamp: Date
    public let level: LogLevel
    public let component: String
    public let message: String
    public let context: [String: String]

    public init(
        timestamp: Date,
        level: LogLevel,
        component: String,
        message: String,
        context: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.level = level
        self.component = component
        self.message = message
        self.context = context
    }
}

// MARK: - Paste events

/// A clipboard write performed by `DeliveryService` while the test was
/// running. The stub `Pasteboarding` records every paste as a
/// `PasteEvent`, which `DictationResult.pasteboardHistory` exposes for
/// the test.
public struct PasteEvent: Sendable, Equatable {
    public let text: String
    public let timestamp: Date

    public init(text: String, timestamp: Date) {
        self.text = text
        self.timestamp = timestamp
    }
}

// MARK: - Pill error

/// Harness-captured snapshot of the user-visible failure state on the
/// pill. `userMessage` is the exact string the production code would
/// render — the I2 regression test asserts the LLM provider's raw HTTP
/// body never appears here.
public struct PillError: Sendable, Equatable {
    public let userMessage: String
    public let severity: ErrorSeverity

    public init(userMessage: String, severity: ErrorSeverity) {
        self.userMessage = userMessage
        self.severity = severity
    }
}

// MARK: - Dictation result

/// Result of `harness.dictate(...)`. Aggregates everything the test needs
/// to assert about a single dictation pipeline run.
///
/// `pillState` is the production `PillViewModel.PillState` — accessed via
/// `@testable import Jot`. The brief's "no reach into Sources/" rule
/// allows internal types through `@testable`.
public struct DictationResult: Sendable {
    /// The final transcript the user would see — post-cleanup if the
    /// flow method enabled cleanup, otherwise the raw transcript.
    public let transcript: String
    /// The terminal pill state at the end of the run. Ordered prior
    /// states are not retained here; tests that need timeline
    /// assertions read `log` instead.
    public let pillState: PillViewModel.PillState
    /// Every paste event the stub `Pasteboarding` recorded during the
    /// run, in order. Used by I2-style tests to assert "the transcript
    /// was written exactly once".
    public let pasteboardHistory: [PasteEvent]
    /// Set when cleanup (Transform) failed and the pipeline fell back
    /// to the raw transcript. nil on the happy path.
    public let transformError: Error?
    /// Captured log entries, in order.
    public let log: [LogEntry]

    public init(
        transcript: String,
        pillState: PillViewModel.PillState,
        pasteboardHistory: [PasteEvent],
        transformError: Error? = nil,
        log: [LogEntry] = []
    ) {
        self.transcript = transcript
        self.pillState = pillState
        self.pasteboardHistory = pasteboardHistory
        self.transformError = transformError
        self.log = log
    }
}

// MARK: - Articulate result

/// Result of `harness.articulate(...)` (both fixed and custom-instruction
/// variants). The pasted text is the user-visible output of the articulate
/// pipeline — delivered via the synthetic ⌘V → restore sandwich.
public struct ArticulateResult: Sendable {
    /// The text that landed in the editor via synthetic paste. nil on
    /// failure paths where the LLM never returned (`pillError` non-nil).
    public let pastedText: String?
    /// Set when the run surfaced a user-visible failure on the pill.
    /// `userMessage` is the exact string production would render — the
    /// I2 regression test asserts the LLM provider's raw HTTP body
    /// never appears here.
    public let pillError: PillError?
    /// Captured log entries.
    public let log: [LogEntry]

    public init(
        pastedText: String? = nil,
        pillError: PillError? = nil,
        log: [LogEntry] = []
    ) {
        self.pastedText = pastedText
        self.pillError = pillError
        self.log = log
    }
}

// MARK: - Ask Jot result

/// Result of `harness.askJotVoice(...)`. Captures the raw and condensed
/// transcripts plus the I1 regression flag.
public struct AskJotResult: Sendable {
    /// The raw voice-input transcript before condensation. nil when the
    /// run was cancelled before transcription completed.
    public let transcript: String?
    /// The condensed question after Apple Intelligence `articulate(...)`.
    /// nil when condensation was disabled, never started, or was cancelled
    /// (see `condensationTaskWasCancelled`).
    public let condensed: String?
    /// **I1 regression flag.** True iff the in-flight Apple Intelligence
    /// `articulate` (condensation) call observed cancellation before
    /// completing. The I1 cancel-doesn't-cancel test asserts this is
    /// `true` when the harness cancels with `cancelAfter: .condensing`.
    /// Production wiring must propagate `Task.cancel()` through the
    /// condensation seam — if the stub completes naturally, this stays
    /// false. (Drives `AppleIntelligenceSeed.blocksUntilCancelled`.)
    public let condensationTaskWasCancelled: Bool
    /// Captured log entries.
    public let log: [LogEntry]

    public init(
        transcript: String? = nil,
        condensed: String? = nil,
        condensationTaskWasCancelled: Bool,
        log: [LogEntry] = []
    ) {
        self.transcript = transcript
        self.condensed = condensed
        self.condensationTaskWasCancelled = condensationTaskWasCancelled
        self.log = log
    }
}

// MARK: - Wizard outcome

/// Result of `harness.runWizard(...)`. Captures which screens the wizard
/// visited (in order), whether it ran to completion, and the final
/// permission grant matrix — so F-row permission-flow tests in
/// `agentic-testing.md` §0.5 can assert "Mic denial parks the user on
/// the Permissions screen" by checking the last `stepsVisited` entry.
public struct WizardOutcome: Sendable, Equatable {
    /// Wizard screens visited during the run, in arrival order. The
    /// last entry is the screen the wizard terminated on — the
    /// happy-path run ends on `.done` (or further if the user opted
    /// into the advanced steps); a permission-blocked run ends on
    /// `.permissions`.
    public let stepsVisited: [WizardStepID]
    /// True iff the wizard reached the terminal "you're set up"
    /// state and dismissed itself.
    public let setupComplete: Bool
    /// The permission matrix at the end of the run. The wizard's job
    /// is to drive this from "all denied" toward "all granted"; tests
    /// assert the deltas.
    public let permissionGrants: [Capability: PermissionStatus]

    public init(
        stepsVisited: [WizardStepID],
        setupComplete: Bool,
        permissionGrants: [Capability: PermissionStatus]
    ) {
        self.stepsVisited = stepsVisited
        self.setupComplete = setupComplete
        self.permissionGrants = permissionGrants
    }
}
