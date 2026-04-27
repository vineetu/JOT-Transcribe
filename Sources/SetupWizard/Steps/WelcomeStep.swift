import SwiftUI

struct WelcomeStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Jot")
                    .font(.system(size: 28, weight: .semibold))
                Text("Press a hotkey, speak, text appears.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                BulletRow(
                    symbol: "mic.fill",
                    title: "On-device dictation",
                    detail: "Parakeet runs on the Apple Neural Engine. Audio never leaves your Mac."
                )
                BulletRow(
                    symbol: "keyboard",
                    title: "Works in any app",
                    detail: "The default shortcut is ⌥Space — press it anywhere to start a recording."
                )
                BulletRow(
                    symbol: "lock.shield",
                    title: "No accounts, no telemetry",
                    detail: "This wizard walks through a few permissions Jot needs to paste text for you."
                )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onAppear {
            coordinator.setChrome(WizardStepChrome(
                primaryTitle: "Continue",
                canAdvance: true,
                isPrimaryBusy: false,
                showsSkip: false
            ))
        }
    }
}

private struct BulletRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
