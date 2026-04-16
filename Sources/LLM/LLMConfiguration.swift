import Foundation
import SwiftUI

@MainActor
final class LLMConfiguration: ObservableObject {
    static let shared = LLMConfiguration()

    @AppStorage("jot.llm.provider") var provider: LLMProvider = .openai
    @AppStorage("jot.llm.baseURL") var baseURL: String = ""
    @AppStorage("jot.llm.model") var model: String = ""

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

    var effectiveBaseURL: String { baseURL.isEmpty ? provider.defaultBaseURL : baseURL }
    var effectiveModel: String { model.isEmpty ? provider.defaultModel : model }
}
