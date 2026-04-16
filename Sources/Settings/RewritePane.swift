import KeyboardShortcuts
import SwiftUI

struct RewritePane: View {
    @ObservedObject private var config = LLMConfiguration.shared
    @State private var apiKeyInput: String = ""
    @State private var testResult: String = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $config.provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                TextField("Base URL (leave empty for default)", text: $config.baseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Default: \(config.provider.defaultBaseURL)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Model (leave empty for default)", text: $config.model)
                    .textFieldStyle(.roundedBorder)
                Text("Default: \(config.provider.defaultModel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if config.provider != .ollama {
                Section("Authentication") {
                    SecureField("API Key", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { apiKeyInput = config.apiKey }
                        .onChange(of: apiKeyInput) { _, newValue in
                            config.apiKey = newValue
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

            Section("Test") {
                HStack {
                    Button(isTesting ? "Testing..." : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting || (config.provider != .ollama && config.apiKey.isEmpty))
                    Spacer()
                    if !testResult.isEmpty {
                        Text(testResult)
                            .font(.system(size: 11))
                            .foregroundStyle(testResult.hasPrefix("\u{2713}") ? .green : .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        let success = await LLMClient().healthCheck()
        if success {
            config.llmVerified = true
            testResult = "\u{2713} Connection verified"
        } else {
            config.llmVerified = false
            testResult = "\u{2717} Connection failed"
        }
    }
}
