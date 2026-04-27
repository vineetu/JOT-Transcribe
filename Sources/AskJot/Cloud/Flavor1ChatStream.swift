#if JOT_FLAVOR_1
// Sources/AskJot/Cloud/Flavor1ChatStream.swift — flavor_1 (PFB Enterprise) Ask Jot
// streaming branch. Bandage path per docs/plans/flavor1-askjot-stream.md; long-term
// AIService consolidation deferred per docs/plans/llm-unification-deferred.md.
//
// PFB exposes an OpenAI-shaped Chat Completions gateway, so this file is a
// near-duplicate of OpenAIChatStream.swift's text-streaming path. The 9
// divergences (plan §2.1) keep flavor_1's quirks confined here:
//   1. Auth via JWT from Flavor1Session.shared.currentJWT() (apiKey ignored).
//   2. JWT read hops to MainActor — makeRequest is async.
//   3. 401 fires Flavor1Client.invalidateOn401() before throwing.
//   4. Endpoint built by string-concat (`"\(baseURL)/chat/completions"`).
//   5. Token-limit key chosen via Flavor1Client.tokenLimitKey(forModel:)
//      (GPT-5 family wants `max_completion_tokens`, others `max_tokens`).
//   6. `Accept: text/event-stream` header set on the streaming request.
//   7. Error type renamed Flavor1ChatStreamError; copy says "PFB Enterprise".
//   8. v1 omits `tools: [...]` from the request body — no tool-calling, no
//      conversation loop. Citation coverage falls through to the provider-
//      agnostic slug post-processing in HelpChatStore (~61% baseline). v1.1
//      reconsideration gated on live PFB tool-call verification.
//   9. Entire file under `#if JOT_FLAVOR_1` so non-flavor builds skip it.

import Foundation

struct Flavor1ChatStream: CloudChatStream {
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
        // v1 omits the showFeature tool-call path entirely — slug post-processing
        // in HelpChatStore handles citations provider-agnostically.
        _ = showFeatureTool
        // Auth comes from Flavor1Session, not the apiKey parameter.
        _ = apiKey

        let conversation = requestMessages(from: messages)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await makeRequest(
                        conversation: conversation,
                        systemInstructions: systemInstructions,
                        baseURL: baseURL,
                        model: model,
                        maxTokens: maxTokens
                    )
                    try await streamTurn(request: request, continuation: continuation)
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

    private func makeRequest(
        conversation: [RequestMessage],
        systemInstructions: String,
        baseURL: String,
        model: String,
        maxTokens: Int
    ) async throws -> URLRequest {
        let jwt = await MainActor.run { Flavor1Session.shared.currentJWT() }
        guard let jwt, !jwt.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }

