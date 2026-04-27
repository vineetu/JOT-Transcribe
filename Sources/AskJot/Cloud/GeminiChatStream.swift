import Foundation

struct GeminiChatStream: CloudChatStream {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    private let maxToolCallsPerTurn = 2

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
                    try await runStream(
                        history: messages,
                        systemInstructions: systemInstructions,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        model: model,
                        maxTokens: maxTokens,
                        showFeatureTool: showFeatureTool,
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

    private func runStream(
        history: [CloudChatMessage],
        systemInstructions: String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int,
        showFeatureTool: @escaping (String) async -> String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var contents = history.map(\.geminiContent)
        var executedToolCalls = 0

        while true {
            try Task.checkCancellation()

            let request = try buildRequest(
                contents: contents,
                systemInstructions: systemInstructions,
                apiKey: apiKey,
                baseURL: baseURL,
                model: model,
                maxTokens: maxTokens
            )
            let pass = try await streamResponse(for: request, continuation: continuation)

            guard !pass.functionCalls.isEmpty else { return }

            let remainingBudget = maxToolCallsPerTurn - executedToolCalls
            guard remainingBudget > 0 else {
                throw GeminiChatStreamError.toolCallLimitExceeded(maxToolCallsPerTurn)
            }
            guard pass.functionCalls.count <= remainingBudget else {
                throw GeminiChatStreamError.toolCallLimitExceeded(maxToolCallsPerTurn)
            }

            contents.append(.init(role: .model, parts: pass.functionCalls.map(\.echoedPart)))
            contents.append(
                .init(
                    role: .user,
                    parts: try await executeToolCalls(pass.functionCalls, showFeatureTool: showFeatureTool)
                )
            )
            executedToolCalls += pass.functionCalls.count
        }
    }

    private func buildRequest(
        contents: [GeminiContent],
        systemInstructions: String,
        apiKey: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else {
            throw GeminiChatStreamError.invalidURL(baseURL)
        }
        var path = components.path
        if !path.hasSuffix("/") { path += "/" }
        path += "models/\(model):streamGenerateContent"
        components.path = path
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

        guard let url = components.url else {
            throw GeminiChatStreamError.invalidURL(baseURL)
        }

        let body = GeminiRequest(
            contents: contents,
            systemInstruction: .init(parts: [.text(systemInstructions)]),
            tools: [.showFeature],
            generationConfig: .init(maxOutputTokens: maxTokens)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func streamResponse(
        for request: URLRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> StreamPass {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiChatStreamError.invalidResponse
        }
        if !(200...299).contains(http.statusCode) {
            throw GeminiChatStreamError.httpError(
                statusCode: http.statusCode,
                body: try await readErrorBody(from: bytes)
            )
        }

        var eventLines: [String] = []
        var functionCalls: [GeminiFunctionCallPart] = []
        var seenCalls = Set<String>()
        var producedOutput = false

        func flush() throws {
            guard let payload = ssePayload(from: eventLines) else {
                eventLines.removeAll(keepingCapacity: true)
                return
            }
            eventLines.removeAll(keepingCapacity: true)

            let event = try decodeEvent(from: payload)
            guard let parts = event.candidates?.first?.content?.parts else { return }

            for part in parts {
                if let text = part.text, !text.isEmpty {
                    continuation.yield(text)
                    producedOutput = true
                }
                if let call = part.functionCall {
                    let wrapped = GeminiFunctionCallPart(part: part, call: call)
                    if seenCalls.insert(wrapped.deduplicationKey).inserted {
                        functionCalls.append(wrapped)
                        producedOutput = true
                    }
                }
            }
        }

        for try await rawLine in bytes.lines {
            try Task.checkCancellation()
            let line = rawLine.trimmingCharacters(in: .newlines)
            if line.isEmpty {
                try flush()
                continue
            }
            if shouldFlush(existingLines: eventLines, nextLine: line) { try flush() }
            eventLines.append(line)
        }
        try flush()

        guard producedOutput else {
            throw GeminiChatStreamError.emptyResponse
        }
        return StreamPass(functionCalls: functionCalls)
    }

    private func executeToolCalls(
        _ calls: [GeminiFunctionCallPart],
        showFeatureTool: @escaping (String) async -> String
    ) async throws -> [GeminiPart] {
        var responses: [GeminiPart] = []
        responses.reserveCapacity(calls.count)

        for call in calls {
            guard call.call.name == "showFeature" else {
                throw GeminiChatStreamError.unsupportedFunction(call.call.name)
            }
            guard let featureId = call.call.args.stringValue(forKey: "featureId"), !featureId.isEmpty else {
                throw GeminiChatStreamError.invalidFunctionArguments(call.call.name)
            }

            let result = await showFeatureTool(featureId)
            let response = GeminiFunctionResponse(
                name: "showFeature",
                id: call.call.id,
                response: .object(["result": .string(result)])
            )
            responses.append(.functionResponse(response))
        }
        return responses
    }

    private func shouldFlush(existingLines: [String], nextLine: String) -> Bool {
        existingLines.contains(where: { $0.hasPrefix("data:") }) &&
            (nextLine.hasPrefix("data:") || nextLine.hasPrefix("event:"))
    }

    private func ssePayload(from lines: [String]) -> String? {
        let dataLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        return payload == "[DONE]" ? nil : payload
    }

    private func decodeEvent(from payload: String) throws -> GeminiEvent {
        guard let data = payload.data(using: .utf8) else {
            throw GeminiChatStreamError.invalidUTF8Payload
        }
        do {
            return try JSONDecoder().decode(GeminiEvent.self, from: data)
        } catch {
            throw GeminiChatStreamError.decodingFailed(error)
        }
    }

    private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        for try await line in bytes.lines {
            body += line
            body += "\n"
        }
        return String(body.prefix(400))
    }
}

private extension CloudChatMessage {
    var geminiContent: GeminiContent {
        let geminiRole: GeminiContent.Role
        switch role {
        case .user:
            geminiRole = .user
        case .assistant, .tool:
            geminiRole = .model
        }
        return GeminiContent(role: geminiRole, parts: [.text(content)])
    }
}

private struct StreamPass { let functionCalls: [GeminiFunctionCallPart] }

private struct GeminiFunctionCallPart {
    let part: GeminiPart
    let call: GeminiFunctionCall
    var echoedPart: GeminiPart { part.echoedFunctionCallPart() }
    var deduplicationKey: String { "\(call.name)|\(call.id ?? "")|\(call.args.jsonString)|\(part.thoughtSignature ?? "")" }
}

private struct GeminiRequest: Encodable { let contents: [GeminiContent]; let systemInstruction: GeminiSystemInstruction; let tools: [GeminiTool]; let generationConfig: GeminiGenerationConfig }
private struct GeminiSystemInstruction: Encodable { let parts: [GeminiPart] }
private struct GeminiGenerationConfig: Encodable { let maxOutputTokens: Int }
private struct GeminiEvent: Decodable { let candidates: [GeminiCandidate]? }
private struct GeminiCandidate: Decodable { let content: GeminiContent? }

private struct GeminiTool: Encodable { let functionDeclarations: [GeminiFunctionDeclaration]; static let showFeature = GeminiTool(functionDeclarations: [.showFeature]) }

private struct GeminiFunctionDeclaration: Encodable {
    let name: String
    let description: String
    let parameters: GeminiFunctionParameters
    static let showFeature = GeminiFunctionDeclaration(name: "showFeature", description: "Highlight a specific feature card in the Jot Help page.", parameters: .showFeature)
}

private struct GeminiFunctionParameters: Encodable {
    let type: String
    let properties: [String: GeminiSchemaProperty]
    let required: [String]
    static let showFeature = GeminiFunctionParameters(type: "OBJECT", properties: ["featureId": .init(type: "STRING")], required: ["featureId"])
}

private struct GeminiSchemaProperty: Encodable { let type: String }
private struct GeminiContent: Codable, Sendable { enum Role: String, Codable, Sendable { case user, model }; let role: Role; let parts: [GeminiPart] }

private struct GeminiPart: Codable, Sendable {
    enum SignatureEncoding { case camelCase, snakeCase, none }
    enum CodingKeys: String, CodingKey { case text, functionCall, functionResponse; case thoughtSignature = "thoughtSignature"; case thoughtSignatureSnake = "thought_signature" }

    var text: String?
    var functionCall: GeminiFunctionCall?
    var functionResponse: GeminiFunctionResponse?
    var thoughtSignature: String?
    var signatureEncoding: SignatureEncoding = .none

    static func text(_ value: String) -> GeminiPart { .init(text: value) }
    static func functionResponse(_ value: GeminiFunctionResponse) -> GeminiPart { .init(functionResponse: value) }
    func echoedFunctionCallPart() -> GeminiPart { .init(functionCall: functionCall, thoughtSignature: thoughtSignature, signatureEncoding: signatureEncoding) }

    init(text: String? = nil, functionCall: GeminiFunctionCall? = nil, functionResponse: GeminiFunctionResponse? = nil, thoughtSignature: String? = nil, signatureEncoding: SignatureEncoding = .none) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
        self.thoughtSignature = thoughtSignature
        self.signatureEncoding = signatureEncoding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        functionCall = try container.decodeIfPresent(GeminiFunctionCall.self, forKey: .functionCall)
        functionResponse = try container.decodeIfPresent(GeminiFunctionResponse.self, forKey: .functionResponse)
        if let signature = try container.decodeIfPresent(String.self, forKey: .thoughtSignatureSnake) {
            thoughtSignature = signature
            signatureEncoding = .snakeCase
        } else if let signature = try container.decodeIfPresent(String.self, forKey: .thoughtSignature) {
            thoughtSignature = signature
            signatureEncoding = .camelCase
        } else {
            thoughtSignature = nil
            signatureEncoding = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(functionCall, forKey: .functionCall)
        try container.encodeIfPresent(functionResponse, forKey: .functionResponse)
        switch signatureEncoding {
        case .camelCase: try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
        case .snakeCase: try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignatureSnake)
        case .none: break
        }
    }
}

private struct GeminiFunctionCall: Codable, Sendable { let name: String; let args: JSONValue; let id: String? }
private struct GeminiFunctionResponse: Codable, Sendable { let name: String; let id: String?; let response: JSONValue }

private enum JSONValue: Codable, Sendable {
    case string(String), number(Double), object([String: JSONValue]), array([JSONValue]), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    func stringValue(forKey key: String) -> String? {
        guard case .object(let object) = self, case .string(let value)? = object[key] else { return nil }
        return value
    }

