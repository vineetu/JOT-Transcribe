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
    // the advanced steps (LLM cleanup, Articulate) for power users who
    // want to set those up inline. Either way the user can return to
    // Settings → General → Run Setup Wizard later.
    case done
    case cleanup
    case articulateIntro

    var id: Int { rawValue }

    static var totalCount: Int { allCases.count }

    var isFirst: Bool { self == .welcome }
    var isLast: Bool { self == .articulateIntro }
}

/// Read-only snapshot of step presentation that the wizard shell consumes
/// without owning the step view. Each concrete step publishes one of these to
/// the coordinator so Back / Skip / Primary in the footer can render even
/// though the actual view body lives elsewhere.
struct WizardStepChrome: Equatable {
    var primaryTitle: String
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