        guard let endpoint = URL(string: "\(baseURL)/chat/completions") else {
            throw Flavor1ChatStreamError.invalidURL(baseURL)
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": ([RequestMessage.system(content: systemInstructions)] + conversation).map(\.jsonObject),
            Flavor1Client.tokenLimitKey(forModel: model): maxTokens,
            "stream": true
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw Flavor1ChatStreamError.requestEncodingFailed(error.localizedDescription)
        }
        return request
    }

    private func streamTurn(
        request: URLRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Flavor1ChatStreamError.networkError(error.localizedDescription)
        }

        let shouldParseEvents = isSuccessfulHTTPResponse(response)
        var eventLines: [String] = []
        var rawLines: [String] = []
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
                        continuation: continuation
                    ) || sawDone
                    eventLines.removeAll(keepingCapacity: true)
                    if sawDone { break }
                    continue
                }

                if shouldFlushEvent(existingLines: eventLines, nextLine: line) {
                    sawDone = try processEvent(
                        lines: eventLines,
                        continuation: continuation
                    ) || sawDone
                    eventLines.removeAll(keepingCapacity: true)
                    if sawDone { break }
                }

                eventLines.append(line)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Flavor1ChatStreamError {
            throw error
        } catch {
            throw Flavor1ChatStreamError.networkError(error.localizedDescription)
        }

        if shouldParseEvents && !sawDone {
            _ = try processEvent(
                lines: eventLines,
                continuation: continuation
            )
        }

        try await validateStreamingResponse(response, body: rawLines.joined(separator: "\n"))
    }

    @discardableResult
    private func processEvent(
        lines: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        switch try parseSSEEvent(lines: lines) {
        case .none:
            return false
        case .done:
            return true
        case .chunk(let chunk):
            if let error = chunk.error {
                throw Flavor1ChatStreamError.apiError(error.message ?? "unknown PFB Enterprise API error")
            }

            for choice in chunk.choices ?? [] {
                if let delta = choice.delta.content, !delta.isEmpty {
                    continuation.yield(delta)
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
            throw Flavor1ChatStreamError.invalidUTF8Payload
        }

        do {
            return .chunk(try JSONDecoder().decode(StreamChunk.self, from: data))
        } catch {
            throw Flavor1ChatStreamError.malformedJSON(error.localizedDescription)
        }
    }

    private func shouldFlushEvent(existingLines: [String], nextLine: String) -> Bool {
        guard existingLines.contains(where: { $0.hasPrefix("data:") }) else {
            return false
        }
        return nextLine.hasPrefix("data:") || nextLine.hasPrefix("event:")
    }

    private func validateStreamingResponse(_ response: URLResponse, body: String) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Flavor1ChatStreamError.invalidResponse("expected HTTPURLResponse")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                await Flavor1Client.invalidateOn401()
            }
            throw Flavor1ChatStreamError.httpError(
                statusCode: httpResponse.statusCode,
                body: String(body.prefix(Self.maxErrorBodyLength))
            )
        }
    }

    private func isSuccessfulHTTPResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return (200...299).contains(httpResponse.statusCode)
    }

    private func requestMessages(from messages: [CloudChatMessage]) -> [RequestMessage] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return .user(content: message.content)
            case .assistant:
                return .assistant(content: message.content)
            case .tool:
                // v1 omits tool-calling — historical .tool messages from older
                // turns are dropped rather than re-sent in an OpenAI-tool shape
                // PFB never asked for. HelpChatStore filters streaming entries
                // already; this guard is belt-and-braces.
                return nil
            }
        }
    }

    private static let maxErrorBodyLength = 1_000
}

private enum Flavor1ChatStreamError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case requestEncodingFailed(String)
    case networkError(String)
    case httpError(statusCode: Int, body: String)
    case invalidResponse(String)
    case malformedJSON(String)
    case invalidUTF8Payload
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let baseURL):
            return "Invalid PFB Enterprise base URL: \(baseURL)"
        case .requestEncodingFailed(let detail):
            return "Failed to encode PFB Enterprise chat request: \(detail)"
        case .networkError(let detail):
            return "PFB Enterprise streaming request failed: \(detail)"
        case .httpError(let statusCode, let body):
            return "PFB Enterprise request failed with HTTP \(statusCode): \(body)"
        case .invalidResponse(let detail):
            return "PFB Enterprise streaming response was invalid: \(detail)"
        case .malformedJSON(let detail):
            return "Failed to decode streamed PFB Enterprise event: \(detail)"
        case .invalidUTF8Payload:
            return "PFB Enterprise streaming payload was not valid UTF-8"
        case .apiError(let detail):
            return "PFB Enterprise API error: \(detail)"
        }
    }
}

private enum SSEEvent: Sendable {
    case chunk(StreamChunk)
    case done
}

private struct StreamChunk: Decodable, Sendable {
    let choices: [StreamChoice]?
    let error: APIErrorPayload?
}

private struct StreamChoice: Decodable, Sendable {
    let delta: StreamDelta
}

private struct StreamDelta: Decodable, Sendable {
    let content: String?
}

private struct APIErrorPayload: Decodable, Sendable {
    let message: String?
}

private enum RequestMessage: Sendable {
    case system(content: String)
    case user(content: String)
    case assistant(content: String)

    var jsonObject: [String: Any] {
        switch self {
        case .system(let content):
            return ["role": "system", "content": content]
        case .user(let content):
            return ["role": "user", "content": content]
        case .assistant(let content):
            return ["role": "assistant", "content": content]
        }
    }
}
#endif
