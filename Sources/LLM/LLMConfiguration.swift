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
    @AppStorage("jot.llm.model") var model: String = ""
    @AppStorage("jot.transformEnabled") var transformEnabled: Bool = false

    @Published var llmVerified: Bool = false

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
            llmVerified = false
            objectWillChange.send()
        }
    }

    var effectiveBaseURL: String { baseURL.isEmpty ? provider.defaultBaseURL : baseURL }
    var effectiveModel: String { model.isEmpty ? provider.defaultModel : model }
}
