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
            switch setup.state {
            case .unsupportedRAM:
                // Below the RAM gate — don't surface the recommendation at all.
                EmptyView()
            default:
                card
            }
        }
        .task {
            // Read-only detection. Safe on appear — never spawns a process
            // or contacts a remote host.
            await setup.detectState()
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
            Text("Jot will download and install LM Studio's local engine (~580 MB, checksum-verified) on this Mac. Afterward you can download the Qwen 3.5 9B model (~6 GB) separately. Nothing runs until you confirm, and everything stays on-device.")
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
                Text("Fast on-device AI for Cleanup and Rewrite — nothing leaves your Mac. Pinned to LM Studio \(LMStudioSetup.pinnedLlmsterVersion).")
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
            progressRow(label: "Installing LM Studio (~580 MB)…", progress: progress)

        case .readyNoModel:
            modelDownloadSection

        case .downloadingModel(let progress):
            progressRow(label: "Downloading Qwen 3.5 9B (~6 GB, a few minutes)…", progress: progress)

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

    @ViewBuilder
    // `progress` is intentionally ignored: `lms get` / `install.sh` print a
    // fresh NN% per shard/file, so a value-driven bar fills, resets, and refills
    // ("growing crazy"). We can't reliably aggregate multi-file percentages, so
    // we show a calm INDETERMINATE bar instead of a misleading fake number.
    private func progressRow(label: String, progress: Double) -> some View {
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
