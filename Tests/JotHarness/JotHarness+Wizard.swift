import Foundation
@testable import Jot

extension JotHarness {

    /// Walk the Setup Wizard programmatically. Returns a
    /// `WizardOutcome` recording which steps were visited (in order)
    /// and whether the run reached `.markComplete()`.
    ///
    /// Phase 3 #31: gating rules now live on
    /// `SetupWizardCoordinator.canAdvance(from:given:)`. The harness
    /// builds the same `WizardState` the production view bodies build
    /// (permission grants from the stub seam + installed-models /
    /// primary-model from the holder) and asks the coordinator the
    /// same question — no inline mirror to drift.
    ///
    /// Spec source: `docs/plans/agentic-testing.md` §0.2.
    func runWizard(grants: PermissionGrants) async throws -> WizardOutcome {
        // 0. Apply the seed-level grant override on the harness's stub
        //    permissions. The wizard's coordinator-side gating reads
        //    these via the snapshot below.
        stubPermissions.update(grants)

        // 1. Snapshot+reset `FirstRunState.shared.setupComplete` so the
        //    harness run starts from "first run" and any production-side
        //    persistence after `markComplete()` is captured for the
        //    test then reverted.
        let priorSetupComplete = FirstRunState.shared.setupComplete
        FirstRunState.shared.setupComplete = false
        defer { FirstRunState.shared.setupComplete = priorSetupComplete }

        var didFinish = false

        // 2. Construct the coordinator with the harness's
        //    TranscriberHolder and a finish-callback that flips
        //    `didFinish`.
        let coordinator = SetupWizardCoordinator(
            startingAt: .welcome,
            transcriberHolder: services.transcriberHolder,
            audioCapture: services.audioCapture
        ) {
            didFinish = true
        }

        // 3. Walk the steps. At each step:
        //    - build the same `WizardState` the production view body
        //      would build (stub-permission grants + holder readings)
        //    - call `coordinator.advance(given:)`, which guards on
        //      `coordinator.canAdvance(from:given:)` internally
        //    - if the pointer didn't move, the step parked the wizard;
        //      break.
        var visited: [WizardStepID] = [coordinator.currentStep]
        while true {
            let step = coordinator.currentStep
            if step.isLast {
                coordinator.finish()
                break
            }
            let state = WizardState(
                permissionGrants: stubPermissions.statuses,
                installedModelIDs: services.transcriberHolder.installedModelIDs,
                primaryModelID: services.transcriberHolder.primaryModelID
            )
            coordinator.advance(given: state)
            if coordinator.currentStep == step {
                // advance() bailed — precondition not met. Wizard parks.
                break
            }
            visited.append(coordinator.currentStep)
        }

        return WizardOutcome(
            stepsVisited: visited,
            setupComplete: didFinish,
            permissionGrants: stubPermissions.statuses
        )
    }
}
