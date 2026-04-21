import Foundation
import Testing
@testable import Jot

private struct MockStreamingResponse {
    let response: HTTPURLResponse
    let chunks: [Data]
}

private final class MockStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> MockStreamingResponse)?

    private var task: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        task = Task {
            do {
                let mockResponse = try handler(request)
                client?.urlProtocol(
                    self,
                    didReceive: mockResponse.response,
                    cacheStoragePolicy: .notAllowed
                )

                for chunk in mockResponse.chunks {
                    guard !Task.isCancelled else { return }
                    client?.urlProtocol(self, didLoad: chunk)
                    try? await Task.sleep(for: .milliseconds(10))
                }

                guard !Task.isCancelled else { return }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        task?.cancel()
        task = nil
    }
}

@Suite("LLM Client")
struct LLMClientTests {
    private struct SavedConfiguration {
        let provider: LLMProvider
        let baseURL: String
        let model: String
        let apiKey: String
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockStreamingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient() -> LLMClient {
        LLMClient(session: makeSession())
    }

    private func makeResponse(
        url: URL,
        statusCode: Int,
        chunks: [String]
    ) -> MockStreamingResponse {
        MockStreamingResponse(
            response: HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!,
            chunks: chunks.map { Data($0.utf8) }
        )
    }

    private func saveConfiguration() async -> SavedConfiguration {
        await MainActor.run {
            let configuration = LLMConfiguration.shared
            return SavedConfiguration(
                provider: configuration.provider,
                baseURL: configuration.baseURL,
                model: configuration.model,
                apiKey: configuration.apiKey
            )
        }
    }

    private func applyConfiguration(
        provider: LLMProvider,
        baseURL: String,
        model: String,
        apiKey: String
    ) async {
        await MainActor.run {
            let configuration = LLMConfiguration.shared
            configuration.provider = provider
            configuration.baseURL = baseURL
            configuration.model = model
            configuration.apiKey = apiKey
        }
    }

    private func restoreConfiguration(_ saved: SavedConfiguration) async {
        await applyConfiguration(
            provider: saved.provider,
            baseURL: saved.baseURL,
            model: saved.model,
            apiKey: saved.apiKey
        )
    }

    private func withConfiguration<T>(
        provider: LLMProvider,
        baseURL: String,
        model: String,
        apiKey: String,
        operation: () async throws -> T
    ) async throws -> T {
        let savedConfiguration = await saveConfiguration()
        await applyConfiguration(
            provider: provider,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )

        do {
            let result = try await operation()
            await restoreConfiguration(savedConfiguration)
            return result
        } catch {
            await restoreConfiguration(savedConfiguration)
            throw error
        }
    }

    @Test("Parses OpenAI SSE event chunk")
    func parseOpenAIStreamChunk() async throws {
        let client = makeClient()
        let text = try await client.testParseSSEEvent(
            provider: .openai,
            lines: ["data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}"]
        )
        #expect(text == "Hello")
    }

    @Test("Parses Anthropic SSE event chunk")
    func parseAnthropicStreamChunk() async throws {
        let client = makeClient()
        let text = try await client.testParseSSEEvent(
            provider: .anthropic,
            lines: ["event: content_block_delta", "data: {\"delta\":{\"text\":\"Hello\"}}"]
        )
        #expect(text == "Hello")
    }

    @Test("Parses Gemini SSE event chunk")
    func parseGeminiStreamChunk() async throws {
        let client = makeClient()
        let text = try await client.testParseSSEEvent(
            provider: .gemini,
            lines: ["data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\"}]}}]}"]
        )
        #expect(text == "Hello")
    }

    @Test("Public transform streams Ollama response")
    func transformStreamsOllamaResponse() async throws {
        let client = makeClient()
        MockStreamingURLProtocol.handler = { request in
            self.makeResponse(
                url: try #require(request.url),
                statusCode: 200,
                chunks: [
                    "data: {\"choices\":[{\"delta\":{\"content\":\"Hello \"}}]}\n\n",
                    "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\n",
                    "data: [DONE]\n\n",
                ]
            )
        }
        defer { MockStreamingURLProtocol.handler = nil }

        let result = try await withConfiguration(
            provider: .ollama,
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2:3b",
            apiKey: ""
        ) {
            try await client.transform(transcript: "hello world")
        }
        #expect(result == "Hello world")
    }

