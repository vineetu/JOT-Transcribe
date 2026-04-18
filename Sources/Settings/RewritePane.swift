import KeyboardShortcuts
import SwiftUI

/// Settings pane for AI features — covers both AI Rewrite (voice-driven
/// selection rewrites) and the Transform / Auto-correct provider
/// configuration, since both share `LLMConfiguration`. File name stays
/// `RewritePane.swift` (Xcode synchronized folder group), but the
/// user-visible display name is "AI" (design doc §4 / §7).
struct RewritePane: View {
    @ObservedObject private var config = LLMConfiguration.shared
    @State private var apiKeyInput: String = ""
    @State private var testStatus: TestStatus = .idle
    @State private var isTesting = false

    private enum TestStatus: Equatable {
        case idle
        case success
        case failure(String)
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
                        body: "Which LLM service handles Auto-correct and AI Rewrite. Supports OpenAI, Anthropic, Gemini, and local Ollama. When selected: the endpoint, model, and auth fields default to that provider's standard values.",
                        helpAnchor: "help.ai.providers"
                    )
                }
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

            if config.provider != .ollama {
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
                            body: "Stored in your macOS Keychain, never written to disk in plaintext. When set: Jot authenticates requests to the selected provider. Leave empty when using Ollama locally.",
                            helpAnchor: "help.ai.endpoint"
                        )
                    }
                }
            }

            Section("Shortcut") {
                HStack {
                    Text("Rewrite selection")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .rewriteSelection)
                }
                Text("Select text, press the shortcut, speak your instruction.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Prompt") {
                CustomizePromptDisclosure(
                    label: "Customize prompt",
                    text: $config.rewritePrompt,
                    defaultValue: RewritePrompt.default,
                    info: .init(
                        title: "Customize prompt",
                        body: "System prompt for AI Rewrite. Tells the LLM how to interpret your voice instruction when rewriting selected text. Edit with care — malformed prompts break rewrite.",
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
                            body: "Runs a minimal request against your provider to confirm credentials and reachability. When it succeeds: Auto-correct becomes enableable. Re-test after changing provider, URL, or key.",
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
        let success = await LLMClient().healthCheck()
        if success {
            config.llmVerified = true
            testStatus = .success
        } else {
            config.llmVerified = false
            testStatus = .failure("Connection failed")
        }
    }
}
