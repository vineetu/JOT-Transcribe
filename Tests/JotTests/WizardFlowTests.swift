import Foundation
import Testing
@testable import Jot

/// Phase 1.7 acceptance: drive `JotHarness.runWizard(grants:)`
/// through the live `SetupWizardCoordinator` and assert the gating
/// logic each step view enforces.
///
/// `.serialized` because the wizard mutates `FirstRunState.shared`
/// (`@AppStorage`-backed, process-global). Same isolation rationale
/// as the other harness suites.
@MainActor
@Suite(.serialized)
struct WizardFlowTests {

    // MARK: - Happy path: all permissions granted → walks to completion

    @Test func runWizardAllGrantedReachesCompletion() async throws {
        let harness = try await JotHarness(seed: .default)

        let outcome = try await harness.runWizard(grants: .allGranted)

        // Welcome → Permissions → Model → Microphone → Shortcuts → Test
        // → Done → Cleanup → ArticulateIntro (terminal). The 6 basic
        // steps from the brief are the prefix; `.done` onward are the
        // optional advanced steps that always advance.
        #expect(outcome.stepsVisited.first == .welcome)
        #expect(outcome.stepsVisited.contains(.permissions))
        #expect(outcome.stepsVisited.contains(.model))
        #expect(outcome.stepsVisited.contains(.microphone))
        #expect(outcome.stepsVisited.contains(.shortcuts))
        #expect(outcome.stepsVisited.contains(.test))
        #expect(outcome.setupComplete == true)
    }

    // MARK: - Mic denied → blocks at Permissions

    @Test func runWizardMicDeniedBlocksAtPermissions() async throws {
        let harness = try await JotHarness(seed: .default)

        let outcome = try await harness.runWizard(grants: .micDenied)

        // Welcome advances unconditionally. Permissions then blocks
        // because `permissions.statuses[.microphone] != .granted`.
        // The wizard parks on `.permissions` — last visited step
        // is the gate.
        #expect(outcome.stepsVisited == [.welcome, .permissions])
        #expect(outcome.setupComplete == false)
        #expect(outcome.permissionGrants[.microphone] == .denied)
    }
}
