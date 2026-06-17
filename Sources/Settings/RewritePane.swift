import SwiftUI

/// Settings pane for AI features — covers both Rewrite (voice-driven and
/// fixed-prompt selection rewrites) and the Transform / Auto-correct
/// provider configuration, since all share `LLMConfiguration`. The
/// user-visible display name is "AI" (design doc §4 / §7).
struct RewritePane: View {
    @EnvironmentObject private var config: LLMConfiguration
    @Environment(\.helpNavigator) private var navigator
    @Environment(\.setSidebarSelection) private var setSidebarSelection
    @State private var apiKeyInput: String = ""
    @State private var testStatus: TestStatus = .idle
    @State private var isTesting = false

    /// Constructor-injected seams for the Test Connection path. Pre-fix
    /// this pane reached `AppServices.live` lazily inside `testConnection()`,
    /// which on a fresh install raced with `applicationDidFinishLaunching`'s
    /// `AppDelegate.services` assignment — the pane could materialise (or
    /// the user could click) before the live graph was wired, so the
    /// guard tripped and surfaced "App services not yet ready". Threading
    /// the deps through `init(...)` here mirrors Phase 3 #29's pattern for
    /// `LLMConfiguration` and removes the only `AppServices.live` reach
    /// in the Settings pane that wasn't already a deferred-action handler.
    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting

    init(
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting
    ) {
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
    }

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

    @ViewBuilder
    var body: some View {
        genericBody
    }

