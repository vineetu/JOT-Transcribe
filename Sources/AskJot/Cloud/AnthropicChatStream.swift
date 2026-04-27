import Foundation

struct AnthropicChatStream: CloudChatStream {
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runConversation(
                        systemInstructions: systemInstructions,
                        messages: messages,
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runConversation(
        systemInstructions: String,
        messages: [CloudChatMessage],
        showFeatureTool: @escaping (String) async -> String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var history = messages.compactMap(AnthropicRequestMessage.init)
        var toolCallsUsed = 0

        while !Task.isCancelled {
            let turn = try await sendTurn(
                systemInstructions: systemInstructions,
                messages: history,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                maxTokens: maxTokens,
                continuation: continuation
            )
            guard turn.stopReason == "tool_use", !turn.toolCalls.isEmpty else { return }
            guard toolCallsUsed + turn.toolCalls.count <= 2 else { throw StreamError.toolInvocationLimitReached }

            toolCallsUsed += turn.toolCalls.count
            let toolResults = await execute(toolCalls: turn.toolCalls, showFeatureTool: showFeatureTool)
            history.append(.init(role: .assistant, content: .array(turn.content.map { $0.jsonValue })))
            history.append(.init(role: .user, content: .array(toolResults.map { $0.jsonValue })))
        }
    }

    private func sendTurn(
        systemInstructions: String,
        messages: [AnthropicRequestMessage],
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> TurnResponse {
        let request = try makeRequest(
            systemInstructions: systemInstructions,
            messages: messages,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            maxTokens: maxTokens
        )
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StreamError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw StreamError.httpError(statusCode: http.statusCode, body: try await collectBody(from: bytes))
        }

        var parser = SSEParser()
        var openBlocks: [Int: BlockState] = [:]
        var closedBlocks: [Int: AssistantContentBlock] = [:]
        var toolCalls: [PendingToolCall] = []
        var stopReason: String?

        for try await line in bytes.lines {
            for event in parser.consume(line) {
                switch try eventKind(in: event.data) {
                case "message_start", "ping":
                    break
                case "content_block_start":
                    let start: ContentBlockStartEvent = try decode(event.data)
                    if let block = BlockState(start.contentBlock) { openBlocks[start.index] = block }
                case "content_block_delta":
                    let delta: ContentBlockDeltaEvent = try decode(event.data)
                    guard var block = openBlocks[delta.index] else { break }
                    if let chunk = block.apply(delta.delta) { continuation.yield(chunk) }
                    openBlocks[delta.index] = block
                case "content_block_stop":
                    let stop: ContentBlockStopEvent = try decode(event.data)
                    guard let block = openBlocks.removeValue(forKey: stop.index) else { break }
                    let finalized = block.finalize()
                    closedBlocks[stop.index] = finalized.block
                    if let toolCall = finalized.toolCall { toolCalls.append(toolCall) }
                case "message_delta":
                    let delta: MessageDeltaEvent = try decode(event.data)
                    stopReason = delta.delta.stopReason ?? stopReason
                case "message_stop":
                    return TurnResponse(
                        content: closedBlocks.keys.sorted().compactMap { closedBlocks[$0] },
                        toolCalls: toolCalls,
                        stopReason: stopReason
                    )
                case "error":
                    let error: StreamErrorEvent = try decode(event.data)
                    throw StreamError.remote(error.error.message)
                default:
                    break
                }
            }
        }

        if let trailing = parser.finish(), try eventKind(in: trailing.data) == "message_stop" {
            return TurnResponse(
                content: closedBlocks.keys.sorted().compactMap { closedBlocks[$0] },
                toolCalls: toolCalls,
                stopReason: stopReason
            )
        }

        return TurnResponse(
            content: closedBlocks.keys.sorted().compactMap { closedBlocks[$0] },
            toolCalls: toolCalls,
            stopReason: stopReason
        )
    }

    private func makeRequest(
        systemInstructions: String,
        messages: [AnthropicRequestMessage],
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/messages") else { throw StreamError.invalidURL(baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = RequestBody(
            model: model,
            maxTokens: maxTokens,
            system: systemInstructions,
            messages: messages,
            tools: [.showFeature],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func execute(
        toolCalls: [PendingToolCall],
        showFeatureTool: @escaping (String) async -> String
    ) async -> [ToolResultBlock] {
        var results: [ToolResultBlock] = []
        results.reserveCapacity(toolCalls.count)
        for toolCall in toolCalls {
            let result = await toolResult(for: toolCall, showFeatureTool: showFeatureTool)
            results.append(.init(toolUseId: toolCall.id, content: result))
        }
        return results
    }

    private func toolResult(
        for toolCall: PendingToolCall,
        showFeatureTool: @escaping (String) async -> String
    ) async -> String {
        guard toolCall.name == "showFeature",
              case .object(let object) = toolCall.input,
              case .string(let featureId)? = object["featureId"] else { return "Feature not available" }
        return await showFeatureTool(featureId)
    }

    private func eventKind(in data: String) throws -> String {
        guard let raw = data.data(using: .utf8) else { throw StreamError.invalidEventData }
        return try JSONDecoder().decode(EventMarker.self, from: raw).type
    }

    private func decode<T: Decodable>(_ data: String) throws -> T {
        guard let raw = data.data(using: .utf8) else { throw StreamError.invalidEventData }
        return try JSONDecoder().decode(T.self, from: raw)
    }

    private func collectBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var lines: [String] = []
        for try await line in bytes.lines {
            lines.append(line)
            if lines.count == 8 { break }
        }
        return String(lines.joined(separator: "\n").prefix(240))
    }
}

private enum StreamError: LocalizedError {
    case invalidURL(String), invalidResponse, invalidEventData, httpError(statusCode: Int, body: String), remote(String), toolInvocationLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidURL(let baseURL): return "Anthropic Ask Jot URL is invalid: \(baseURL)"
        case .invalidResponse: return "Anthropic Ask Jot returned an invalid HTTP response."
        case .invalidEventData: return "Anthropic Ask Jot returned malformed event data."
        case .httpError(let code, let body): return body.isEmpty ? "Anthropic Ask Jot failed with HTTP \(code)." : "Anthropic Ask Jot failed with HTTP \(code): \(body)"
        case .remote(let message): return "Anthropic Ask Jot stream error: \(message)"
        case .toolInvocationLimitReached: return "Anthropic Ask Jot exceeded the tool-call limit for one turn."
        }
    }
}