    var jsonString: String {
        guard let data = try? JSONEncoder().encode(self), let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }
}

private enum GeminiChatStreamError: LocalizedError {
    case invalidURL(String), invalidResponse, httpError(statusCode: Int, body: String), invalidUTF8Payload
    case decodingFailed(Error), unsupportedFunction(String), invalidFunctionArguments(String), toolCallLimitExceeded(Int), emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let baseURL): return "Gemini request URL is invalid: \(baseURL)"
        case .invalidResponse: return "Gemini returned a non-HTTP response."
        case .httpError(let statusCode, let body):
            return body.isEmpty ? "Gemini request failed with status \(statusCode)." : "Gemini request failed with status \(statusCode): \(body)"
        case .invalidUTF8Payload: return "Gemini returned a streaming payload with invalid UTF-8."
        case .decodingFailed(let error): return "Gemini returned an unreadable streaming event: \(error.localizedDescription)"
        case .unsupportedFunction(let name): return "Gemini requested an unsupported function: \(name)"
        case .invalidFunctionArguments(let name): return "Gemini returned invalid arguments for function \(name)."
        case .toolCallLimitExceeded(let limit): return "Gemini exceeded the per-turn tool-call limit of \(limit)."
        case .emptyResponse: return "Gemini returned an empty response."
        }
    }
}
