import SwiftUI

struct PermissionsStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @ObservedObject private var permissions = PermissionsService.shared
    @State private var showResetAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant permissions")
                    .font(.system(size: 22, weight: .semibold))
                Text("Jot needs three macOS permissions to record your voice and paste text in other apps.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                PermissionRow(
                    capability: .microphone,
                    title: "Microphone",
                    subtitle: "Required. Lets Jot hear what you say.",
                    status: permissions.statuses[.microphone] ?? .notDetermined,
                    primaryLabel: "Grant"
                )
                PermissionRow(
                    capability: .inputMonitoring,
                    title: "Input Monitoring",
                    subtitle: "Lets the ⌥Space global hotkey fire from any app.",
                    status: permissions.statuses[.inputMonitoring] ?? .notDetermined,
                    primaryLabel: "Open System Settings"
                )
                PermissionRow(
                    capability: .accessibilityPostEvents,
                    title: "Accessibility",
                    subtitle: "Lets Jot paste text for you via synthetic ⌘V.",
                    status: permissions.statuses[.accessibilityPostEvents] ?? .notDetermined,
                    primaryLabel: "Open System Settings"
                )
            }

            if anyNeedsRelaunch {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text("Jot needs to relaunch before it can see the new permission.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Jot") { RestartHelper.relaunchApp() }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(role: .destructive) {
                    showResetAlert = true
                } label: {
                    Label("Reset permissions…", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert("Reset permissions?", isPresented: $showResetAlert) {
            Button("Reset and Relaunch", role: .destructive, action: resetPermissions)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes all permissions for Jot and relaunches the app. You will be prompted again.")
        }
        .onAppear {
            permissions.refreshAll()
            updateChrome()
        }
        .onReceive(permissions.$statuses) { _ in updateChrome() }
    }

    private var anyNeedsRelaunch: Bool {
        let interesting: [Capability] = [.inputMonitoring, .accessibilityPostEvents]
        return interesting.contains { permissions.statuses[$0] == .requiresRelaunch }
    }

    private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jot.Jot"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", bundleID]
        try? task.run()
        task.waitUntilExit()
        RestartHelper.relaunchApp()
    }

    private func updateChrome() {
        let micGranted = permissions.statuses[.microphone] == .granted
        coordinator.setChrome(WizardStepChrome(
            primaryTitle: "Continue",
            canAdvance: micGranted,
            isPrimaryBusy: false,
            showsSkip: false
        ))
    }
}

private struct PermissionRow: View {
    let capability: Capability
    let title: String
    let subtitle: String
    let status: PermissionStatus
    let primaryLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    StatusPill(status: status)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if status != .granted {
                Button(primaryLabel) {
                    Task { await PermissionsService.shared.request(capability) }
                }
                .controlSize(.small)
            }
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
    }
}

private struct StatusPill: View {
    let status: PermissionStatus

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous).fill(background)
            )
            .foregroundStyle(foreground)
    }

    private var label: String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not set"
        case .requiresRelaunch: return "Needs restart"
        }
    }

    private var background: Color {
        switch status {
        case .granted: return Color.green.opacity(0.18)
        case .denied: return Color.red.opacity(0.18)
        case .notDetermined: return Color.secondary.opacity(0.18)
        case .requiresRelaunch: return Color.orange.opacity(0.20)
        }
    }

    private var foreground: Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        case .requiresRelaunch: return .orange
        }
    }
}
