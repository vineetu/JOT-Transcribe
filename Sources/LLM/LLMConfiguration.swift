import Foundation
import SwiftUI

@MainActor
final class LLMConfiguration: ObservableObject {
    static let shared = LLMConfiguration()

    @AppStorage("jot.llm.provider") var provider: LLMProvider = .openai {
        didSet { llmVerified = false }
    }
    @AppStorage("jot.llm.baseURL") var baseURL: String = "" {
        didSet { llmVerified = false }
    }
    @AppStorage("jot.llm.model") var model: String = "" {
        didSet { llmVerified = false }
    }
    @AppStorage("jot.transformEnabled") var transformEnabled: Bool = false

    // Editable system prompts. Note: intentionally no `didSet` clearing
    // `llmVerified` — prompt edits are independent of provider/endpoint/key
    // changes, which is what verification actually tracks. See
    // `docs/plans/app-ui-unification.md` §"Editable-prompt storage on
    // `LLMConfiguration` (B1)".
    @AppStorage("jot.llm.transformPrompt") var transformPrompt: String = TransformPrompt.default
    @AppStorage("jot.llm.rewritePrompt") var rewritePrompt: String = RewritePrompt.default

    /// Persisted across launches so a user who successfully ran Test
    /// Connection once doesn't have to re-verify every cold launch for
    /// Transform to work. Reset to `false` whenever any of the config
    /// knobs that affect verification (provider / baseURL / model /
    /// apiKey) change.
    @Published var llmVerified: Bool {
        didSet {
            UserDefaults.standard.set(llmVerified, forKey: Self.llmVerifiedKey)
            // TODO: if a third AI-dependent toggle lands, refactor to a capability-gate
            // computed property instead of per-consumer cascade.
            if !llmVerified && transformEnabled { transformEnabled = false }
        }
    }

    private static let keychainKey = "jot.llm.apiKey"
    private static let llmVerifiedKey = "jot.llm.verified"

    init() {
        self.llmVerified = UserDefaults.standard.bool(forKey: Self.llmVerifiedKey)
    }

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
            llmVerified = false
            objectWillChange.send()
        }
    }

    var effectiveBaseURL: String { baseURL.isEmpty ? provider.defaultBaseURL : baseURL }
    var effectiveModel: String { model.isEmpty ? provider.defaultModel : model }
}
