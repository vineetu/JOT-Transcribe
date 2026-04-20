import KeyboardShortcuts
import SwiftUI

/// Settings pane for AI features — covers both Articulate (voice-driven
/// and fixed-prompt selection rewrites) and the Transform / Auto-correct
/// provider configuration, since all share `LLMConfiguration`. The
/// user-visible display name is "AI" (design doc §4 / §7).
///
/// v1.5 rename: `RewritePane` → `ArticulatePane`. File renamed accordingly.
struct ArticulatePane: View {
    @ObservedObject private var config = LLMConfiguration.shared
    @State private var apiKeyInput: String = ""
    @State private var testStatus: TestStatus = .idle
    @State private var isTesting = false

    private enum TestStatus: Equatable {
        case idle
        case success
        case failure(String)
    }

    private var isAppleIntelligenceSelected: Bool {
        config.provider == .appleIntelligence
    }

    private var isAppleIntelligenceAvailable: Bool {
        AppleIntelligenceClient.isAvailable
    }

    var body: some View {
        Form {
            Section("Provider") {
                HStack {
                    Picker("Provider", selection: $config.provider) {
                        ForEach(LLMProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    InfoPopoverButton(
                        title: "Provider",
                        body: "Which service handles Auto-correct and Articulate. Apple Intelligence runs on-device (free, no API key). OpenAI, Anthropic, Gemini, Vertex Gemini, and local Ollama round out the cloud options.",
                        helpAnchor: "help.ai.providers"
                    )
                }

                if isAppleIntelligenceSelected {
                    if isAppleIntelligenceAvailable {
                        HStack(spacing: 6) {
                            Image(systemName: "brain.head.profile")
                                .foregroundStyle(.secondary)
                            Text("On-device via Apple Foundation Models. No API key required.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Apple Intelligence isn't available on this Mac. Requires macOS 26.0 or later on Apple Silicon with Apple Intelligence enabled.")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    HStack {
                        TextField("Base URL (leave empty for default)", text: $config.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                        InfoPopoverButton(
                            title: "Base URL",
                            body: "Optional override for the provider's API endpoint. Leave empty to use the provider default. Handy for OpenAI-compatible proxies or self-hosted endpoints.",
                            helpAnchor: "help.ai.endpoint"
                        )
                    }
                    Text("Default: \(config.provider.defaultBaseURL)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Model (leave empty for default)", text: $config.model)
                            .textFieldStyle(.roundedBorder)
                        InfoPopoverButton(
                            title: "Model",
                            body: "Which model the provider should route requests to. Leave empty to use the provider default. Use this to opt into newer or cheaper variants your account supports.",
                            helpAnchor: "help.ai.providers"
                        )
                    }
                    Text("Default: \(config.provider.defaultModel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if config.provider != .ollama && config.provider != .appleIntelligence {
                Section("Authentication") {
                    HStack {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .onAppear { apiKeyInput = config.apiKey }
                            .onChange(of: apiKeyInput) { _, newValue in
                                config.apiKey = newValue
                            }
                        InfoPopoverButton(
                            title: "API Key",
                            body: "Stored in your macOS Keychain, never written to disk in plaintext. When set: Jot authenticates requests to the selected provider. Leave empty when using Ollama locally or Apple Intelligence on-device.",
                            helpAnchor: "help.ai.endpoint"
                        )
                    }
                }
            }

            Section("Articulate") {
                HStack {
                    Text("Articulate (Custom)")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .articulateCustom)
                }
                Text("Select text, press the shortcut, speak your instruction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Articulate")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .articulate)
                }
                Text("Select text and press the shortcut — Jot articulates it with a built-in prompt. No voice step.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Prompt") {
                CustomizePromptDisclosure(
                    label: "Articulate shared invariants",
                    text: $config.articulatePrompt,
                    defaultValue: ArticulatePrompt.default,
                    info: .init(
                        title: "Articulate shared invariants",
                        body: "System prompt scaffolding for Articulate. Tells the LLM how to interpret your instruction when articulating selected text. Edit with care — malformed prompts break articulate.",
                        helpAnchor: nil
                    )
                )
            }

            Section("Test") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            if isTesting {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.accentColor)

                        Spacer()
                        InfoPopoverButton(
                            title: "Test Connection",
                            body: "Runs a minimal check against your provider to confirm availability. When it succeeds: Auto-correct becomes enableable. Re-test after changing provider, URL, or key.",
                            helpAnchor: "help.ai.verify"
                        )
                    }

                    switch testStatus {
                    case .idle:
                        EmptyView()
                    case .success:
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connection verified")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    case .failure(let message):
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI")
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        if config.provider == .appleIntelligence {
            // Short-circuit: Apple Intelligence success is purely about
            // local availability; no request to make.
            if AppleIntelligenceClient.isAvailable {
                testStatus = .success
            } else {
                testStatus = .failure("Apple Intelligence isn't available on this Mac.")
            }
            return
        }
        let success = await LLMClient().healthCheck()
        if success {
            testStatus = .success
        } else {
            testStatus = .failure("Connection failed")
        }
    }
}
