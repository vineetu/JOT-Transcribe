import AppKit
import Combine
import SwiftUI

/// Orchestrates the setup wizard's step pointer and footer state.
///
/// Step views hold their own local state (picked model, selected device,
/// download progress, recorded transcript); the coordinator owns the
/// **persistent** step-precondition rules (`canAdvance(from:given:)`) and
/// the chrome (`setChrome(_:)`).
///
/// Phase 3 #31: gating rules previously lived inside view-body
/// `updateChrome()` calls and the harness mirrored them inline in
/// `JotHarness+Wizard.canAdvance(from:grants:)`. Two parallel switch
/// statements drift silently when a step's rule changes. The rules now
/// live on this type; views call `coordinator.canAdvance(...)` to
/// derive `WizardStepChrome.canAdvance` (AND-combining with their own
/// view-only ephemeral state where needed), and the harness calls the
/// same function — no mirror.
///
/// `advance(given:)` consults the precondition before bumping the
/// pointer; `back()` is unconditional; `skip()` deliberately bypasses
/// the precondition (that's what "skip" means).
@MainActor
final class SetupWizardCoordinator: ObservableObject {
    @Published private(set) var currentStep: WizardStepID = .welcome
    @Published var chrome: WizardStepChrome = .empty

    /// Transcript from a successful Test step, persisted here so the Cleanup
    /// and Articulate intro steps can run a live demo against the user's real
    /// dictation. Nil when Test hasn't succeeded (skipped, failed, or user
    /// navigated past it without recording).
    @Published var testTranscript: String?

    /// Phase 3 F4: holder is the source of truth for the shared
    /// transcriber. `transcriber` is a computed read-through so a model
    /// swap mid-wizard propagates without re-binding the coordinator.
    let transcriberHolder: TranscriberHolder
    var transcriber: any Transcribing { transcriberHolder.transcriber }

    /// Phase 4 patch round 3: `AudioCapturing` seam threaded through so
    /// `TestStep.runTest()` records via the same seam-injected capture
    /// the production dictation flow uses (and the harness's
    /// `StubAudioCapture` consumes). Pre-fix `TestStep` constructed
    /// `AudioCapture()` directly, bypassing the seam.
    let audioCapture: any AudioCapturing

    private let onFinish: () -> Void

    init(
        startingAt step: WizardStepID = .welcome,
        transcriberHolder: TranscriberHolder,
        audioCapture: any AudioCapturing,
        onFinish: @escaping () -> Void
    ) {
        self.currentStep = step
        self.transcriberHolder = transcriberHolder
        self.audioCapture = audioCapture
        self.onFinish = onFinish
    }

    func goTo(_ step: WizardStepID) {
        currentStep = step
    }

    /// Coordinator-owned step-precondition rules. Phase 3 #31. Returns
    /// `true` iff the wizard's persistent state allows leaving `step`
    /// — this answers only the `WizardState`-derived part of "can the
    /// Primary button advance now?". View-only ephemeral conditions
    /// (download in flight, test recording in progress) are AND-combined
    /// at the view layer when computing chrome.
    ///
    /// Exhaustive on `WizardStepID` — the compiler is the checklist for
    /// "did I add a case?" when a new step lands.
    func canAdvance(from step: WizardStepID, given state: WizardState) -> Bool {
        switch step {
        case .welcome:
            return true
        case .permissions:
            // Mic is the only required capability today: Input Monitoring
            // and Accessibility have soft fallbacks (clipboard-only paste,
            // hotkey via menu bar). Matches `PermissionsStep.updateChrome`
            // pre-#31 behavior verbatim.
            return state.permissionGrants[.microphone] == .granted
        case .model:
            return state.installedModelIDs.contains(state.primaryModelID)
        case .microphone, .shortcuts, .test:
            // Microphone (device picker), Shortcuts (defaults pre-set),
            // and Test (3-second recording is optional) all advance
            // unconditionally. View-side may temporarily hold the
            // Primary disabled while a recording is in flight — that's
            // chrome-level state, not a precondition.
            return true
        case .done, .cleanup, .articulateIntro:
            // Post-basics walkthrough steps. No persistent precondition.
            return true
        }
    }

    /// Advance the pointer iff `canAdvance(from:given:)` passes. Falls
    /// through to `finish()` when called on the last step. Callers
    /// already disable the Primary button via `chrome.canAdvance`, so
    /// the guard is defense-in-depth — but it makes the harness path
    /// (which doesn't render a view) honor the same rule.
    func advance(given state: WizardState) {
        guard canAdvance(from: currentStep, given: state) else { return }
        guard let next = WizardStepID(rawValue: currentStep.rawValue + 1) else {
            finish()
            return
        }
        currentStep = next
    }

    func back() {
        guard let prev = WizardStepID(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    /// Skip the current step. Bypasses `canAdvance(from:given:)` —
    /// that's the contract of "Skip" (the user is acknowledging they
    /// can't or don't want to satisfy the precondition right now).
    func skip() {
        if currentStep.isLast {
            finish()
            return
        }
        guard let next = WizardStepID(rawValue: currentStep.rawValue + 1) else {
            finish()
            return
        }
        currentStep = next
    }

    func finish() {
        FirstRunState.shared.markComplete()
        onFinish()
    }

    /// Steps call this from `onAppear` / `onChange` to publish their footer
    /// chrome. Kept as a single setter (rather than N published fields) so the
    /// coordinator's contract is symmetric across steps.
    func setChrome(_ chrome: WizardStepChrome) {
        self.chrome = chrome
    }
}
