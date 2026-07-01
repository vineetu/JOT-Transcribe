import SwiftUI

/// State-driven card that walks the user through setting up LM Studio as a
/// local AI provider on capable Macs. Rendered in Settings → AI and the
/// Setup Wizard's AI step, but only when physical RAM qualifies
/// (`LMStudioSetup.ramQualifies`). Hidden entirely when the orchestrator
/// reports `.unsupportedRAM`.
///
/// Badge is per-flavor (design F4): "Recommended (local)" on public,
/// "Local option" on Sony — so on a corporate machine it never reads as
/// competing with the IT-sanctioned PFB Enterprise default.
///
/// Every network / install action is behind an explicit button press —
/// `detectState()` runs on appear (read-only), but `install()` and
/// `downloadModel()` fire only from the CTAs here.
struct LMStudioRecommendCard: View {
    @EnvironmentObject private var config: LLMConfiguration
    @StateObject private var setup = LMStudioSetup()
    @State private var showInstallConfirm = false

    var body: some View {
        Group {
            if shouldShowCard {
                card
            } else {
                EmptyView()
            }
        }
        // Read-only detection on appear AND whenever the selected provider
        // changes — so the setup card surfaces right after the user picks
        // "LM Studio (local)", and never for other providers. Safe: never
        // spawns a process or contacts a remote host.
        .task(id: config.provider) {
            guard config.provider == .lmStudio else { return }
            await setup.detectState()
        }
    }

    /// The setup card is shown ONLY when the user has actually selected LM Studio
    /// AND it still needs setup (not installed / no model). Hidden for other
    /// providers, for under-RAM machines, and once configured — the provider's
    /// model picker then shows the chosen model.
    private var shouldShowCard: Bool {
        guard config.provider == .lmStudio else { return false }
        switch setup.state {
        case .unsupportedRAM, .configured: return false
        default: return true
        }
    }

    // MARK: - Card chrome

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stateContent
            if let warning = setup.warning {
                advisory(warning, color: .orange, symbol: "exclamationmark.triangle.fill")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .confirmationDialog(
            "Set up local AI with LM Studio?",
            isPresented: $showInstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Download & Install (~580 MB)") {
                Task { await setup.install() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jot will download and install LM Studio's local engine (~580 MB) from LM Studio's official installer over HTTPS. Afterward you can download the Qwen 3.5 9B model (~6 GB) separately. Nothing runs until you confirm, and everything stays on-device.")
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Run AI locally with LM Studio")
                        .font(.system(size: 13, weight: .semibold))
                    badge
                }
                Text("Fast on-device AI for Cleanup and Rewrite — nothing leaves your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var badge: some View {
        Text(badgeText)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.15))
            )
            .foregroundStyle(Color.accentColor)
    }

    private var badgeText: String {
        #if JOT_FLAVOR_1
        return "Local option"
        #else
        return "Recommended (local)"
        #endif
    }

    // MARK: - State-driven content

    @ViewBuilder
    private var stateContent: some View {
        switch setup.state {
        case .unsupportedRAM:
            EmptyView()

        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                Button("Set up local AI (LM Studio)…") {
                    showInstallConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Downloads and installs LM Studio's local engine (~580 MB). Verified against a pinned checksum before it runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .installing(let progress):
            determinateProgressRow(label: "Installing LM Studio (~580 MB)…", progress: progress)

        case .readyNoModel:
            modelDownloadSection

        case .downloadingModel(let progress):
            determinateProgressRow(label: "Downloading Qwen 3.5 9B (~6 GB)…", progress: progress)

        case .loadingModel:
            indeterminateProgressRow(label: "Loading model…")

        case .configured:
            advisory("Ready — Qwen 3.5 9B (local), thinking off.", color: .green, symbol: "checkmark.circle.fill")

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                advisory(message, color: .red, symbol: "xmark.circle.fill")
                Button("Try again") {
                    Task { await setup.detectState() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var modelDownloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let freeDisk = LMStudioSetup.freeDiskGB()
            if freeDisk < LMStudioSetup.diskFloorGB {
                advisory(
                    "Need about \(Int(LMStudioSetup.diskFloorGB)) GB of free disk to download the model (~6 GB). You have \(String(format: "%.1f", freeDisk)) GB free.",
                    color: .orange,
                    symbol: "externaldrive.badge.exclamationmark"
                )
            } else {
                Button("Download Qwen 3.5 9B (~6 GB)") {
                    Task { await setup.downloadModel(config: config) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if LMStudioSetup.isTightRAM {
                    advisory(
                        "This model works on your Mac, but may be slow under memory pressure (16–18 GB RAM).",
                        color: .secondary,
                        symbol: "info.circle"
                    )
                }
            }
        }
    }

    // MARK: - Reusable bits

    /// Determinate bar with a trailing percentage. Used for the model download,
    /// whose `progress` comes from on-disk bytes ÷ known total (monotonic) —
    /// NOT from `lms get`'s per-shard CLI percentages (which reset 0→100 per
    /// shard and made a value bar "grow crazy"; that's why this used to be
    /// indeterminate).
    private func determinateProgressRow(label: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                Spacer(minLength: 8)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
        }
    }

    /// Indeterminate bar for the quick post-download model load phase, which has
    /// no meaningful fraction to show.
    private func indeterminateProgressRow(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private func advisory(_ message: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(color == .secondary ? Color.secondary : color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
