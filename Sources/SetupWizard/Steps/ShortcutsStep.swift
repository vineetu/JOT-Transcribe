import KeyboardShortcuts
import SwiftUI

struct ShortcutsStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your dictation shortcut")
                    .font(.system(size: 22, weight: .semibold))
                Text("Press this from any app to start and stop a recording.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Toggle recording")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Default is ⌥Space. Change it here if it clashes with another app.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyboardShortcuts.Recorder(for: .toggleRecording)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Text("You can change this and add Push-to-talk, Cancel, or Paste-last shortcuts any time in Settings → Shortcuts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            coordinator.setChrome(WizardStepChrome(
                primaryTitle: "Continue",
                canAdvance: true,
                isPrimaryBusy: false,
                showsSkip: true
            ))
        }
    }
}
