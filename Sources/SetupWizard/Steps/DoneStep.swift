import SwiftUI

/// Terminal card shown right after the Test step succeeds.
///
/// Acts as a junction: first-run users hit Skip to exit and start using
/// Jot immediately, power users hit Continue to set up the optional LLM
/// cleanup + Articulate intro inline. Either path reaches the same
/// end state — Skip dismisses now, Continue walks through the advanced
/// pair and then dismisses at ArticulateIntro's Finish. Advanced
/// configuration is always reachable later from Settings or by re-running
/// this wizard.
///
/// The step hides the standard Skip/Continue footer chrome and presents
/// its own two buttons, because the semantics here are intentionally
/// different from elsewhere: "Skip" here means "done, close the wizard,"
/// not "skip this step and proceed to the next."
struct DoneStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @ObservedObject private var permissions = PermissionsService.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("You're set up for the basics")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Press ⌥Space anywhere to dictate. Speech becomes text at your cursor. That's the whole feature.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            advancedHintCard

            Spacer(minLength: 0)

            buttons
        }
        .padding(.vertical, 16)
        .onAppear {
            // Hide the footer — this step's two buttons replace it.
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "",
                    canAdvance: false,
                    isPrimaryBusy: false,
                    showsSkip: false
                )
            )
        }
    }

    private var advancedHintCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced, for later")
                    .font(.system(size: 12, weight: .semibold))
                Text("LLM cleanup, voice-driven rewrite (Articulate), and custom vocabulary are ready whenever you're curious — in Settings, or by re-running this wizard from Settings → General.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
        .padding(12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            // Continue to advanced. Bordered / secondary — power-user path.
            Button {
                coordinator.advance(given: WizardState(
                    permissionGrants: permissions.statuses,
                    installedModelIDs: transcriberHolder.installedModelIDs,
                    primaryModelID: transcriberHolder.primaryModelID
                ))
            } label: {
                Text("Continue")
                    .frame(minWidth: 120, minHeight: 32)
            }
            .controlSize(.large)

            // Skip = close the wizard. Suggested / primary — the
            // recommended first-run action.
            Button {
                coordinator.finish()
            } label: {
                Text("Skip")
                    .frame(minWidth: 120, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
    }
}
