import SwiftUI

/// Identity of each wizard step. Ordered `allCases` drives the step indicator
/// and the Back/Continue transitions in `SetupWizardView`.
enum WizardStepID: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case permissions
    case model
    case microphone
    /// Step 5 — merged "your dictation shortcut" + "try your hotkey".
    /// The view (TestStep) shows the current binding (Caps Lock single-
    /// key + chord), inline controls to change either, and the live
    /// press-to-test surface. Previously these were two adjacent steps
    /// (`.shortcuts` + `.test`) — merged because users found it
    /// confusing to set a binding on one page and only verify it on
    /// the next.
    case test
    // Terminal "you're set up for the basics" card shown right after
    // the Test step succeeds. Skip is the suggested first-run action —
    // most users want to stop here and start using Jot. Continue reveals
    // the advanced steps (AI provider, LLM cleanup, Rewrite) for power
    // users who want to set those up inline. Either way the user can
    // return to Settings → General → Run Setup Wizard later.
    case done
    /// AI provider configuration (provider picker, key / URL / model
    /// fields, Test Connection). First step of the advanced flow now
    /// that vocabulary has moved out of the wizard — the rescoring
    /// pipeline is experimental and intentionally surfaced only in
    /// Settings → Vocabulary, not in onboarding.
    case aiProvider
    case cleanup
    case rewriteIntro
    /// Rewrite-with-voice demo #1 — "Make this into three bullet
    /// points." Drives the production voice-capture + transcribe +
    /// rewrite pipeline against a bundled draft.
    case rewriteWithVoiceBullets
    /// Rewrite-with-voice demo #2 — "Translate this to Spanish."
    /// Last step of the wizard.
    case rewriteWithVoiceSpanish

    var id: Int { rawValue }

    static var totalCount: Int { allCases.count }

    var isFirst: Bool { self == .welcome }
    var isLast: Bool { self == .rewriteWithVoiceSpanish }
}

/// Read-only snapshot of step presentation that the wizard shell consumes
/// without owning the step view. Each concrete step publishes one of these to
/// the coordinator so Back / Skip / Primary in the footer can render even
/// though the actual view body lives elsewhere.
struct WizardStepChrome: Equatable {
    var primaryTitle: LocalizedStringKey
    var canAdvance: Bool
    var isPrimaryBusy: Bool
    var showsSkip: Bool

    static let empty = WizardStepChrome(
        primaryTitle: "Continue",
        canAdvance: true,
        isPrimaryBusy: false,
        showsSkip: true
    )
}

/// Phase 3 #31: persistent state the wizard's step-gating rules consult.
/// Constructed by view bodies (from their `@EnvironmentObject` /
/// `@AppStorage` reads) and by the harness (from seed-driven stub state),
/// then handed to `SetupWizardCoordinator.canAdvance(from:given:)`. The
/// coordinator owns the rules; views and harness own the state-construction
/// boundary they each know how to fill.
///
/// Scope: this struct holds only **persistent** preconditions — values
/// that survive a view-tree teardown (granted permissions, installed
/// models, the active model id). View-only ephemeral state (e.g.
/// `isDownloading`, `phase == .recording`) stays in the view and is
/// AND-combined with the coordinator's answer when computing chrome.
struct WizardState: Sendable {
    let permissionGrants: [Capability: PermissionStatus]
    let installedModelIDs: Set<ParakeetModelID>
    let primaryModelID: ParakeetModelID
}
