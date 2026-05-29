import SwiftUI

/// Terminal card shown right after the Test step succeeds.
///
/// Acts as a junction: first-run users hit Skip to exit and start using
/// Jot immediately, power users hit Continue to set up the optional LLM
/// cleanup + Rewrite intro inline. Either path reaches the same
/// end state — Skip dismisses now, Continue walks through the advanced
/// pair and then dismisses at RewriteIntro's Finish. Advanced
/// configuration is always reachable later from Settings or by re-running
/// this wizard.
///
/// v1.14: uses the unified footer with `skipIsPrimary: true` and
/// `skipExitsWizard: true`. Skip is the borderedProminent blue button
/// on the right (recommended action — most users want to start using
/// Jot now), Continue is the subtle borderless button on the left
/// (power-user path into the advanced flow).
struct DoneStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @ObservedObject private var permissions = PermissionsService.shared

    /// Reads the user's currently-bound dictation shortcut so the body
    /// copy matches what they actually have. For fresh installs this
    /// resolves to "Caps Lock"; returning users see whatever they
    /// bound previously.
    private var currentShortcutLabel: String {
        SingleKeyMigration.effectiveBindingLabel(for: .toggleRecording) ?? "your hotkey"
    }

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

                Text("Press \(currentShortcutLabel) anywhere to dictate. Speech becomes text at your cursor. That's the whole feature.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            advancedHintCard

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .onAppear {
            // v1.14: unified footer. `skipIsPrimary` flips the layout so
            // Skip is the prominent blue button; `skipExitsWizard` makes
            // it call `finish()` instead of advancing to the AI provider
            // step.
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "Continue",
                    canAdvance: true,
                    isPrimaryBusy: false,
                    showsSkip: true,
                    skipIsPrimary: true,
                    skipExitsWizard: true
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
                Text("More power-user options — including LLM cleanup, voice-driven rewrite, and custom vocabulary — live behind the Advanced toggle in Settings → General. Flip it on whenever you're curious; flip it off again to keep the surface minimal.")
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

}
