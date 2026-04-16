import Testing
import Foundation
@testable import Jot

@Suite("LLM Provider")
struct LLMProviderTests {

    @Test("All providers have non-empty defaults",
          arguments: LLMProvider.allCases)
    func hasDefaults(provider: LLMProvider) {
        #expect(!provider.displayName.isEmpty)
        #expect(!provider.defaultBaseURL.isEmpty)
        #expect(!provider.defaultModel.isEmpty)
    }

    @Test("Ollama defaults to localhost")
    func ollamaLocalhost() {
        #expect(LLMProvider.ollama.defaultBaseURL.contains("localhost"))
        #expect(LLMProvider.ollama.defaultBaseURL.contains("11434"))
    }

    @Test("Cloud providers use HTTPS")
    func cloudProviderHTTPS() {
        for provider in [LLMProvider.openai, .anthropic, .gemini] {
            #expect(provider.defaultBaseURL.hasPrefix("https://"))
        }
    }

    @Test("Each provider has a unique default base URL")
    func uniqueBaseURLs() {
        let urls = LLMProvider.allCases.map(\.defaultBaseURL)
        #expect(Set(urls).count == urls.count)
    }
}
