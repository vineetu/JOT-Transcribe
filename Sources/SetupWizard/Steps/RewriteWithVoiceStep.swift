import SwiftUI

/// Configurable Rewrite-with-Voice wizard step. Runs twice (bullets +
/// Spanish) so the user sees two flavors of voice-instructed rewrite.
///
/// Wizard semantics (intentionally simpler than production):
///   • One button. Click it → the wizard runs
///     `LLMClient.rewrite(sample, suggestedInstruction)` and shows the
///     result inline. No mic capture, no selection requirement.
///   • Pressing the user's Rewrite-with-Voice hotkey while this step is
///     on screen also fires the same demo via `HotkeyRouter.setRewriteOverride`.
///
/// Why no voice capture in the wizard: the production voice flow
/// (mic → transcribe → LLM) has too many failure modes for a demo
/// surface — too-quiet speech returns empty, simultaneous AVAudioEngine
/// use across wizard steps races, etc. The teaching here is "see what
/// it does"; the footer line tells the user how to actually use the
/// feature in real apps.
struct RewriteWithVoiceStep: View {
    let config: Config

    @EnvironmentObject private var coordinator: SetupWizardCoordinator

    @State private var phase: DemoPhase = .idle
    @State private var rewriteResult: String = ""
    @State private var errorMessage: String?
    @State private var bindingsRefreshToken: Int = 0

    @AppStorage("jot.hotkey.rewriteWithVoice.singleKey") private var rewriteWithVoiceSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.rewriteWithVoice.triggerType") private var rewriteWithVoiceTriggerTypeRaw: String = ""

    struct Config {
        let title: String
        let subtitle: String
        let sample: String
        /// Instruction text the wizard hands to the LLM and shows the
        /// user as "Try saying: …". The wizard never actually records
        /// the user — this is the literal string sent.
        let suggestedInstruction: String
        let isLastStep: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            sampleCard

            instructionCard

            resultCard

            realAppFooter

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: config.isLastStep ? "Done" : "Continue",
                    canAdvance: true,
                    isPrimaryBusy: false,
                    showsSkip: true
                )
            )
            // Hotkey commandeer: pressing the user's rewrite hotkey on
            // this page also fires the demo. Same destination as the
            // button — keeps the two affordances aligned.
            coordinator.hotkeyRouter?.setRewriteOverride {
                Task { @MainActor in runDemo() }
            }
        }
        .onDisappear {
            coordinator.hotkeyRouter?.clearRewriteOverride()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(config.title)
                .font(.system(size: 22, weight: .semibold))
            Text(config.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }

    // MARK: - Sample card

    @ViewBuilder
    private var sampleCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DRAFT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Text(config.sample)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Instruction + button

    @ViewBuilder
    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13))
                Text("Instruction:")
                    .font(.system(size: 13, weight: .semibold))
                Text("\u{201C}\(config.suggestedInstruction)\u{201D}")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                Button(action: { runDemo() }) {
                    HStack(spacing: 6) {
                        if phase == .running {
                            ProgressView().controlSize(.small)
                        }
                        Text(buttonLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(phase == .running)
                Spacer(minLength: 0)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var buttonLabel: LocalizedStringKey {
        switch phase {
        case .idle:    return "Try it"
        case .running: return "Rewriting…"
        case .done:    return "Run again"
        case .failed:  return "Try again"
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultCard: some View {
        if phase == .done, !rewriteResult.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("REWRITE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                Text(rewriteResult)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Real-app footer

    /// Footer line teaching the production gesture — distinct from the
    /// wizard-only button above. Reads the user's actual bound
    /// Rewrite-with-Voice hotkey (single-key or chord) and renders the
    /// first one available as the keycap to press.
    @ViewBuilder
    private var realAppFooter: some View {
        let hotkey = primaryHotkeyLabel
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
            Text("In real apps:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("select your text, then press")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let hotkey {
                Text(hotkey)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                    )
                Text("and speak the instruction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("your Rewrite-with-Voice hotkey (set one in Settings → Shortcuts) and speak the instruction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// First-bound trigger for `.rewriteWithVoice` — single-key wins
    /// over chord because it's the v1.9+ first-class default. Returns
    /// `nil` only when both are unbound (rare; user explicitly cleared
    /// both defaults).
    private var primaryHotkeyLabel: String? {
        _ = bindingsRefreshToken
        _ = rewriteWithVoiceSingleKey
        _ = rewriteWithVoiceTriggerTypeRaw
        return SingleKeyMigration.effectiveBindingLabel(for: .rewriteWithVoice)
    }

    // MARK: - Demo runner

    @MainActor
    private func runDemo() {
        guard phase != .running else { return }
        phase = .running
        rewriteResult = ""
        errorMessage = nil
        let service = resolveAIService()
        Task {
            do {
                let result = try await service.rewrite(
                    selectedText: config.sample,
                    instruction: config.suggestedInstruction
                )
                await MainActor.run {
                    rewriteResult = result
                    phase = .done
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Rewrite failed: \(error.localizedDescription)"
                    phase = .failed
                }
            }
        }
    }

    private func resolveAIService() -> any AIService {
        AIServices.current(
            configuration: coordinator.llmConfiguration,
            urlSession: coordinator.urlSession,
            appleClient: coordinator.appleIntelligence,
            logSink: coordinator.logSink
        )
    }
}

fileprivate enum DemoPhase: Equatable {
    case idle
    case running
    case done
    case failed
}

extension RewriteWithVoiceStep.Config {
    static let bullets = RewriteWithVoiceStep.Config(
        title: "Rewrite with your voice",
        subtitle: "Voice instructions like \u{201C}make this into three bullet points\u{201D} rewrite the selected text using what you said.",
        sample: "We need to finalize the design system in October, complete the API integration in November, and conduct user testing in December before the launch.",
        suggestedInstruction: "Make this into three bullet points",
        isLastStep: false
    )

    static let spanish = RewriteWithVoiceStep.Config(
        title: "One more — translate it",
        subtitle: "Voice instructions can do more than restructure. Try a translation.",
        sample: "Thanks for getting back to me — let's meet next Tuesday at 2pm to discuss the proposal.",
        suggestedInstruction: "Translate this to Spanish",
        isLastStep: true
    )
}
