import KeyboardShortcuts
import SwiftUI

/// Step 8 — final wizard step. Teaches Rewrite via a live demo against
/// a bundled sample draft, plus shows the two hotkey bindings so the
/// user walks away knowing which key does what.
///
/// Demo calls the SAME pipeline Rewrite (fixed-prompt) uses in the wild:
/// `LLMClient.rewrite(selectedText:instruction:)` with the instruction
/// "Rewrite this" — identical to how the feature works post-wizard. No
/// mocking, no special-casing.
///
/// Hotkey commandeer: while this step is on screen, both `.rewrite` and
/// `.rewriteWithVoice` route into `runPreview()` via
/// `HotkeyRouter.setRewriteOverride(...)`. Pressing either hotkey fires
/// the same wizard demo — voice capture is deliberately skipped here so
/// the user doesn't accidentally trigger a real voice-instruction
/// capture against whatever app is behind the wizard window. The
/// override is cleared on `.onDisappear`, restoring the real pipeline.
struct RewriteIntroStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator

    @State private var phase: PreviewPhase = .idle
    @State private var rewrittenText: String = ""
    @State private var errorMessage: String?
    /// Bumped by the inline KeyboardShortcuts.Recorder's onChange so the
    /// binding-pill row re-renders after the user records a new chord.
    /// `@AppStorage` already reactive-rebuilds for the single-key half;
    /// the chord half needs this nudge.
    @State private var bindingsRefreshToken: Int = 0

    /// Single-key bindings for both rewrite hotkeys. SwiftUI auto-
    /// re-renders the binding-pill row when either changes — no token
    /// nudge needed.
    @AppStorage("jot.hotkey.rewrite.singleKey") private var rewriteSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.rewriteWithVoice.singleKey") private var rewriteWithVoiceSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.rewrite.triggerType") private var rewriteTriggerTypeRaw: String = ""

    /// Bundled sample draft. A casual Slack-style message — a realistic
    /// thing someone would want to polish with Rewrite (fixed-prompt).
    /// Different shape from the Cleanup step's dictation sample so the
    /// two demos don't feel redundant.
    private static let sampleDraft = "Hey team, just wanted to circle back on the proposal — let me know if you have any questions or concerns or whatever, thanks!"

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
                Text("Rewrite any selected text")
                    .font(.system(size: 22, weight: .semibold))
                Text("Press your hotkey with text selected — Jot rewrites it using the built-in \u{201C}Rewrite this\u{201D} prompt. No speaking required. (The next steps show how to add a voice instruction.)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            demoCard(for: Self.sampleDraft)

            Text("Jot is still in development. If you hit issues, you can share diagnostic logs from the About tab — nothing is sent to us unless you copy and send them yourself.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Text("Same AI provider as Cleanup — change in Settings → AI. Rebind in Settings → Shortcuts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

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
            // Commandeer both rewrite hotkeys so they fire the wizard
            // demo instead of the production selection-capture pipeline.
            // Either hotkey runs the same demo — Rewrite with Voice's
            // voice-capture step is intentionally skipped here.
            coordinator.hotkeyRouter?.setRewriteOverride {
                Task { @MainActor in runPreview() }
            }
        }
        .onDisappear {
            coordinator.hotkeyRouter?.clearRewriteOverride()
        }
    }

    // MARK: - Demo

    @ViewBuilder
    private func demoCard(for transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            hotkeyInstruction

            transcriptBlock(label: "SAMPLE DRAFT", text: transcript, color: .secondary)

            if phase == .success, !rewrittenText.isEmpty {
                transcriptBlock(label: "REWRITTEN", text: rewrittenText, color: .accentColor)
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

    /// Either a "Press [X] or [Y] to rewrite…" pill row showing every
    /// rewrite binding currently active, or — when no rewrite hotkey is
    /// bound at all — an inline binding picker so the user can set one
    /// without leaving the wizard.
    @ViewBuilder
    private var hotkeyInstruction: some View {
        let bindings = rewriteBindingLabels
        if bindings.isEmpty {
            inlineBindingPicker
        } else {
            bindingPillRow(for: bindings)
        }
    }

    /// Bound triggers for `.rewrite` only (fixed-prompt). Step 10 is
    /// about the Rewrite hotkey; the badge must not surface
    /// `.rewriteWithVoice` bindings even though the override
    /// commandeers both keys behind the scenes.
    private var rewriteBindingLabels: [String] {
        _ = bindingsRefreshToken
        _ = rewriteSingleKey
        _ = rewriteTriggerTypeRaw
        return SingleKeyMigration.effectiveBindingLabel(for: .rewrite).map { [$0] } ?? []
    }

    @ViewBuilder
    private func bindingPillRow(for bindings: [String]) -> some View {
        HStack(spacing: 6) {
            Text("Press")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(Array(bindings.enumerated()), id: \.offset) { idx, label in
                if idx > 0 {
                    Text("or")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                    )
            }
            Text("to rewrite the draft, or click the button.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Shown when neither rewrite hotkey has any binding. Lets the user
    /// pick a single-key or record a chord right here in the wizard —
    /// changes write through to UserDefaults via `@AppStorage` and the
    /// `KeyboardShortcuts.Recorder`, which `HotkeyRouter`'s
    /// `UserDefaults.didChangeNotification` observer picks up
    /// immediately. The next press of the new binding fires the demo.
    @ViewBuilder
    private var inlineBindingPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set a Rewrite hotkey to try it here:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Trigger type", selection: rewriteTriggerTypeBinding) {
                ForEach(SingleKey.TriggerType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                if rewriteTriggerType == .singleKey {
                    Picker("", selection: $rewriteSingleKey) {
                        Text(SingleKey.none.displayName).tag(SingleKey.none)
                        Divider()
                        ForEach(SingleKey.Action.rewrite.pickerCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                } else {
                    KeyboardShortcuts.Recorder(for: .rewrite) { _ in
                        bindingsRefreshToken &+= 1
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Or click the button — you can always rebind in Settings → Shortcuts.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var rewriteTriggerType: SingleKey.TriggerType {
        _ = rewriteTriggerTypeRaw
        return SingleKeyMigration.effectiveTriggerType(for: .rewrite)
    }

    private var rewriteTriggerTypeBinding: Binding<SingleKey.TriggerType> {
        Binding(
            get: { rewriteTriggerType },
            set: { type in
                SingleKeyMigration.setTriggerType(type, for: .rewrite)
                bindingsRefreshToken &+= 1
            }
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
        case .idle: return "Preview Rewrite"
        case .loading: return "Rewriting…"
        case .success: return "Run again"
        }
    }

    private func runPreview() {
        // Coalesce duplicate fires — the hotkey override and the
        // button both call this, and the user may tap repeatedly while
        // the LLM is in flight.
        guard phase != .loading else { return }
        phase = .loading
        rewrittenText = ""
        errorMessage = nil
        let service = resolveAIService()
        Task {
            do {
                let result = try await service.rewrite(
                    selectedText: Self.sampleDraft,
                    instruction: nil
                )
                await MainActor.run {
                    rewrittenText = result
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

}

private enum PreviewPhase: Equatable {
    case idle
    case loading
    case success
}
