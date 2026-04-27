// TODO: unify provider dispatch per docs/plans/llm-unification-deferred.md — single CloudChatStream protocol when scaffolding consolidation lands.

import Foundation

struct OpenAIChatStream: CloudChatStream {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func streamChat(
        messages: [CloudChatMessage],
        systemInstructions: String,
        showFeatureTool: @escaping (String) async -> String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let seedMessages = requestMessages(from: messages)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runConversationLoop(
                        seedMessages: seedMessages,
                        systemInstructions: systemInstructions,
                        showFeatureTool: showFeatureTool,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        model: model,
                        maxTokens: maxTokens,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runConversationLoop(
        seedMessages: [RequestMessage],
        systemInstructions: String,
        showFeatureTool: @escaping (String) async -> String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var conversation = seedMessages
        var executedToolCalls = 0

        while !Task.isCancelled {
            let request = try makeRequest(
                conversation: conversation,
                systemInstructions: systemInstructions,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                maxTokens: maxTokens
            )

            let turn = try await streamTurn(request: request, continuation: continuation)
            switch turn.finishReason {
            case .toolCalls:
                let toolCalls = try finalizedToolCalls(from: turn.toolCallBuilders)
                guard !toolCalls.isEmpty else {
                    throw OpenAIChatStreamError.invalidResponse("finish_reason=tool_calls without any tool calls")
                }
                if executedToolCalls + toolCalls.count > Self.maxToolInvocationsPerTurn {
                    throw OpenAIChatStreamError.toolInvocationLimitExceeded(limit: Self.maxToolInvocationsPerTurn)
                }

                executedToolCalls += toolCalls.count
                conversation.append(
                    .assistantToolCalls(
                        content: turn.assistantText.isEmpty ? nil : turn.assistantText,
                        toolCalls: toolCalls
                    )
                )

                for toolCall in toolCalls {
                    let featureID = try parseFeatureID(from: toolCall.arguments)
                    let result = await showFeatureTool(featureID)
                    conversation.append(.tool(toolCallID: toolCall.id, content: result))
                }

            case .stop, .length, .contentFilter:
                return
            }
        }

        throw CancellationError()
    }

    private func makeRequest(
        conversation: [RequestMessage],
        systemInstructions: String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) throws -> URLRequest {
        guard let rootURL = URL(string: baseURL) else {
            throw OpenAIChatStreamError.invalidURL(baseURL)
        }

        let endpoint = rootURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        let payload: [String: Any] = [
            "model": model,
            "messages": ([RequestMessage.system(content: systemInstructions)] + conversation).map(\.jsonObject),
            "tools": [Self.showFeatureToolDefinition],
            "max_tokens": maxTokens,
            "stream": true
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw OpenAIChatStreamError.requestEncodingFailed(error.localizedDescription)
        }
        return request
    }

    private func streamTurn(
        request: URLRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> StreamedTurn {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw OpenAIChatStreamError.networkError(error.localizedDescription)
        }

        let shouldParseEvents = isSuccessfulHTTPResponse(response)
        var eventLines: [String] = []
        var rawLines: [String] = []
        var assistantText = ""
        var finishReason: FinishReason?
        var toolCallBuilders: [Int: ToolCallBuilder] = [:]
        var sawDone = false

        do {
            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(in: .newlines)
                rawLines.append(line)

                guard shouldParseEvents else { continue }

                if line.isEmpty {
                    sawDone = try processEvent(
                        lines: eventLines,
                        assistantText: &assistantText,
                        finishReason: &finishReason,
                        toolCallBuilders: &toolCallBuilders,
                        continuation: continuation
                    ) || sawDone
                    eventLines.removeAll(keepingCapacity: true)
                    if sawDone { break }
                    continue
                }

                if shouldFlushEvent(existingLines: eventLines, nextLine: line) {
                    sawDone = try processEvent(
                        lines: eventLines,
                        assistantText: &assistantText,
                        finishReason: &finishReason,
                        toolCallBuilders: &toolCallBuilders,
                        continuation: continuation
                    ) || sawDone
                    eventLines.removeAll(keepingCapacity: true)
                    if sawDone { break }
                }

                eventLines.append(line)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAIChatStreamError {
            throw error
        } catch {
            throw OpenAIChatStreamError.networkError(error.localizedDescription)
        }

        if shouldParseEvents && !sawDone {
            _ = try processEvent(
                lines: eventLines,
                assistantText: &assistantText,
                finishReason: &finishReason,
                toolCallBuilders: &toolCallBuilders,
                continuation: continuation
            )
        }

        try validateStreamingResponse(response, body: rawLines.joined(separator: "\n"))

        guard let finishReason else {
            throw OpenAIChatStreamError.invalidResponse("missing finish_reason in streamed response")
        }

        return StreamedTurn(
            assistantText: assistantText,
            finishReason: finishReason,
            toolCallBuilders: toolCallBuilders
        )
    }

    @discardableResult
    private func processEvent(
        lines: [String],
        assistantText: inout String,
        finishReason: inout FinishReason?,
        toolCallBuilders: inout [Int: ToolCallBuilder],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        switch try parseSSEEvent(lines: lines) {
        case .none:
            return false
        case .done:
            return true
        case .chunk(let chunk):
            if let error = chunk.error {
                throw OpenAIChatStreamError.apiError(error.message ?? "unknown OpenAI API error")
            }

            for choice in chunk.choices ?? [] {
                if let delta = choice.delta.content, !delta.isEmpty {
                    assistantText += delta
                    continuation.yield(delta)
                }

                if let toolCalls = choice.delta.toolCalls {
                    for toolDelta in toolCalls {
                        var builder = toolCallBuilders[toolDelta.index] ?? ToolCallBuilder()
                        builder.consume(toolDelta)
                        toolCallBuilders[toolDelta.index] = builder
                    }
                }

                if let streamedReason = choice.finishReason {
                    finishReason = streamedReason
                }
            }
            return false
        }
    }

    private func parseSSEEvent(lines: [String]) throws -> SSEEvent? {
        guard !lines.isEmpty else { return nil }

        let payloadLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !payloadLines.isEmpty else { return nil }

        let payload = payloadLines.joined(separator: "\n")
        if payload == "[DONE]" {
            return .done
        }

        guard let data = payload.data(using: .utf8) else {
            throw OpenAIChatStreamError.invalidUTF8Payload
        }

        do {
            return .chunk(try JSONDecoder().decode(StreamChunk.self, from: data))
        } catch {
            throw OpenAIChatStreamError.malformedJSON(error.localizedDescription)
        }
    }

    private func shouldFlushEvent(existingLines: [String], nextLine: String) -> Bool {
        guard existingLines.contains(where: { $0.hasPrefix("data:") }) else {
            return false
        }
        return nextLine.hasPrefix("data:") || nextLine.hasPrefix("event:")
    }

    private func validateStreamingResponse(_ response: URLResponse, body: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIChatStreamError.invalidResponse("expected HTTPURLResponse")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenAIChatStreamError.httpError(
                statusCode: httpResponse.statusCode,
                body: String(body.prefix(Self.maxErrorBodyLength))
            )
        }
    }

    private func isSuccessfulHTTPResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return (200...299).contains(httpResponse.statusCode)
    }

    private func finalizedToolCalls(from builders: [Int: ToolCallBuilder]) throws -> [CompletedToolCall] {
        try builders
            .sorted { $0.key < $1.key }
            .map { try $0.value.finalized(index: $0.key) }
    }

    private func parseFeatureID(from argumentsJSON: String) throws -> String {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw OpenAIChatStreamError.invalidUTF8Payload
        }

        let parsed: ShowFeatureArguments
        do {
            parsed = try JSONDecoder().decode(ShowFeatureArguments.self, from: data)
        } catch {
            throw OpenAIChatStreamError.invalidToolArguments(argumentsJSON)
        }

        let trimmed = parsed.featureId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAIChatStreamError.invalidToolArguments(argumentsJSON)
        }
        return trimmed
    }

    private func requestMessages(from messages: [CloudChatMessage]) -> [RequestMessage] {
        messages.map { message in
            switch message.role {
            case .user:
                return .user(content: message.content)
            case .assistant:
                return .assistant(content: message.content)
            case .tool(let callID, _):
                return .tool(toolCallID: callID, content: message.content)
            }
        }
    }

    private static let maxToolInvocationsPerTurn = 2
    private static let maxErrorBodyLength = 1_000
    private static let showFeatureToolDefinition: [String: Any] = [
        "type": "function",
        "function": [
            "name": "showFeature",
            "description": "Highlight a specific feature card in the Jot Help page.",
            "parameters": [
                "type": "object",
                "properties": [
                    "featureId": ["type": "string"]
                ],
                "required": ["featureId"]
            ]
        ]
    ]
}

