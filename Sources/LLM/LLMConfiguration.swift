import Foundation
import SwiftUI

@MainActor
final class LLMConfiguration: ObservableObject {
    static let shared = LLMConfiguration()

    /// The canonical `@AppStorage` key for the selected provider.
    /// Kept stable across releases so existing users' stored values survive.
    private static let providerKey = "jot.llm.provider"

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
    @AppStorage("jot.llm.baseURL") var baseURL: String = ""
    @AppStorage("jot.llm.model") var model: String = ""
    @AppStorage("jot.transformEnabled") var transformEnabled: Bool = false

    @AppStorage("jot.llm.transformPrompt") var transformPrompt: String = TransformPrompt.default
    // Swift property renamed to `articulatePrompt` in v1.5; the underlying
    // @AppStorage key stays as `"jot.llm.rewritePrompt"` so users' customized
    // prompts survive the rename. Do NOT change the key literal.
    @AppStorage("jot.llm.rewritePrompt") var articulatePrompt: String = ArticulatePrompt.default

    private static let keychainKey = "jot.llm.apiKey"

    var apiKey: String {
        get {
            guard let data = KeychainHelper.load(key: Self.keychainKey) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(key: Self.keychainKey)
            } else {
                KeychainHelper.save(key: Self.keychainKey, data: Data(newValue.utf8))
            }
            objectWillChange.send()
        }
    }

    var isMinimallyConfigured: Bool {
        provider == .ollama
            || provider == .appleIntelligence
            || !apiKey.isEmpty
            || !baseURL.isEmpty
            || !model.isEmpty
    }

    var effectiveBaseURL: String { baseURL.isEmpty ? provider.defaultBaseURL : baseURL }
    var effectiveModel: String { model.isEmpty ? provider.defaultModel : model }
}