private struct RequestBody: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicRequestMessage]
    let tools: [ToolDefinition]
    let stream: Bool

    enum CodingKeys: String, CodingKey { case model, system, messages, tools, stream; case maxTokens = "max_tokens" }
}

private struct AnthropicRequestMessage: Encodable {
    let role: AnthropicMessageRole
    let content: JSONValue

    init(role: AnthropicMessageRole, content: JSONValue) {
        self.role = role
        self.content = content
    }

    init?(_ message: CloudChatMessage) {
        switch message.role {
        case .user:
            self.init(role: .user, content: .string(message.content))
        case .assistant:
            self.init(role: .assistant, content: .string(message.content))
        case .tool:
            return nil
        }
    }
}

private enum AnthropicMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

private struct ToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: ToolInputSchema

    enum CodingKeys: String, CodingKey { case name, description; case inputSchema = "input_schema" }

    static let showFeature = ToolDefinition(
        name: "showFeature",
        description: "Highlight a specific feature card in the Jot Help page.",
        inputSchema: .init(type: "object", properties: ["featureId": .init(type: "string")], required: ["featureId"])
    )
}

private struct ToolInputSchema: Encodable { let type: String; let properties: [String: ToolSchemaProperty]; let required: [String] }
private struct ToolSchemaProperty: Encodable { let type: String }

