import Foundation
import SwiftUI

@MainActor
final class LLMConfiguration: ObservableObject {
    static let shared = LLMConfiguration()

    private init() {
        LLMConfigMigration.runIfNeeded()
    }

    /// The canonical `@AppStorage` key for the selected provider.
    /// Kept stable across releases so existing users' stored values survive.
    private static let providerKey = "jot.llm.provider"

    /// Providers that actually use the shared `{baseURL, apiKey, model}`
    /// bucket scheme. Apple Intelligence runs entirely on-device and has
    /// no endpoint/key/model, so it's excluded.
    static let bucketedProviders: [LLMProvider] = [.openai, .anthropic, .gemini, .ollama]

    /// Default provider for first-install users (nothing stored yet).
    ///
    /// v1.5 change: if Apple Intelligence is available on this Mac, the
    /// effective default for a fresh install becomes `.appleIntelligence`
    /// so cleanup and articulate run on-device with no API-key step.
    /// Existing users whose `@AppStorage` already holds a provider value
    /// see no change — `@AppStorage` reads the stored value before this
    /// default ever applies.
    private static var firstInstallDefaultProvider: LLMProvider {
        AppleIntelligenceClient.isAvailable ? .appleIntelligence : .openai
    }

    @AppStorage(LLMConfiguration.providerKey) var provider: LLMProvider = LLMConfiguration.firstInstallDefaultProvider
    @AppStorage("jot.transformEnabled") var transformEnabled: Bool = false

    @AppStorage("jot.llm.transformPrompt") var transformPrompt: String = TransformPrompt.default
    // Swift property renamed to `articulatePrompt` in v1.5; the underlying
    // @AppStorage key stays as `"jot.llm.rewritePrompt"` so users' customized
    // prompts survive the rename. Do NOT change the key literal.
    @AppStorage("jot.llm.rewritePrompt") var articulatePrompt: String = ArticulatePrompt.default

    // MARK: - Per-provider storage keys

    private static func baseURLKey(for provider: LLMProvider) -> String {
        "jot.llm.\(provider.rawValue).baseURL"
    }

    private static func modelKey(for provider: LLMProvider) -> String {
        "jot.llm.\(provider.rawValue).model"
    }

    private static func apiKeyKey(for provider: LLMProvider) -> String {
        "jot.llm.\(provider.rawValue).apiKey"
    }

    // MARK: - Per-provider accessors

    func baseURL(for provider: LLMProvider) -> String {
        UserDefaults.standard.string(forKey: Self.baseURLKey(for: provider)) ?? ""
    }

    func setBaseURL(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.baseURLKey(for: provider)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
        objectWillChange.send()
    }

    func model(for provider: LLMProvider) -> String {
        UserDefaults.standard.string(forKey: Self.modelKey(for: provider)) ?? ""
    }

    func setModel(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.modelKey(for: provider)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
        objectWillChange.send()
    }

    func apiKey(for provider: LLMProvider) -> String {
        guard let data = KeychainHelper.load(key: Self.apiKeyKey(for: provider)) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func setAPIKey(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.apiKeyKey(for: provider)
        if trimmed.isEmpty {
            KeychainHelper.delete(key: key)
        } else {
            KeychainHelper.save(key: key, data: Data(trimmed.utf8))
        }
        objectWillChange.send()
    }

    // MARK: - SwiftUI bindings (re-bind automatically when provider changes)

    func baseURLBinding(for provider: LLMProvider) -> Binding<String> {
        Binding(
            get: { self.baseURL(for: provider) },
            set: { self.setBaseURL($0, for: provider) }
        )
    }

    func modelBinding(for provider: LLMProvider) -> Binding<String> {
        Binding(
            get: { self.model(for: provider) },
            set: { self.setModel($0, for: provider) }
        )
    }

    func apiKeyBinding(for provider: LLMProvider) -> Binding<String> {
        Binding(
            get: { self.apiKey(for: provider) },
            set: { self.setAPIKey($0, for: provider) }
        )
    }

    // MARK: - Effective values (fallback to provider defaults)

    func effectiveBaseURL(for provider: LLMProvider) -> String {
        let stored = baseURL(for: provider)
        return stored.isEmpty ? provider.defaultBaseURL : stored
    }

    func effectiveModel(for provider: LLMProvider) -> String {
        let stored = model(for: provider)
        return stored.isEmpty ? provider.defaultModel : stored
    }

    // MARK: - Aggregate state

    var isMinimallyConfigured: Bool {
        if !provider.requiresUserAPIKey {
            return true
        }
        return !apiKey(for: provider).isEmpty || !baseURL(for: provider).isEmpty
    }

    /// Clears the API key for the currently-selected provider. Kept as a
    /// static convenience because existing call-sites (ResetActions) don't
    /// hold an instance reference.
    static func clearAPIKey() {
        let current = shared.provider
        KeychainHelper.delete(key: apiKeyKey(for: current))
        shared.objectWillChange.send()
    }
}