    /// True when the selected provider is the flavor_1 (PFB Enterprise) build.
    /// Returns `false` on the public build (the case doesn't exist there).
    /// Used to swap only the provider-specific fields (baseURL/apiKey/model)
    /// for `Flavor1Pane`, while keeping the cross-cutting UI — provider
    /// picker, rewrite/transform toggles, custom prompts, and Test
    /// Connection — visible. The Keychain-leak risk is specific to the
    /// generic API-key field at ~L112; the rest of the pane is safe.
    private var isFlavor1Selected: Bool {
        #if JOT_FLAVOR_1
        return config.provider == .flavor1
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var genericBody: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Provider") {
                    HStack {
                        Picker("Provider", selection: $config.provider) {
                            ForEach(LLMProvider.userSelectable, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        InfoPopoverButton(
                            title: "Provider",
                            body: "Which service handles Auto-correct and Rewrite. Apple Intelligence runs on-device (free, no API key). OpenAI, Anthropic, Gemini, and local Ollama round out the options.",
                            helpAnchor: "ai-cloud-providers"
                        )
                    }
                    .id("ai-provider")
                    // v1.13: the "Allow Ask Jot to use this provider"
                    // toggle was removed. Ask Jot now follows the global
                    // provider unconditionally. Users who explicitly opted
                    // OUT before retain their privacy preference — see
                    // `HelpChatStore.isCloudAskJotEnabled` for the
                    // migration sentinel logic.

                    if isAppleIntelligenceSelected {
                        if isAppleIntelligenceAvailable {
                            AppleIntelligenceQualityBanner()
                        } else {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("Apple Intelligence isn't available on this Mac. Requires macOS 26.0 or later on Apple Silicon with Apple Intelligence enabled.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                    } else if !isFlavor1Selected {
                        // Unified model picker (v1.13). Replaces the
                        // freeform Model TextField + always-visible
                        // Base URL TextField. The picker hides the
                        // base URL behind a `Use a custom endpoint`
                        // disclosure (auto-expanded if non-default)
                        // and auto-populates the model combobox from
                        // the provider's /models endpoint.
                        HStack(alignment: .firstTextBaseline) {
                            ProviderModelPicker(
                                provider: config.provider,
                                urlSession: urlSession,
                                config: config,
                                justRanTestConnection: testStatus != .idle
                            )
                            .id(config.provider)  // Re-instantiate per provider so the AppStorage keys re-bind.
                            InfoPopoverButton(
                                title: "Model",
                                body: "Which model the provider should route requests to. Pick from the auto-detected list, or type a model id to use one we filtered out (e.g. a reasoning model or a snapshot build).",
                                helpAnchor: "ai-cloud-providers"
                            )
                        }
                    }
                }

                #if JOT_FLAVOR_1
                // Flavor1's sign-in / endpoint / model UI lives in its own
                // pane. Embedded here so users can still see the provider
                // picker above (and switch back to Apple/OpenAI/etc.) and
                // the cross-cutting toggles + prompts below.
                if config.provider == .flavor1 {
                    Flavor1Pane()
                }
                #endif

                // Generic Keychain-backed API key field. Hidden for
                // .flavor1 because that provider authenticates via JWT
                // through Flavor1Session — pasting a JWT into this field
                // would persist it in Keychain under the generic key path.
                if config.provider != .ollama && config.provider != .appleIntelligence && !isFlavor1Selected {
                    Section("Authentication") {
                        HStack {
                            SecureField("API Key", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .onAppear { apiKeyInput = config.apiKey(for: config.provider) }
                                .onChange(of: config.provider) { _, newProvider in
                                    apiKeyInput = config.apiKey(for: newProvider)
                                }
                                .onChange(of: apiKeyInput) { _, newValue in
                                    config.setAPIKey(newValue, for: config.provider)
                                }
                            InfoPopoverButton(
                                title: "API Key",
                                body: "Stored in your macOS Keychain, never written to disk in plaintext. When set: Jot authenticates requests to the selected provider. Leave empty when using Ollama locally or Apple Intelligence on-device.",
                                helpAnchor: "ai-custom-base-url"
                            )
                        }
                        if let keyURL = config.provider.apiKeyURL {
                            Link("Need a key? Get one →", destination: keyURL)
                                .font(.system(size: 11))
                        }
                    }
                }

                Section("Cleanup") {
                    HStack {
                        Toggle("Clean up transcript with AI", isOn: $config.transformEnabled)
                            .disabled(!config.isMinimallyConfigured)
                            .help("Sends transcript text to your LLM provider to remove filler words and fix grammar. Configure a provider in AI settings.")
                        Spacer()
                        InfoPopoverButton(
                            title: "Clean up transcript with AI",
                            body: "Sends the raw transcript to your configured LLM for light cleanup — filler removal, grammar, list detection — while preserving your voice. When on: every transcript is transformed before delivery.",
                            helpAnchor: "cleanup"
                        )
                    }
                    // The editable cleanup prompt now lives in the unified
                    // Prompts panel (Settings → Prompts → Cleanup) alongside
                    // every other prompt. The toggle stays here because it
                    // governs the automatic post-dictation behavior.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Edit the cleanup prompt in the Prompts pane.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            setSidebarSelection(.settings(.prompts))
                        } label: {
                            HStack(spacing: 4) {
                                Text("Open Prompts")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(.link)
                    }
                }

                Section("Rewrite") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Configure Rewrite shortcuts in the Shortcuts pane.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            setSidebarSelection(.settings(.shortcuts))
                        } label: {
                            HStack(spacing: 4) {
                                Text("Open Shortcuts")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(.link)
                    }

                    CustomizePromptDisclosure(
                        label: "Shared system prompt",
                        text: $config.rewritePrompt,
                        defaultValue: RewritePrompt.default,
                        info: .init(
                            title: "Shared system prompt",
                            body: "The foundation of every Rewrite call. When you trigger Rewrite or Rewrite with Voice, Jot sends this text plus a short branch-specific tendency it picks automatically based on your instruction — voice-preserving, shape change, translation, or code. Cleanup has its own separate prompt for transcripts; editing this here does not affect Cleanup. Edit with care — malformed prompts can break Rewrite.",
                            helpAnchor: "ai-editable-prompts"
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
                                helpAnchor: "ai-test-connection"
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
                                    .textSelection(.enabled)
                            }
                        case .failure(let message):
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(message)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { consumePendingSettingsFieldAnchor(with: proxy) }
            .onChange(of: navigator.pendingSettingsFieldAnchor) { _, _ in
                consumePendingSettingsFieldAnchor(with: proxy)
            }
        }
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
        let success = await LLMClient(
            session: urlSession,
            appleClient: appleIntelligence,
            llmConfiguration: config
        ).healthCheck()
        if success {
            testStatus = .success
        } else {
            testStatus = .failure("Connection failed")
        }
    }

    private func consumePendingSettingsFieldAnchor(with proxy: ScrollViewProxy) {
        guard let anchor = navigator.pendingSettingsFieldAnchor,
              Self.supportedSettingsAnchors.contains(anchor)
        else { return }
        withAnimation {
            proxy.scrollTo(anchor, anchor: .top)
        }
        navigator.clearPendingSettingsFieldAnchor()
    }

    private static let supportedSettingsAnchors: Set<String> = [
        "ai-provider",
    ]
}
