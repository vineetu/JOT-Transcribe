import Foundation
import SwiftUI

@MainActor
final class LLMConfiguration: ObservableObject {

    /// KeychainStoring seam (Phase 0.8). Phase 3 #29 routes
    /// `apiKey(for:)` / `setAPIKey(_:for:)` / `clearAPIKey(...)`
    /// through the seam instead of the static `KeychainHelper`,
    /// so harness tests can swap in `StubKeychain` and exercise the
    /// `.openai` / `.anthropic` / `.gemini` provider paths without
    /// touching the developer's real macOS keychain.
    private let keychain: any KeychainStoring

    /// `UserDefaults` seam threaded through `@AppStorage`'s `store:`
    /// parameter so harness tests writing `provider = .ollama` land in
    /// the suite-scoped `SystemServices.userDefaults`, not the developer's
    /// `~/Library/Preferences/com.jot.Jot.plist`. Pre-fix, `@AppStorage`
    /// defaulted to `UserDefaults.standard` and harness writes leaked
    /// `.ollama` into the production app — next launch read the leaked
    /// value instead of the `.appleIntelligence` first-install default.
    private let defaults: UserDefaults

    init(keychain: any KeychainStoring, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        // Initialize `@AppStorage` wrappers with the injected store so
        // reads/writes route to the suite-scoped UserDefaults instead of
        // `.standard`. `wrappedValue:` is the first-install default that
        // applies when no value is stored under the key.
        self._provider = AppStorage(
            wrappedValue: Self.firstInstallDefaultProvider,
            Self.providerKey,
            store: defaults
        )
        self._transformEnabled = AppStorage(
            wrappedValue: false,
            "jot.transformEnabled",
            store: defaults
        )
        self._transformPrompt = AppStorage(
            wrappedValue: TransformPrompt.default,
            "jot.llm.transformPrompt",
            store: defaults
        )
        self._articulatePrompt = AppStorage(
            wrappedValue: ArticulatePrompt.default,
            "jot.llm.rewritePrompt",
            store: defaults
        )
        LLMConfigMigration.runIfNeeded(keychain: keychain, defaults: defaults)
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
    static var firstInstallDefaultProvider: LLMProvider {
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
        defaults.string(forKey: Self.baseURLKey(for: provider)) ?? ""
    }

    func setBaseURL(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.baseURLKey(for: provider)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
        objectWillChange.send()
    }

    func model(for provider: LLMProvider) -> String {
        defaults.string(forKey: Self.modelKey(for: provider)) ?? ""
    }

    func setModel(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.modelKey(for: provider)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
        objectWillChange.send()
    }

    func apiKey(for provider: LLMProvider) -> String {
        // `KeychainStoring.load(account:)` throws `KeychainError`
        // for genuine load failures (decoding, OSStatus). Today's
        // call sites treat "no key configured" the same as "load
        // failed" — both surface as "" so the user sees the missing-
        // key UX. Preserve that contract.
        (try? keychain.load(account: Self.apiKeyKey(for: provider))) ?? ""
    }

    func setAPIKey(_ value: String, for provider: LLMProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.apiKeyKey(for: provider)
        if trimmed.isEmpty {
            try? keychain.delete(account: key)
        } else {
            try? keychain.save(trimmed, account: key)
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
        #if JOT_FLAVOR_1
        // Flavor-1 auth is a short-lived JWT held in memory by
        // Flavor1Session — not an API key in Keychain. Configuration is
        // "minimal" when a non-expired JWT is present.
        if provider == .flavor1 {
            return Flavor1Session.shared.hasValidJWT()
        }
        #endif
        if !provider.requiresUserAPIKey {
            return true
        }
        return !apiKey(for: provider).isEmpty || !baseURL(for: provider).isEmpty
    }

    /// Clears the API key for the currently-selected provider. Phase 3 #29
    /// converted this from a static convenience (which read
    /// `LLMConfiguration.shared`) to an instance method routed through
    /// the `KeychainStoring` seam. Call sites that don't already hold
    /// an instance reach via `AppServices.live?.llmConfiguration`.
    func clearAPIKey() {
        try? keychain.delete(account: Self.apiKeyKey(for: provider))
        objectWillChange.send()
    }
}
