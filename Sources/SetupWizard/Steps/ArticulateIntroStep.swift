import KeyboardShortcuts
import SwiftUI

/// Step 8 — final wizard step. Teaches Articulate via a live demo against
/// the user's Test-step transcript (when available), plus shows the two
/// hotkey bindings so the user walks away knowing which key does what.
///
/// Demo calls the SAME pipeline Articulate (fixed-prompt) uses in the
/// wild: `LLMClient.articulate(selectedText:instruction:)` with the
/// instruction "Articulate this" — identical to how the feature works
/// post-wizard. No mocking, no special-casing.
struct ArticulateIntroStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator

    @State private var phase: PreviewPhase = .idle
    @State private var articulatedText: String = ""
    @State private var errorMessage: String?

    private let llm = LLMClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Articulate any selected text")
                    .font(.system(size: 22, weight: .semibold))
                Text("Select text in any app, press your hotkey, and Jot articulates it with AI — rewrite a paragraph, convert a note into a list, translate a sentence, clean up a message.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let transcript = coordinator.testTranscript,
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                demoCard(for: transcript)
            }

            hotkeysList

            Text("Same AI provider as Cleanup — change in Settings → AI. Rebind either hotkey in Settings → Shortcuts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "Done",
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
            transcriptBlock(label: "YOUR TEXT", text: transcript, color: .secondary)

            if phase == .success, !articulatedText.isEmpty {
                transcriptBlock(label: "ARTICULATED", text: articulatedText, color: .accentColor)
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
        }
    }

    private var buttonLabel: String {
        switch phase {
        case .idle: return "Preview Articulate"
        case .loading: return "Articulating…"
        case .success: return "Run again"
        }
    }

    private func runPreview() {
        guard let transcript = coordinator.testTranscript,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        phase = .loading
        articulatedText = ""
        errorMessage = nil
        Task {
            do {
                let result = try await llm.articulate(
                    selectedText: transcript,
                    instruction: "Articulate this"
                )
                await MainActor.run {
                    articulatedText = result
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

    // MARK: - Hotkeys

    private var hotkeysList: some View {
        VStack(alignment: .leading, spacing: 12) {
            hotkeyRow(
                name: .articulate,
                title: "Articulate",
                description: "Fixed prompt: \u{201C}Articulate this.\u{201D} No speaking — press the hotkey and Jot rewrites your selection."
            )
            hotkeyRow(
                name: .articulateCustom,
                title: "Articulate (Custom)",
                description: "Press the hotkey, then speak an instruction like \u{201C}translate to Japanese\u{201D} or \u{201C}shorten to two sentences.\u{201D}"
            )
        }
    }

    private func hotkeyRow(
        name: KeyboardShortcuts.Name,
        title: String,
        description: String
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            shortcutBadge(for: name)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func shortcutBadge(for name: KeyboardShortcuts.Name) -> some View {
        let label = KeyboardShortcuts.getShortcut(for: name)?.description ?? "unbound"
        return Text(label)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(minWidth: 72)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
    }
}

private enum PreviewPhase: Equatable {
    case idle
    case loading
    case success
}
