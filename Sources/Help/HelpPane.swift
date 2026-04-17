import SwiftUI

/// Durable in-app help surface (design doc §6 / §I4 / Frontend Directives §4).
///
/// Three sections:
///   • Basics — Dictation, Auto-correct, AI Rewrite.
///   • Advanced — LLM providers (cloud + Ollama), editable prompts,
///     Sparkle auto-update.
///   • Troubleshooting — macOS hotkey limits (single-key shortcuts need
///     a modifier), permissions, Bluetooth input redirect.
///
/// Tone matches `README.md` and `docs/features.md`: plain, understated,
/// specific. Feature descriptions follow the shape *what it is → how it
/// works → what users do with it*.
///
/// By exception, this pane is allowed to scroll (design doc §Frontend §4)
/// — help prose is long-form. Deep-link anchors registered via `.id(…)`
/// are the same IDs that `InfoPopoverButton.helpAnchor` references.
/// `HelpPane` subscribes to `jot.help.scrollToAnchor` and calls
/// `ScrollViewReader.scrollTo(_:anchor:)` to bring the anchor into view.
struct HelpPane: View {
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    basicsSection
                    sectionDivider
                    advancedSection
                    sectionDivider
                    troubleshootingSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: InfoPopoverButton.scrollToAnchorNotification
            )) { note in
                guard let anchor = note.userInfo?["anchor"] as? String else { return }
                // Slight delay so the pane is fully laid out before we
                // ask the reader to scroll — mirrors the pattern the
                // KeyboardShortcuts library uses for similar flows.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Section chrome

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 20)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, id: String? = nil) -> some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.top, 4)
            .padding(.bottom, 8)
            .modifier(OptionalID(id: id))
    }

    @ViewBuilder
    private func subsection(
        _ title: String,
        id: String,
        @ViewBuilder body: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.top, 16)
            body()
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id(id)
    }

    // MARK: - Basics

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Basics", id: "help.basics")

            subsection("Dictation", id: "help.dictation.basics") {
                Text("You press ⌥Space, speak, and the transcript is pasted at the cursor. Audio is transcribed locally by Parakeet on the Apple Neural Engine — no network, no telemetry. Press ⌥Space again to stop, or Esc to cancel without pasting.")
            }

            subsection("Model", id: "help.dictation.model") {
                Text("Jot downloads Parakeet TDT 0.6B v3 once, on first run, and stores it on disk. Every subsequent recording runs offline. You can re-download or swap the model in Settings > Transcription if a file is corrupted or you want to try a newer build.")
            }

            subsection("Auto-correct", id: "help.transform.overview") {
                Text("When enabled, each transcript is run through a language model for a light cleanup pass — filler words removed, grammar smoothed, numbers and times normalized — before it reaches the cursor. Your voice and vocabulary are preserved. Auto-correct is off by default and only runs once you've configured and verified an LLM provider in Settings > AI.")
            }

            subsection("AI Rewrite", id: "help.rewrite.overview") {
                Text("Select text in any app, press your Rewrite hotkey, speak an instruction (“make this shorter,” “rewrite in a neutral tone”), and Jot replaces the selection with the rewritten text. The selected text is copied via a synthetic ⌘C, sent to your configured LLM along with your instruction, and pasted back. Same provider, same prompt settings, same verification flow as Auto-correct.")
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Advanced", id: "help.advanced")

            subsection("LLM providers", id: "help.ai.providers") {
                Text("Jot supports four providers for the optional LLM paths (Auto-correct and AI Rewrite): OpenAI, Anthropic, Gemini, and Ollama. Each is configured separately in Settings > AI. The provider you pick there is used for both Auto-correct and Rewrite — they share one `LLMConfiguration`. Nothing is sent to an LLM until you both configure a provider and pass Test Connection.")
            }

            subsection("Endpoint and API key", id: "help.ai.endpoint") {
                Text("For cloud providers, enter the API key you generated on the provider's dashboard. The Base URL is prefilled with the provider's default and is usually only worth changing if you route through a proxy. Keys are stored in the macOS Keychain — never written to disk in plaintext, never synced anywhere.")
            }

            subsection("Ollama (fully local)", id: "help.ai.ollama") {
                Text("Run Ollama on your Mac, pull a model (`ollama pull llama3.1`, for example), and point Jot at `http://localhost:11434`. No API key is required. With Ollama selected, Auto-correct and Rewrite stay entirely on-device — no data ever leaves the machine.")
            }

            subsection("Test Connection", id: "help.ai.verify") {
                Text("The Test Connection button in Settings > AI issues a small probe request to your configured endpoint. A green check means Jot can reach the provider and the credentials work; an inline error explains what failed. Verification is required before Auto-correct or Rewrite will run — it's the one moment Jot confirms the provider is real.")
            }

            subsection("Editable prompts", id: "help.ai.customPrompt") {
                Text("The system prompts that drive Auto-correct and AI Rewrite are editable. Click Customize prompt beneath either toggle to expand a monospace editor. The default prompts describe the model's role and the exact rules (filler removal, grammar preservation, output format). Edit freely; Reset to default restores the shipped prompt. Editing the prompt does not invalidate your provider verification — it's a content change, not an endpoint change.")
            }

            subsection("Automatic updates", id: "help.advanced.updates") {
                Text("Jot uses Sparkle to check for new releases once a day. When a signed update is available, you'll be offered a one-click install. The only network traffic the update path makes is fetching the appcast and the signed DMG — no analytics, no account check.")
            }
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Troubleshooting", id: "help.troubleshooting")

            DisclosureGroup {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text("macOS requires that every global shortcut include at least one modifier key (⌘, ⌥, ⌃, ⇧, or Fn). A plain letter or a bare function key can't be registered — the system reserves single-key input for ordinary typing. If the Shortcuts pane rejects a recording, add a modifier and try again.")
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Text("Single-key shortcuts aren't allowed")
                    .font(.headline)
            }
            .id("help.shortcuts.mac-limits")
            .padding(.top, 16)

            DisclosureGroup {
                Text("Jot asks for four distinct capabilities, each with its own system prompt: Microphone (to record), Input Monitoring (for global hotkeys), Accessibility (to post the synthetic ⌘V that pastes the transcript), and optional full Accessibility trust for AI Rewrite's ⌘C capture. If any are denied you can re-grant them in System Settings > Privacy & Security. If Accessibility is denied, Jot falls back to copying the transcript to the clipboard and surfacing a toast — you can paste it manually with ⌘V.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } label: {
                Text("Permissions")
                    .font(.headline)
            }
            .id("help.permissions")
            .padding(.top, 16)

            DisclosureGroup {
                Text("If a Bluetooth headset or external device is connected when you start recording, macOS may route the mic through it instead of your intended input. Jot records from the system default input; choose the input you want in System Settings > Sound > Input before starting a dictation, or disconnect the device temporarily.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } label: {
                Text("Bluetooth mic redirect")
                    .font(.headline)
            }
            .id("help.bt-redirect")
            .padding(.top, 16)

            DisclosureGroup {
                Text("Shortcuts pane shows you every hotkey registered to Jot side-by-side so you can spot collisions. If two Jot shortcuts share a binding, the pane renders a conflict warning. Shortcuts Jot defines are checked against each other only — it can't see collisions with other apps' global hotkeys, so if one of yours stops firing, another tool is probably grabbing it first.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } label: {
                Text("Shortcut conflicts")
                    .font(.headline)
            }
            .id("help.shortcuts.conflicts")
            .padding(.top, 16)
        }
    }
}

// MARK: - Helpers

/// Applies `.id(…)` only when `id` is non-nil, so view builders that don't
/// need an anchor don't fragment SwiftUI's identity diff.
private struct OptionalID: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id {
            content.id(id)
        } else {
            content
        }
    }
}
