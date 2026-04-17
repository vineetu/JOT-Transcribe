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
/// Phase 1 of the Help redesign (`docs/plans/help-redesign.md` §8) swaps
/// the legacy scaffolding for the "Field Notes" component library under
/// `Sources/Help/Components/`. Content is byte-for-byte identical with
/// the pre-redesign copy; diagrams land in Phase 2+.
///
/// Deep-link contract (plan §7): `HelpPane` observes the public
/// `jot.help.scrollToAnchor` notification posted by `InfoPopoverButton`.
/// On receipt it immediately re-posts the private
/// `jot.help.expandForAnchor` notification so any `ExpandableRow`
/// matching the anchor expands synchronously (no animation, same
/// runloop pass) before we ask `ScrollViewReader` for a Y. The actual
/// scroll is deferred one runloop via `DispatchQueue.main.async` so the
/// post-expand layout has committed.
struct HelpPane: View {
    /// Private contract between `HelpPane` and `ExpandableRow` (plan §7).
    /// Not part of the public `InfoPopoverButton` API — callers still
    /// post `scrollToAnchor` only.
    static let expandForAnchorNotification = Notification.Name("jot.help.expandForAnchor")

    private static let railItems: [AnchorRail.Item] = [
        .init(
            number: "01",
            title: "Basics",
            dek: "What Jot does and how the pipeline runs.",
            anchor: "help.basics"
        ),
        .init(
            number: "02",
            title: "Advanced",
            dek: "Optional LLM paths, editable prompts, auto-update.",
            anchor: "help.advanced"
        ),
        .init(
            number: "03",
            title: "Troubleshooting",
            dek: "Common symptoms and what to do about them.",
            anchor: "help.troubleshooting"
        ),
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    AnchorRail(items: Self.railItems) { anchor in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                    .padding(.bottom, 40)

                    basicsSection
                    SectionRule()
                    advancedSection
                    SectionRule()
                    troubleshootingSection
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: InfoPopoverButton.scrollToAnchorNotification
            )) { note in
                guard let anchor = note.userInfo?["anchor"] as? String else { return }

                // Phase 1 of the §7 two-phase contract: tell any matching
                // ExpandableRow to expand synchronously (no animation) so
                // SwiftUI commits the new layout in this runloop pass.
                NotificationCenter.default.post(
                    name: HelpPane.expandForAnchorNotification,
                    object: nil,
                    userInfo: ["anchor": anchor]
                )

                // Phase 2: deferred one runloop — the expansion relayout
                // has committed, so scrollTo resolves against the final Y.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: - Basics

    private var basicsSection: some View {
        HelpSection(
            number: "01",
            title: "Basics",
            dek: "The fundamentals — what Jot does, how the pipeline runs, and the two places you'll live in it.",
            anchor: "help.basics"
        ) {
            HelpSubsection("Dictation", anchor: "help.dictation.basics") {
                BodyText("You press ⌥Space, speak, and the transcript is pasted at the cursor. Audio is transcribed locally by Parakeet on the Apple Neural Engine — no network, no telemetry. Press ⌥Space again to stop, or Esc to cancel without pasting.")
            }

            HelpSubsection("Model", anchor: "help.dictation.model") {
                BodyText("Jot downloads Parakeet TDT 0.6B v3 once, on first run, and stores it on disk. Every subsequent recording runs offline. You can re-download or swap the model in Settings > Transcription if a file is corrupted or you want to try a newer build.")
            }

            HelpSubsection("Auto-correct", anchor: "help.transform.overview") {
                BodyText("When enabled, each transcript is run through a language model for a light cleanup pass — filler words removed, grammar smoothed, numbers and times normalized — before it reaches the cursor. Your voice and vocabulary are preserved. Auto-correct is off by default and only runs once you've configured and verified an LLM provider in Settings > AI.")
            }

            HelpSubsection("AI Rewrite", anchor: "help.rewrite.overview") {
                BodyText("Select text in any app, press your Rewrite hotkey, speak an instruction (“make this shorter,” “rewrite in a neutral tone”), and Jot replaces the selection with the rewritten text. The selected text is copied via a synthetic ⌘C, sent to your configured LLM along with your instruction, and pasted back. Same provider, same prompt settings, same verification flow as Auto-correct.")
            }
        }
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        HelpSection(
            number: "02",
            title: "Advanced",
            dek: "The optional LLM paths, prompt editing, and how the app updates itself.",
            anchor: "help.advanced"
        ) {
            HelpSubsection("LLM providers", anchor: "help.ai.providers") {
                BodyText("Jot supports four providers for the optional LLM paths (Auto-correct and AI Rewrite): OpenAI, Anthropic, Gemini, and Ollama. Each is configured separately in Settings > AI. The provider you pick there is used for both Auto-correct and Rewrite — they share one `LLMConfiguration`. Nothing is sent to an LLM until you both configure a provider and pass Test Connection.")
            }

            HelpSubsection("Endpoint and API key", anchor: "help.ai.endpoint") {
                BodyText("For cloud providers, enter the API key you generated on the provider's dashboard. The Base URL is prefilled with the provider's default and is usually only worth changing if you route through a proxy. Keys are stored in the macOS Keychain — never written to disk in plaintext, never synced anywhere.")
            }

            HelpSubsection("Ollama (fully local)", anchor: "help.ai.ollama") {
                BodyText("Run Ollama on your Mac, pull a model (`ollama pull llama3.1`, for example), and point Jot at `http://localhost:11434`. No API key is required. With Ollama selected, Auto-correct and Rewrite stay entirely on-device — no data ever leaves the machine.")
            }

            HelpSubsection("Test Connection", anchor: "help.ai.verify") {
                BodyText("The Test Connection button in Settings > AI issues a small probe request to your configured endpoint. A green check means Jot can reach the provider and the credentials work; an inline error explains what failed. Verification is required before Auto-correct or Rewrite will run — it's the one moment Jot confirms the provider is real.")
            }

            HelpSubsection("Editable prompts", anchor: "help.ai.customPrompt") {
                BodyText("The system prompts that drive Auto-correct and AI Rewrite are editable. Click Customize prompt beneath either toggle to expand a monospace editor. The default prompts describe the model's role and the exact rules (filler removal, grammar preservation, output format). Edit freely; Reset to default restores the shipped prompt. Editing the prompt does not invalidate your provider verification — it's a content change, not an endpoint change.")
            }

            HelpSubsection("Automatic updates", anchor: "help.advanced.updates") {
                BodyText("Jot uses Sparkle to check for new releases once a day. When a signed update is available, you'll be offered a one-click install. The only network traffic the update path makes is fetching the appcast and the signed DMG — no analytics, no account check.")
            }
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingSection: some View {
        HelpSection(
            number: "03",
            title: "Troubleshooting",
            dek: "Symptoms on the left, diagnosis inside.",
            anchor: "help.troubleshooting"
        ) {
            ExpandableRow(
                "Single-key shortcuts aren't allowed",
                anchor: "help.shortcuts.mac-limits"
            ) {
                BodyText("macOS requires that every global shortcut include at least one modifier key (⌘, ⌥, ⌃, ⇧, or Fn). A plain letter or a bare function key can't be registered — the system reserves single-key input for ordinary typing. If the Shortcuts pane rejects a recording, add a modifier and try again.")
            }

            ExpandableRow(
                "Permissions",
                anchor: "help.permissions"
            ) {
                BodyText("Jot asks for four distinct capabilities, each with its own system prompt: Microphone (to record), Input Monitoring (for global hotkeys), Accessibility (to post the synthetic ⌘V that pastes the transcript), and optional full Accessibility trust for AI Rewrite's ⌘C capture. If any are denied you can re-grant them in System Settings > Privacy & Security. If Accessibility is denied, Jot falls back to copying the transcript to the clipboard and surfacing a toast — you can paste it manually with ⌘V.")
            }

            ExpandableRow(
                "Bluetooth mic redirect",
                anchor: "help.bt-redirect"
            ) {
                BodyText("If a Bluetooth headset or external device is connected when you start recording, macOS may route the mic through it instead of your intended input. Jot records from the system default input; choose the input you want in System Settings > Sound > Input before starting a dictation, or disconnect the device temporarily.")
            }

            ExpandableRow(
                "Shortcut conflicts",
                anchor: "help.shortcuts.conflicts"
            ) {
                BodyText("Shortcuts pane shows you every hotkey registered to Jot side-by-side so you can spot collisions. If two Jot shortcuts share a binding, the pane renders a conflict warning. Shortcuts Jot defines are checked against each other only — it can't see collisions with other apps' global hotkeys, so if one of yours stops firing, another tool is probably grabbing it first.")
            }
        }
    }
}
