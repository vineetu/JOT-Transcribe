import SwiftUI

/// Root SwiftUI view for the setup wizard window. Implements the minimal
/// shell documented in `docs/design-requirements.md` → Frontend Design →
/// Wizard: header + step body + footer with Back / Skip / Primary, and a
/// horizontal step indicator.
struct SetupWizardView: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

            Divider().opacity(0.4)

            stepBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().opacity(0.4)

            footer
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Spacer()
                Text("Step \(coordinator.currentStep.rawValue + 1) of \(WizardStepID.totalCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            StepIndicator(current: coordinator.currentStep)
        }
    }

    // MARK: - Step body

    /// Scrollable so steps whose content exceeds the window height
    /// (Cleanup with its RAW/CLEANED demo, for example) don't push the
    /// footer offscreen. Static steps with short content render the same
    /// because the ScrollView collapses to natural height when the
    /// content fits.
    private var stepBody: some View {
        ScrollView {
            ZStack {
                currentStepView
                    .transition(transition)
                    .id(coordinator.currentStep)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(animation, value: coordinator.currentStep)
        }
    }

    @ViewBuilder
    private var currentStepView: some View {
        switch coordinator.currentStep {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .model: ModelStep()
        case .microphone: MicrophoneStep()
        case .shortcuts: ShortcutsStep()
        case .test: TestStep()
        case .cleanup: CleanupStep()
        case .articulateIntro: ArticulateIntroStep()
        }
    }

    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var animation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.28, dampingFraction: 0.85)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if !coordinator.currentStep.isFirst {
                Button("Back") { coordinator.back() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }

            Spacer()

            if coordinator.chrome.showsSkip {
                Button("Skip") { coordinator.skip() }
                    .buttonStyle(.borderless)
            }

            Button(action: handlePrimary) {
                HStack(spacing: 6) {
                    if coordinator.chrome.isPrimaryBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(coordinator.chrome.primaryTitle)
                }
                .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!coordinator.chrome.canAdvance || coordinator.chrome.isPrimaryBusy)
        }
    }

    private func handlePrimary() {
        if coordinator.currentStep.isLast {
            coordinator.finish()
        } else {
            coordinator.advance()
        }
    }
}

private struct StepIndicator: View {
    let current: WizardStepID

    var body: some View {
        HStack(spacing: 8) {
            ForEach(WizardStepID.allCases) { step in
                Circle()
                    .fill(color(for: step))
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
        }
    }

    private func color(for step: WizardStepID) -> Color {
        if step == current { return .accentColor }
        if step.rawValue < current.rawValue { return Color.accentColor.opacity(0.35) }
        return Color.secondary.opacity(0.25)
    }
}