private enum OpenAIChatStreamError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case requestEncodingFailed(String)
    case networkError(String)
    case httpError(statusCode: Int, body: String)
    case invalidResponse(String)
    case malformedJSON(String)
    case invalidUTF8Payload
    case apiError(String)
    case invalidToolArguments(String)
    case unknownToolName(String)
    case toolInvocationLimitExceeded(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let baseURL):
            return "Invalid OpenAI base URL: \(baseURL)"
        case .requestEncodingFailed(let detail):
            return "Failed to encode OpenAI chat request: \(detail)"
        case .networkError(let detail):
            return "OpenAI streaming request failed: \(detail)"
        case .httpError(let statusCode, let body):
            return "OpenAI request failed with HTTP \(statusCode): \(body)"
        case .invalidResponse(let detail):
            return "OpenAI streaming response was invalid: \(detail)"
        case .malformedJSON(let detail):
            return "Failed to decode streamed OpenAI event: \(detail)"
        case .invalidUTF8Payload:
            return "OpenAI streaming payload was not valid UTF-8"
        case .apiError(let detail):
            return "OpenAI API error: \(detail)"
        case .invalidToolArguments(let raw):
            return "OpenAI returned invalid showFeature arguments: \(raw)"
        case .unknownToolName(let name):
            return "OpenAI requested unsupported tool: \(name)"
        case .toolInvocationLimitExceeded(let limit):
            return "OpenAI exceeded the Ask Jot tool-call limit of \(limit) per turn"
        }
    }
}

