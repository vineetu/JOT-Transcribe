import SwiftUI

/// Identity of each wizard step. Ordered `allCases` drives the step indicator
/// and the Back/Continue transitions in `SetupWizardView`.
enum WizardStepID: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case permissions
    case model
    case microphone
    case shortcuts
    case test
    // Terminal "you're set up for the basics" card shown right after
    // the Test step succeeds. Skip is the suggested first-run action —
    // most users want to stop here and start using Jot. Continue reveals
    // the advanced steps (AI provider, LLM cleanup, Rewrite) for power
    // users who want to set those up inline. Either way the user can
    // return to Settings → General → Run Setup Wizard later.
    case done
    /// Optional custom-vocabulary primer. First step of the advanced
    /// flow because it's the lightest-weight: no API keys, no network
    /// (except the optional boost-model download), no LLM dependency.
    /// Users who only want vocabulary can finish here and Skip the AI
    /// steps entirely.
    case vocabulary
    /// AI provider configuration (provider picker, key / URL / model
    /// fields, Test Connection). Lives between `.vocabulary` and
    /// `.cleanup` so users entering the advanced flow actively pick
    /// and verify a provider before they see the Cleanup / Rewrite
    /// demos run against it.
    case aiProvider
    case cleanup
    case rewriteIntro

    var id: Int { rawValue }

    static var totalCount: Int { allCases.count }

    var isFirst: Bool { self == .welcome }
    var isLast: Bool { self == .rewriteIntro }
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
