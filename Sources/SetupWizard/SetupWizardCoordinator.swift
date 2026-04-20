import AppKit
import Combine
import SwiftUI

/// Orchestrates the setup wizard's step pointer and footer state.
///
/// Step views hold their own local state (picked model, selected device,
/// download progress, recorded transcript); the coordinator only knows which
/// step is active and what the footer should say. Each step updates the
/// shared `chrome` via `setChrome(_:)` so the bottom bar stays in sync with
/// per-step conditions (e.g. Primary disabled until microphone granted).
///
/// `advance()` / `back()` / `skip()` are no-arg bridges that simply move the
/// pointer — the step's own `onAdvance` closure (if any) runs first via the
/// footer's Primary action. Finish marks first-run complete and dismisses.
@MainActor
final class SetupWizardCoordinator: ObservableObject {
    @Published private(set) var currentStep: WizardStepID = .welcome
    @Published var chrome: WizardStepChrome = .empty

    /// Transcript from a successful Test step, persisted here so the Cleanup
    /// and Articulate intro steps can run a live demo against the user's real
    /// dictation. Nil when Test hasn't succeeded (skipped, failed, or user
    /// navigated past it without recording).
    @Published var testTranscript: String?

    /// The long-lived `Transcriber` owned by `RecorderController`, injected at
    /// construction. Steps (notably `TestStep`) reuse this instance so that
    /// the ANE warm-up performed during the wizard leaves the recorder ready
    /// to transcribe the first post-wizard hotkey press — without this, the
    /// wizard and the recorder each load their own `AsrManager`, and the
    /// recorder's remains unloaded until relaunch.
    let transcriber: Transcriber

    private let onFinish: () -> Void

    init(
        startingAt step: WizardStepID = .welcome,
        transcriber: Transcriber,
        onFinish: @escaping () -> Void
    ) {
        self.currentStep = step
        self.transcriber = transcriber
        self.onFinish = onFinish
    }

    func goTo(_ step: WizardStepID) {
        currentStep = step
    }

    func advance() {
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

    func skip() {
        if currentStep.isLast {
            finish()
        } else {
            advance()
        }
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
