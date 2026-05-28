import SwiftUI

/// Top-of-page banners for the redesigned `TestStep`. Three variants —
/// Input Monitoring (proactive), Microphone (gating), Model not
/// downloaded (gating) — wired with their own CTAs.
///
/// The Input Monitoring banner is the design's headline fix: it
/// surfaces as soon as the user lands on the page (not after a 12 s
/// silent timer) whenever permission isn't `.granted`. The mic + model
/// banners reproduce the existing v1.12 remediationBanner pattern but
/// reposition above the focal chip so the chip can be the page's true
/// focal point.
struct WizardPermissionBanner: View {
    enum Variant: Equatable {
        case inputMonitoring(needsRelaunch: Bool)
        case microphone
        case modelNotDownloaded
    }

    let variant: Variant
    let onGoBackToPermissions: () -> Void
    let onGoBackToModel: () -> Void
    let onOpenSystemSettings: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                Text(subhead)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    primaryButton
                    secondaryButton
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bannerFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(bannerBorder, lineWidth: 1)
        )
    }

    // MARK: - Variant copy

    private var iconName: String {
        switch variant {
        case .inputMonitoring(let needsRelaunch):
            return needsRelaunch ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill"
        case .microphone, .modelNotDownloaded:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color { .orange }

    private var headline: String {
        switch variant {
        case .inputMonitoring(let needsRelaunch):
            return needsRelaunch
                ? "Restart needed to pick up Input Monitoring."
                : "Input Monitoring is required."
        case .microphone:
            return "Microphone permission is not granted."
        case .modelNotDownloaded:
            return "Model isn't downloaded yet."
        }
    }

    private var subhead: String {
        switch variant {
        case .inputMonitoring(let needsRelaunch):
            return needsRelaunch
                ? "macOS caches the old denial for this running process. Quit and relaunch Jot to pick up the grant."
                : "macOS won't deliver global key presses to Jot until you grant Input Monitoring."
        case .microphone:
            return "Jot needs the microphone before it can record. Grant it in System Settings → Privacy & Security → Microphone."
        case .modelNotDownloaded:
            return "Jot needs the Parakeet model on disk before it can transcribe. Go back to the Model step to download it."
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var primaryButton: some View {
        switch variant {
        case .inputMonitoring(let needsRelaunch):
            if needsRelaunch {
                Button("Restart Jot", action: onRestart)
                    .controlSize(.small)
            } else {
                Button("Open System Settings", action: onOpenSystemSettings)
                    .controlSize(.small)
            }
        case .microphone:
            Button("Go back to Permissions", action: onGoBackToPermissions)
                .controlSize(.small)
        case .modelNotDownloaded:
            Button("Go back to Model", action: onGoBackToModel)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch variant {
        case .inputMonitoring:
            Button("Go back to Permissions", action: onGoBackToPermissions)
                .controlSize(.small)
                .buttonStyle(.borderless)
        case .microphone, .modelNotDownloaded:
            EmptyView()
        }
    }

    // MARK: - Container

    private var bannerFill: Color { Color.orange.opacity(0.12) }
    private var bannerBorder: Color { Color.orange.opacity(0.30) }
}
