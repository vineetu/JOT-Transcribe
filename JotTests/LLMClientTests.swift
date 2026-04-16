import Testing
import Foundation
@testable import Jot

@Suite("LLM Client")
struct LLMClientTests {

    // MARK: - Response Parsing

    private let client = LLMClient()

    @Test("Parses OpenAI chat completion response")
    func parseOpenAI() throws {
        let json = """
        {"choices":[{"message":{"content":"Hello world"}}]}
        """.data(using: .utf8)!
        let result = try client.testParseResponse(provider: .openai, data: json)
        #expect(result == "Hello world")
    }

    @Test("Parses Anthropic messages response")
    func parseAnthropic() throws {
        let json = """
        {"content":[{"type":"text","text":"Hello world"}]}
        """.data(using: .utf8)!
        let result = try client.testParseResponse(provider: .anthropic, data: json)
        #expect(result == "Hello world")
    }

    @Test("Parses Gemini generateContent response")
    func parseGemini() throws {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"Hello world"}]}}]}
        """.data(using: .utf8)!
        let result = try client.testParseResponse(provider: .gemini, data: json)
        #expect(result == "Hello world")
    }

    @Test("Parses Ollama response using OpenAI format")
    func parseOllama() throws {
        let json = """
        {"choices":[{"message":{"content":"Hello world"}}]}
        """.data(using: .utf8)!
        let result = try client.testParseResponse(provider: .ollama, data: json)
        #expect(result == "Hello world")
    }

    @Test("Throws on empty response")
    func emptyResponse() throws {
        let json = """
        {"choices":[{"message":{"content":""}}]}
        """.data(using: .utf8)!
        #expect(throws: LLMError.self) {
            try client.testParseResponse(provider: .openai, data: json)
        }
    }

    @Test("Throws on malformed JSON")
    func malformedJSON() throws {
        let data = "not json".data(using: .utf8)!
        #expect(throws: LLMError.self) {
            try client.testParseResponse(provider: .openai, data: data)
        }
    }

    @Test("Throws on missing content field")
    func missingContent() throws {
        let json = """
        {"choices":[{"message":{}}]}
        """.data(using: .utf8)!
        #expect(throws: LLMError.self) {
            try client.testParseResponse(provider: .openai, data: json)
        }
    }

    // MARK: - Request Building

    @Test("OpenAI request has correct URL and auth header")
    func openAIRequest() throws {
        let request = try client.testBuildRequest(
            provider: .openai,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-5.4-mini",
            systemPrompt: "System",
            userPrompt: "User"
        )
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test("Anthropic request has correct URL and API key header")
    func anthropicRequest() throws {
        let request = try client.testBuildRequest(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "sk-ant-test",
            model: "claude-haiku-4-5-20251001",
            systemPrompt: "System",
            userPrompt: "User"
        )
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test("Gemini request has API key in URL")
    func geminiRequest() throws {
        let request = try client.testBuildRequest(
            provider: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "AIza-test",
            model: "gemini-3.1-flash-lite-preview",
            systemPrompt: "System",
            userPrompt: "User"
        )
        #expect(request.url?.absoluteString.contains("key=AIza-test") == true)
        #expect(request.url?.absoluteString.contains("gemini-3.1-flash-lite-preview") == true)
    }

    @Test("Ollama request routes to OpenAI format at localhost")
    func ollamaRequest() throws {
        let request = try client.testBuildRequest(
            provider: .ollama,
            baseURL: "http://localhost:11434/v1",
            apiKey: "",
            model: "llama3.2:3b",
            systemPrompt: "System",
            userPrompt: "User"
        )
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    // MARK: - Transform Length Validation

    @Test("Accepts normal-length transform result",
          arguments: [
            ("Um uh so I was thinking we should go to the store", "I was thinking we should go to the store"),
            ("Hello", "Hello."),
            ("Yes um yes", "Yes, yes."),
          ])
    func validLength(input: String, output: String) {
        let ratio = Double(output.count) / Double(input.count)
        let minRatio = Double(input.count) < 50 ? 0.15 : 0.3
        #expect(ratio >= minRatio && ratio <= 3.0)
    }

    @Test("Rejects suspiciously short transform for long input")
    func rejectsTooShort() {
        let input = "Um so basically I was thinking that we should probably go ahead and make the changes to the document"
        let output = "OK"
        let ratio = Double(output.count) / Double(input.count)
        #expect(ratio < 0.3)
    }

    @Test("Allows aggressive cleanup for short filler-heavy input")
    func allowsShortCleanup() {
        let input = "Um uh well you know yes"  // 23 chars
        let output = "Yes."  // 4 chars, ratio = 0.17
        let ratio = Double(output.count) / Double(input.count)
        let minRatio = Double(input.count) < 50 ? 0.15 : 0.3
        #expect(ratio >= minRatio)
    }
}
