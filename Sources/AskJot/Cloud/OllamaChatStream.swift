import Foundation

struct OllamaChatStream: CloudChatStream {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    private let maxToolInvocations = 2

    func streamChat(
        messages: [CloudChatMessage],
        systemInstructions: String,
        showFeatureTool: @escaping (String) async -> String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamConversation(
                        messages: messages,
                        systemInstructions: systemInstructions,
                        showFeatureTool: showFeatureTool,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        model: model,
                        maxTokens: maxTokens,
                        into: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamConversation(
        messages: [CloudChatMessage],
        systemInstructions: String,
        showFeatureTool: @escaping (String) async -> String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var conversation = initialMessages(from: messages, systemInstructions: systemInstructions)
        var remainingToolInvocations = maxToolInvocations
        var yieldedAnyContent = false

        while true {
            let pass = try await runPass(
                messages: conversation,
                remainingToolInvocations: remainingToolInvocations,
                showFeatureTool: showFeatureTool,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                maxTokens: maxTokens,
                continuation: continuation
            )
            yieldedAnyContent = yieldedAnyContent || pass.emittedText
            guard pass.shouldContinue, let assistantMessage = pass.assistantMessage else { break }
            conversation.append(assistantMessage)
            conversation.append(contentsOf: pass.toolMessages)
            remainingToolInvocations -= pass.toolMessages.count
            if remainingToolInvocations <= 0 { break }
        }

        if !yieldedAnyContent {
            throw LLMError.emptyResponse
        }
    }

    private func runPass(
        messages: [OllamaRequestMessage],
        remainingToolInvocations: Int,
        showFeatureTool: @escaping (String) async -> String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> PassResult {
        let request = try makeRequest(
            messages: messages,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            maxTokens: maxTokens
        )
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            let body = try await readBody(from: bytes)
            throw LLMError.httpError(statusCode: http.statusCode, body: String(body.prefix(200)))
        }

        let decoder = JSONDecoder()
        var lineBuffer = Data()
        var assistantContent = ""
        var toolCalls: [OllamaToolCall] = []
        var seenToolCalls = Set<String>()
        var sawDone = false

        func parseLine(_ data: Data) throws {
            let line = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }

            let chunk: OllamaChatChunk
            do {
                chunk = try decoder.decode(OllamaChatChunk.self, from: Data(line.utf8))
            } catch {
                throw LLMError.decodingError(error)
            }

            sawDone = sawDone || chunk.done
            if let content = chunk.message?.content, !content.isEmpty {
                assistantContent += content
                continuation.yield(content)
            }
            if let chunkToolCalls = chunk.message?.toolCalls, !chunkToolCalls.isEmpty {
                for toolCall in chunkToolCalls {
                    let key = toolCallKey(for: toolCall)
                    if seenToolCalls.insert(key).inserted {
                        toolCalls.append(toolCall)
                    }
                }
            }
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 0x0A {
                try parseLine(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
            } else {
                lineBuffer.append(byte)
            }
        }
        if !lineBuffer.isEmpty {
            try parseLine(lineBuffer)
        }

        if toolCalls.isEmpty {
            if !sawDone && assistantContent.isEmpty {
                throw LLMError.emptyResponse
            }
            return .init(emittedText: !assistantContent.isEmpty, assistantMessage: nil, toolMessages: [], shouldContinue: false)
        }
        guard remainingToolInvocations > 0 else {
            return .init(emittedText: !assistantContent.isEmpty, assistantMessage: nil, toolMessages: [], shouldContinue: false)
        }

        var toolMessages: [OllamaRequestMessage] = []
        // Tool support is model-dependent on Ollama. If tools are ignored or malformed,
        // HelpChatStore still has its slug-injection fallback after the text completes.
        for toolCall in toolCalls {
            guard toolMessages.count < remainingToolInvocations else { break }
            guard toolCall.function.name == "showFeature" else { continue }
            let featureId = toolCall.function.arguments?.featureId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let featureId, !featureId.isEmpty else { continue }
            toolMessages.append(
                .init(
                    role: .tool,
                    content: await runShowFeatureTool(featureId: featureId, showFeatureTool: showFeatureTool),
                    toolName: "showFeature"
                )
            )
        }
        guard !toolMessages.isEmpty else {
            return .init(emittedText: !assistantContent.isEmpty, assistantMessage: nil, toolMessages: [], shouldContinue: false)
        }

        let assistantMessage = OllamaRequestMessage(
            role: .assistant,
            content: assistantContent.isEmpty ? nil : assistantContent,
            toolCalls: toolCalls
        )
        return .init(emittedText: !assistantContent.isEmpty, assistantMessage: assistantMessage, toolMessages: toolMessages, shouldContinue: true)
    }

    private func initialMessages(
        from messages: [CloudChatMessage],
        systemInstructions: String
    ) -> [OllamaRequestMessage] {
        [.init(role: .system, content: systemInstructions)] + messages.map(OllamaRequestMessage.init)
    }

    private func makeRequest(
        messages: [OllamaRequestMessage],
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) throws -> URLRequest {
        guard let url = nativeChatURL(baseURL: baseURL) else { throw LLMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let body = OllamaChatRequest(
            model: model,
            messages: messages,
            tools: [.showFeature],
            stream: true,
            options: .init(numPredict: maxTokens)
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LLMError.decodingError(error)
        }
        return request
    }

    private func nativeChatURL(baseURL: String) -> URL? {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        value = dropSuffix("/chat/completions", from: value)
        value = dropSuffix("/v1", from: value)
        value = dropSuffix("/api", from: value)
        guard !value.isEmpty else { return nil }
        let url = URL(string: "\(value)/api/chat")
        return url?.scheme == nil ? nil : url
    }

    private func dropSuffix(_ suffix: String, from value: String) -> String {
        value.hasSuffix(suffix) ? String(value.dropLast(suffix.count)) : value
    }

    private func readBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes where data.count < 4_096 {
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func runShowFeatureTool(
        featureId: String,
        showFeatureTool: @escaping (String) async -> String
    ) async -> String {
        await showFeatureTool(featureId)
    }

    private func toolCallKey(for toolCall: OllamaToolCall) -> String {
        "\(toolCall.function.name)|\(toolCall.function.index.map(String.init) ?? "-")|\(toolCall.function.arguments?.featureId ?? "-")"
    }

    private func mapError(_ error: Error) -> LLMError {
        (error as? LLMError) ?? .networkError(error)
    }
}

private struct PassResult { let emittedText: Bool; let assistantMessage: OllamaRequestMessage?; let toolMessages: [OllamaRequestMessage]; let shouldContinue: Bool }
private struct OllamaChatRequest: Encodable { let model: String; let messages: [OllamaRequestMessage]; let tools: [OllamaToolDefinition]; let stream: Bool; let options: OllamaChatOptions }

private struct OllamaChatOptions: Encodable {
    let numPredict: Int
    enum CodingKeys: String, CodingKey { case numPredict = "num_predict" }
}

private struct OllamaRequestMessage: Encodable {
    let role: OllamaRequestRole
    let content: String?
    let toolName: String?
    let toolCalls: [OllamaToolCall]?
    enum CodingKeys: String, CodingKey {
        case role, content
        case toolName = "tool_name"
        case toolCalls = "tool_calls"
    }
    init(role: OllamaRequestRole, content: String?, toolName: String? = nil, toolCalls: [OllamaToolCall]? = nil) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCalls = toolCalls
    }
    init(_ message: CloudChatMessage) {
        switch message.role {
        case .user:
            self.init(role: .user, content: message.content)
        case .assistant:
            self.init(role: .assistant, content: message.content)
        case .tool(_, let name):
            self.init(role: .tool, content: message.content, toolName: name)
        }
    }
}

private enum OllamaRequestRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

private struct OllamaToolDefinition: Encodable {
    let type: String
    let function: ToolSchema

    static let showFeature = OllamaToolDefinition(
        type: "function",
        function: .init(
            name: "showFeature",
            description: "Highlight a specific feature card in the Jot Help page.",
            parameters: .init(
                type: "object",
                properties: ["featureId": .init(type: "string")],
                required: ["featureId"]
            )
        )
    )
}

private struct ToolSchema: Encodable { let name: String; let description: String; let parameters: ToolParameters }
private struct ToolParameters: Encodable { let type: String; let properties: [String: ToolProperty]; let required: [String] }
private struct ToolProperty: Encodable { let type: String }
private struct OllamaChatChunk: Decodable { let message: OllamaChunkMessage?; let done: Bool }

private struct OllamaChunkMessage: Decodable {
    let role: String?
    let content: String?
    let toolCalls: [OllamaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

private struct OllamaToolCall: Codable { let type: String?; let function: OllamaToolFunction }
private struct OllamaToolFunction: Codable { let index: Int?; let name: String; let description: String?; let arguments: OllamaToolArguments? }

private struct OllamaToolArguments: Codable {
    let featureId: String?
    enum CodingKeys: String, CodingKey { case featureId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .featureId) {
            featureId = value
        } else if let value = try? container.decode(Int.self, forKey: .featureId) {
            featureId = String(value)
        } else if let value = try? container.decode(Double.self, forKey: .featureId) {
            featureId = String(value)
        } else if let value = try? container.decode(Bool.self, forKey: .featureId) {
            featureId = String(value)
        } else {
            featureId = nil
        }
    }
}
