import SwiftUI

/// Configure the AI provider used by the optional Cleanup and Rewrite
/// features. Sits between the optional Vocabulary primer and the
/// Cleanup / Rewrite demo steps so users entering the advanced flow
/// actively pick and verify a provider before they see those demos
/// run.
///
/// Design notes:
///   • No default. The picker starts unselected ("Choose…") on first
///     run; the user must actively pick a provider. We deliberately
///     do not nudge toward Apple Intelligence, OpenAI, or any other
///     provider — neutrality is the contract. The stored
///     `LLMConfiguration.provider` only changes when the user makes
///     a deliberate selection here.
///   • A `@AppStorage` flag tracks whether the user has ever made a
///     pick in this wizard step, so back/continue traversal within
///     one wizard run, and subsequent reopens of the wizard from
///     Settings → General, keep showing the user's existing selection
///     instead of resetting to "Choose…".
///   • Optional step. Skip is allowed — the user can finish the
///     wizard without configuring AI; Cleanup and Rewrite then
///     surface their own configuration prompts later.
///   • Test Connection mirrors `RewritePane.testConnection()` so the
///     wizard and Settings use identical validation logic.
struct AIProviderStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var config: LLMConfiguration

    /// Local picker state. `nil` means the user hasn't picked anything
    /// in this wizard step yet — we render a "Choose…" placeholder and
    /// hide the provider-specific fields. Becomes non-nil once the
    /// user makes a pick, at which point we mirror the choice into
    /// `config.provider` and flip the persistent `hasPickedProvider`
    /// flag so the choice survives back/continue traversal and
    /// subsequent wizard reopens.
    @State private var pickerChoice: LLMProvider?
    @State private var apiKeyInput: String = ""
    @State private var testStatus: TestStatus = .idle
    @State private var isTesting = false
    /// Persistent record that the user has actively picked a provider
    /// in the wizard at least once. Until set, the picker shows
    /// "Choose…" instead of reflecting the stored default — that's
    /// the whole point of an active-choice step. Once set, subsequent
    /// reopens seed the picker from `config.provider`.
    @AppStorage("jot.wizard.aiHasPicked") private var hasPickedProvider = false

    private enum TestStatus: Equatable {
        case idle
        case success
        case failure(String)
    }

    private var isAppleIntelligenceAvailable: Bool {
        AppleIntelligenceClient.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up your AI provider")
                    .font(.system(size: 22, weight: .semibold))
                Text("Pick the service that should power Cleanup (transcript polish) and Rewrite (selection rewrites). You can change this any time in Settings → AI.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            providerCard

            if pickerChoice != nil {
                testCard
            }

            Text("Skip if you only need dictation — Cleanup and Rewrite remain off until you finish this step from Settings → AI.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Seed the picker from the user's prior selection only if
            // they've actually picked something in the wizard before.
            // First-run users see "Choose…" and have to actively pick.
            pickerChoice = hasPickedProvider ? config.provider : nil
            syncAPIKeyInput()
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "Continue",
                    canAdvance: true,
                    isPrimaryBusy: false,
                    showsSkip: true
                )
            )
        }
        .onChange(of: pickerChoice) { _, newValue in
            // Apply the user's choice to the persisted configuration.
            // Only fires when the user actually picks something (the
            // initial seed in onAppear is also routed here, but the
            // guard makes that a no-op since hasPickedProvider was
            // already true when the seed was non-nil).
            guard let newValue else { return }
            config.provider = newValue
            hasPickedProvider = true
            syncAPIKeyInput()
            testStatus = .idle
        }
    }

    // MARK: - Provider card

    @ViewBuilder
    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $pickerChoice) {
                Text("Choose…").tag(LLMProvider?.none)
                ForEach(LLMProvider.userSelectable, id: \.self) { provider in
                    Text(provider.displayName).tag(LLMProvider?.some(provider))
                }
            }
            .pickerStyle(.menu)

            // LM Studio recommended-local setup, surfaced when physical
            // RAM qualifies. Independent of the picker selection — it
            // drives setup; selecting `.lmStudio` stays user-initiated.
            if LMStudioSetup.ramQualifies {
                LMStudioRecommendCard()
            }

            switch pickerChoice {
            case .none:
                Text("Pick a provider above to configure it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .appleIntelligence:
                appleIntelligenceFootnote
            #if JOT_FLAVOR_1
            case .flavor1:
                // Mirror of Settings → AI for the flavor_1 provider:
                // installs the gimme-ai-creds CLI / signs in / shows
                // signed-in confirmation. Endpoint, JWT, and full
                // countdown details still live in Settings → AI.
                Flavor1WizardSetupCard()
            #endif
            case .some:
                providerFields
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    @ViewBuilder
    private var appleIntelligenceFootnote: some View {
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
    }

    @ViewBuilder
    private var providerFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            // API key first — without it, the picker can't probe.
            // Gate on the provider's own contract instead of an
            // explicit case list. `.flavor1` (when JOT_FLAVOR_1 is on)
            // authenticates via JWT — `requiresUserAPIKey` is false
            // for it, so we correctly hide the generic API-key field
            // and avoid persisting a JWT under the openai/anthropic
            // /gemini Keychain bucket path. Sign-in for Flavor-1 lives
            // in Settings → AI.
            if config.provider.requiresUserAPIKey {
                SecureField("API Key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKeyInput) { _, newValue in
                        config.setAPIKey(newValue, for: config.provider)
                    }
                Text("Stored in your macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let keyURL = config.provider.apiKeyURL {
                    Link("Need a key? Get one →", destination: keyURL)
                        .font(.system(size: 11))
                }
            }

            // Unified model picker (v1.13): replaces the old freeform
            // Model TextField + always-visible Base URL TextField with
            // a combobox that auto-populates from the provider's
            // /models endpoint. The Base URL field is now hidden
            // inside the picker's "Use a custom endpoint" disclosure.
            ProviderModelPicker(
                provider: config.provider,
                urlSession: coordinator.urlSession,
                config: config,
                justRanTestConnection: testStatus != .idle
            )
            .id(config.provider)  // Re-instantiate per provider so the AppStorage keys re-bind.
        }
    }

    // MARK: - Test card

    @ViewBuilder
    private var testCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)

                Spacer()
            }

            switch testStatus {
            case .idle:
                EmptyView()
            case .success:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connection verified.")
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

    // MARK: - Helpers

    private func syncAPIKeyInput() {
        // Same gate as the API-key field's visibility — never touch
        // Keychain for providers that don't use an API key (Apple
        // Intelligence, Ollama, Flavor-1). Keeps the field empty and
        // avoids a synchronous Keychain hit when one isn't needed.
        guard config.provider.requiresUserAPIKey else {
            apiKeyInput = ""
            return
        }
        apiKeyInput = config.apiKey(for: config.provider)
    }

    private func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        if config.provider == .appleIntelligence {
            if AppleIntelligenceClient.isAvailable {
                testStatus = .success
            } else {
                testStatus = .failure("Apple Intelligence isn't available on this Mac.")
            }
            return
        }
        let success = await LLMClient(
            session: coordinator.urlSession,
            appleClient: coordinator.appleIntelligence,
            llmConfiguration: config
        ).healthCheck()
        testStatus = success ? .success : .failure("Connection failed")
    }
}
