import SwiftUI

/// Step 7 — informational intro to Auto-correct (Transform) with a live
/// demo against the user's actual Test-step dictation when available.
///
/// UX contract:
///   • Always shows the title, disclaimer card, and the "how to enable"
///     pointer — this is the stable teaching moment.
///   • If `coordinator.testTranscript` is non-empty, adds a demo block with
///     the raw transcript + a "Preview cleanup" button. On press we call
///     `LLMClient.transform(...)` with the user's current configuration
///     (Apple Intelligence by default on macOS 26+, cloud provider if
///     they've set one). The cleaned result appears beneath the raw block.
///   • If the preview fails (no API key for a cloud provider, Apple
///     Intelligence unavailable, etc.) we show the error inline — it's
///     informative, not blocking.
///   • No toggle, no in-wizard configuration. User still has to enable
///     Auto-correct from Settings → AI; this step just demonstrates what
///     it does.
struct CleanupStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var config: LLMConfiguration

    @State private var phase: PreviewPhase = .idle
    @State private var cleanedText: String = ""
    @State private var errorMessage: String?

    /// LLM dispatch resolved from coordinator-injected deps (set up by
    /// `WizardPresenter.present(...)`). Replaces the previous lazy
    /// `AppServices.live` reach + `preconditionFailure`, which compiled
    /// to a hard `brk #1` trap in release and took the whole app down
    /// when the live graph wasn't visible from the wizard window's view
    /// tree. Resolved per-call inside `runPreview()` so a Settings-side
    /// provider switch mid-wizard takes effect on the next press without
    /// re-presenting.
    private func resolveAIService() -> any AIService {
        AIServices.current(
            configuration: coordinator.llmConfiguration,
            urlSession: coordinator.urlSession,
            appleClient: coordinator.appleIntelligence,
            logSink: coordinator.logSink
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clean up your dictations")
                    .font(.system(size: 22, weight: .semibold))
                Text("Jot can polish each transcript after dictation — remove \u{201C}um\u{201D}s, fix grammar, and preserve your structure.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            if let transcript = coordinator.testTranscript,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                demoCard(for: transcript)
            }

            // Apple-Intelligence-specific quality caveat: only show
            // when the user actually chose Apple Intelligence (either
            // by accepting the on-device default or by switching to it
            // in the AI provider step). For any other provider, the
            // caveat is stale and would mislead.
            if config.provider == .appleIntelligence {
                disclaimerCard
            }

            settingsPointer

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "Continue",
                    canAdvance: true,
                    isPrimaryBusy: false,
                    showsSkip: false
                )
            )
        }
    }

    // MARK: - Demo

    @ViewBuilder
    private func demoCard(for transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            transcriptBlock(label: "RAW", text: transcript, color: .secondary)

            if phase == .success, !cleanedText.isEmpty {
                transcriptBlock(label: "CLEANED", text: cleanedText, color: .accentColor)
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(action: runPreview) {
                    HStack(spacing: 6) {
                        if phase == .loading {
                            ProgressView().controlSize(.small)
                        }
                        Text(buttonLabel)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(phase == .loading)
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private func transcriptBlock(label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .tracking(0.5)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
                .textSelection(.enabled)
        }
    }

    private var buttonLabel: LocalizedStringKey {
        switch phase {
        case .idle: return "Preview cleanup"
        case .loading: return "Cleaning up…"
        case .success: return "Run again"
        }
    }

    private func runPreview() {
        guard let transcript = coordinator.testTranscript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        phase = .loading
        cleanedText = ""
        errorMessage = nil
        let service = resolveAIService()
        Task {
            do {
                let result = try await service.transform(transcript: transcript)
                await MainActor.run {
                    cleanedText = result
                    phase = .success
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Preview failed: \(error.localizedDescription)"
                    phase = .idle
                }
            }
        }
    }

    // MARK: - Static cards

    private var disclaimerCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Apple Intelligence is still maturing")
                    .font(.system(size: 12, weight: .semibold))
                Text("Jot uses Apple Intelligence on-device by default — free, private, no API key. Apple's model handles short dictations well, but results can feel uneven on longer transcripts today. Quality will improve as Apple ships updates.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var settingsPointer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-correct is off by default.")
                .font(.system(size: 13, weight: .medium))
            Text("When you want to turn it on — or switch to a cloud provider (OpenAI, Anthropic, Gemini) — open Settings → AI.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}

private enum PreviewPhase: Equatable {
    case idle
    case loading
    case success
}