    @Test("Transforms streamed HTTP errors into typed LLMError")
    func streamedHTTPError() async throws {
        let client = makeClient()
        let request = try await client.testBuildRequest(
            provider: .openai,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-5.4-mini",
            systemPrompt: "System",
            userPrompt: "User",
            stream: true
        )

        MockStreamingURLProtocol.handler = { request in
            self.makeResponse(
                url: try #require(request.url),
                statusCode: 401,
                chunks: [
                    "data: {\"error\":{\"message\":\"bad key\"}}\n\n",
                ]
            )
        }
        defer { MockStreamingURLProtocol.handler = nil }

        do {
            _ = try await client.testPerformLLMRequest(provider: .openai, request: request)
            Issue.record("Expected streamed request to fail")
        } catch let error as LLMError {
            switch error {
            case .httpError(let statusCode, let body):
                #expect(statusCode == 401)
                #expect(body.contains("bad key"))
            default:
                Issue.record("Expected .httpError, got \(error)")
            }
        }
    }

    @Test("Public transform skips empty transcript")
    func transformSkipsEmptyTranscript() async throws {
        let client = makeClient()
        let result = try await withConfiguration(
            provider: .ollama,
            baseURL: "http://localhost:11434/v1",
            model: "llama3.2:3b",
            apiKey: ""
        ) {
            try await client.transform(transcript: "   \n")
        }
        #expect(result == "   \n")
    }

    @Test("Public transform throws emptyResponse for empty streamed payload")
    func transformEmptyResponse() async throws {
        let client = makeClient()
        MockStreamingURLProtocol.handler = { request in
            self.makeResponse(
                url: try #require(request.url),
                statusCode: 200,
                chunks: ["data: [DONE]\n\n"]
            )
        }
        defer { MockStreamingURLProtocol.handler = nil }

        do {
            _ = try await withConfiguration(
                provider: .ollama,
                baseURL: "http://localhost:11434/v1",
                model: "llama3.2:3b",
                apiKey: ""
            ) {
                try await client.transform(transcript: "hello world")
            }
            Issue.record("Expected emptyResponse")
        } catch let error as LLMError {
            switch error {
            case .emptyResponse:
                break
            default:
                Issue.record("Expected .emptyResponse, got \(error)")
            }
        }
    }

    @Test("Public transform maps transport timeout into networkError")
    func transformTimeout() async throws {
        let client = makeClient()
        MockStreamingURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        defer { MockStreamingURLProtocol.handler = nil }

        do {
            _ = try await withConfiguration(
                provider: .ollama,
                baseURL: "http://localhost:11434/v1",
                model: "llama3.2:3b",
                apiKey: ""
            ) {
                try await client.transform(transcript: "hello world")
            }
            Issue.record("Expected timeout")
        } catch let error as LLMError {
            switch error {
            case .networkError(let underlying as URLError):
                #expect(underlying.code == .timedOut)
            default:
                Issue.record("Expected .networkError(URLError.timedOut), got \(error)")
            }
        }
    }

    @Test("OpenAI request enables stream when requested")
    func openAIStreamingRequest() async throws {
        let client = makeClient()
        let request = try await client.testBuildRequest(
            provider: .openai,
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            model: "gpt-5.4-mini",
            systemPrompt: "System",
            userPrompt: "User",
            stream: true
        )

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(json["stream"] as? Bool == true)
    }

    @Test("Gemini streaming request uses streamGenerateContent endpoint")
    func geminiStreamingRequest() async throws {
        let client = makeClient()
        let request = try await client.testBuildRequest(
            provider: .gemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKey: "AIza-test",
            model: "gemini-3.1-flash-lite-preview",
            systemPrompt: "System",
            userPrompt: "User",
            stream: true
        )

        let absoluteURL = try #require(request.url?.absoluteString)
        #expect(absoluteURL.contains(":streamGenerateContent"))
        #expect(absoluteURL.contains("alt=sse"))
        #expect(absoluteURL.contains("key=AIza-test"))
    }

    @Test("Vertex request stays non-streaming")
    func vertexRequest() async throws {
        let client = makeClient()
        let request = try await client.testBuildRequest(
            provider: .vertexGemini,
            baseURL: "https://vertex.example.com",
            apiKey: "vertex-key",
            model: "gemini-1.5-flash",
            systemPrompt: "System",
            userPrompt: "User"
        )

        let absoluteURL = try #require(request.url?.absoluteString)
        #expect(absoluteURL.contains(":generateContent"))
        #expect(!absoluteURL.contains("streamGenerateContent"))
    }
}
