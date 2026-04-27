import Foundation

/// OS-boundary seam for cross-cutting structured logging. The live
/// conformer is `ErrorLog` (actor that writes to
/// `~/Library/Logs/Jot/jot.log` with 2 MB rotation); harness conformers
/// in `Tests/JotHarness/` capture entries in memory so flow tests can
/// assert on log content (notably I2's "HTTP body must not appear in
/// `result.log`").
///
/// **Scope of the Phase 0.10 migration is calibrated** per the brief:
/// only the operational hot-path consumers that fire during the four
/// `JotHarness` flow methods (`dictate`, `articulateCustom`,
/// `askJotVoice`, `runWizard`) thread the seam. Today that's:
///
/// - `RecorderController` — Transform-fallback log on dictation path.
/// - `ArticulateController` — every error-state path the user reaches.
/// - `DeliveryService` — clipboard-write / synthetic-paste failures.
/// - `LLMClient` — the I2-relevant redacted HTTP error log.
///
/// Other call sites (AudioCapture, Transcriber, AppleIntelligenceClient,
/// Library, Permissions, Setup wizard) keep using `ErrorLog.shared`
/// directly. They live behind seam types that the harness already
/// stubs (so live calls don't fire under the harness) or in surfaces
/// the harness doesn't touch (Library / Setup wizard). Phase 3's
/// `S3 errorAsync` shim collapses the remaining `Task { await
/// ErrorLog.shared.* }` boilerplate.
///
/// Method signatures mirror `ErrorLog`'s public surface verbatim so
/// `ErrorLog: LogSink` is a one-line conformance.
protocol LogSink: Sendable {
    func info(component: String, message: String, context: [String: String]) async
    func warn(component: String, message: String, context: [String: String]) async
    func error(component: String, message: String, context: [String: String]) async
}

extension LogSink {
    /// Default-context overloads so call sites that don't have structured
    /// fields don't have to pass `context: [:]` explicitly. Matches
    /// `ErrorLog`'s existing default-value pattern.
    func info(component: String, message: String) async {
        await info(component: component, message: message, context: [:])
    }
    func warn(component: String, message: String) async {
        await warn(component: component, message: message, context: [:])
    }
    func error(component: String, message: String) async {
        await error(component: component, message: message, context: [:])
    }
}