private struct EventMarker: Decodable { let type: String }
private struct ContentBlockStartEvent: Decodable { let index: Int; let contentBlock: StreamContentBlock; enum CodingKeys: String, CodingKey { case index; case contentBlock = "content_block" } }
private struct ContentBlockDeltaEvent: Decodable { let index: Int; let delta: StreamContentDelta }
private struct ContentBlockStopEvent: Decodable { let index: Int }
private struct MessageDeltaEvent: Decodable { let delta: MessageDeltaPayload }
private struct MessageDeltaPayload: Decodable { let stopReason: String?; enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" } }
private struct StreamErrorEvent: Decodable { let error: RemoteErrorPayload }
private struct RemoteErrorPayload: Decodable { let type: String; let message: String }
private struct StreamContentBlock: Decodable { let type: String; let text: String?; let id: String?; let name: String?; let input: JSONValue? }
private struct StreamContentDelta: Decodable { let type: String; let text: String?; let partialJSON: String?; enum CodingKeys: String, CodingKey { case type, text; case partialJSON = "partial_json" } }

private struct TurnResponse { let content: [AssistantContentBlock]; let toolCalls: [PendingToolCall]; let stopReason: String? }
private struct PendingToolCall { let id: String; let name: String; let input: JSONValue }

private struct ToolResultBlock {
    let toolUseId: String
    let content: String

    var jsonValue: JSONValue {
        .object(["type": .string("tool_result"), "tool_use_id": .string(toolUseId), "content": .string(content)])
    }
}

private enum AssistantContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)

    var jsonValue: JSONValue {
        switch self {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .toolUse(let id, let name, let input):
            return .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])
        }
    }
}

private enum BlockState {
    case text(String)
    case toolUse(id: String, name: String, initialInput: JSONValue, partialJSON: String)

    init?(_ block: StreamContentBlock) {
        switch block.type {
        case "text": self = .text(block.text ?? "")
        case "tool_use":
            guard let id = block.id, let name = block.name else { return nil }
            self = .toolUse(id: id, name: name, initialInput: block.input ?? .object([:]), partialJSON: "")
        default: return nil
        }
    }

    mutating func apply(_ delta: StreamContentDelta) -> String? {
        switch self {
        case .text(var text):
            guard delta.type == "text_delta", let chunk = delta.text else { self = .text(text); return nil }
            text += chunk
            self = .text(text)
            return chunk
        case .toolUse(let id, let name, let initialInput, var partialJSON):
            if delta.type == "input_json_delta", let piece = delta.partialJSON { partialJSON += piece }
            self = .toolUse(id: id, name: name, initialInput: initialInput, partialJSON: partialJSON)
            return nil
        }
    }

    func finalize() -> (block: AssistantContentBlock, toolCall: PendingToolCall?) {
        switch self {
        case .text(let text):
            return (.text(text), nil)
        case .toolUse(let id, let name, let initialInput, let partialJSON):
            let input: JSONValue
            if !partialJSON.isEmpty, let data = partialJSON.data(using: .utf8), let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                input = decoded
            } else {
                input = initialInput
            }
            return (.toolUse(id: id, name: name, input: input), .init(id: id, name: name, input: input))
        }
    }
}

private struct SSEEvent { let type: String; let data: String }

private struct SSEParser {
    private var currentType: String?
    private var currentData: [String] = []

    mutating func consume(_ line: String) -> [SSEEvent] {
        let trimmed = line.trimmingCharacters(in: .newlines)
        if trimmed.isEmpty { return flush().map { [$0] } ?? [] }
        if trimmed.hasPrefix("event:") {
            let nextType = payload(in: trimmed, after: "event:")
            if currentType != nil || !currentData.isEmpty {
                let event = flush()
                currentType = nextType
                return event.map { [$0] } ?? []
            }
            currentType = nextType
            return []
        }
        if trimmed.hasPrefix("data:") { currentData.append(payload(in: trimmed, after: "data:")) }
        return []
    }

    mutating func finish() -> SSEEvent? { flush() }

    private mutating func flush() -> SSEEvent? {
        guard currentType != nil || !currentData.isEmpty else { return nil }
        let event = SSEEvent(type: currentType ?? "", data: currentData.joined(separator: "\n"))
        currentType = nil
        currentData.removeAll(keepingCapacity: true)
        return event
    }

    private func payload(in line: String, after prefix: String) -> String {
        let value = String(line.dropFirst(prefix.count))
        return value.first == " " ? String(value.dropFirst()) : value
    }
}

private indirect enum JSONValue: Codable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { self = .string(string); return }
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let number = try? container.decode(Double.self) { self = .number(number); return }
        if let object = try? container.decode([String: JSONValue].self) { self = .object(object); return }
        if let array = try? container.decode([JSONValue].self) { self = .array(array); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