private enum SSEEvent: Sendable {
    case chunk(StreamChunk)
    case done
}

private enum FinishReason: String, Decodable, Sendable {
    case stop
    case toolCalls = "tool_calls"
    case length
    case contentFilter = "content_filter"
}

private struct StreamedTurn: Sendable {
    let assistantText: String
    let finishReason: FinishReason
    let toolCallBuilders: [Int: ToolCallBuilder]
}

private struct StreamChunk: Decodable, Sendable {
    let choices: [StreamChoice]?
    let error: APIErrorPayload?
}

private struct StreamChoice: Decodable, Sendable {
    let delta: StreamDelta
    let finishReason: FinishReason?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct StreamDelta: Decodable, Sendable {
    let content: String?
    let toolCalls: [ToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

private struct ToolCallDelta: Decodable, Sendable {
    let index: Int
    let id: String?
    let function: ToolFunctionDelta?
    let type: String?
}

private struct ToolFunctionDelta: Decodable, Sendable {
    let name: String?
    let arguments: String?
}

private struct APIErrorPayload: Decodable, Sendable {
    let message: String?
}

private struct ToolCallBuilder: Sendable {
    var id: String?
    var name: String?
    var type: String?
    var arguments = ""

    mutating func consume(_ delta: ToolCallDelta) {
        if let id = delta.id, !id.isEmpty {
            self.id = id
        }
        if let name = delta.function?.name, !name.isEmpty {
            self.name = name
        }
        if let type = delta.type, !type.isEmpty {
            self.type = type
        }
        if let fragment = delta.function?.arguments {
            arguments.append(fragment)
        }
    }

    func finalized(index: Int) throws -> CompletedToolCall {
        guard let id, !id.isEmpty else {
            throw OpenAIChatStreamError.invalidResponse("tool call \(index) missing id")
        }
        guard let name, !name.isEmpty else {
            throw OpenAIChatStreamError.invalidResponse("tool call \(index) missing function name")
        }
        guard name == "showFeature" else {
            throw OpenAIChatStreamError.unknownToolName(name)
        }
        return CompletedToolCall(
            id: id,
            name: name,
            arguments: arguments,
            type: type ?? "function"
        )
    }
}

private struct CompletedToolCall: Sendable {
    let id: String
    let name: String
    let arguments: String
    let type: String

    var jsonObject: [String: Any] {
        [
            "id": id,
            "type": type,
            "function": [
                "name": name,
                "arguments": arguments
            ]
        ]
    }
}

private struct ShowFeatureArguments: Decodable, Sendable {
    let featureId: String
}

private enum RequestMessage: Sendable {
    case system(content: String)
    case user(content: String)
    case assistant(content: String)
    case assistantToolCalls(content: String?, toolCalls: [CompletedToolCall])
    case tool(toolCallID: String, content: String)

    var jsonObject: [String: Any] {
        switch self {
        case .system(let content):
            return ["role": "system", "content": content]
        case .user(let content):
            return ["role": "user", "content": content]
        case .assistant(let content):
            return ["role": "assistant", "content": content]
        case .assistantToolCalls(let content, let toolCalls):
            var object: [String: Any] = [
                "role": "assistant",
                "tool_calls": toolCalls.map(\.jsonObject)
            ]
            object["content"] = content ?? NSNull()
            return object
        case .tool(let toolCallID, let content):
            return [
                "role": "tool",
                "tool_call_id": toolCallID,
                "content": content
            ]
        }
    }
}
