import Foundation

actor LLMClient {
    private let session: URLSession
    private let appleClient: AppleIntelligenceClient

    init(
        session: URLSession? = nil,
        appleClient: AppleIntelligenceClient = AppleIntelligenceClient()
    ) {
        self.session = session ?? URLSession(configuration: LLMClient.makeSessionConfiguration())
        self.appleClient = appleClient
    }

    private static func makeSessionConfiguration(
        requestTimeout: TimeInterval = 3,
        resourceTimeout: TimeInterval = 120
    ) -> URLSessionConfiguration {
        // Session default `timeoutIntervalForRequest` stays tight (3s) to
        // give any uncared-for callers fast failure on an unreachable
        // endpoint. The long-running paths — `articulate`, `transform`,
        // `healthCheck` — set their own per-request `timeoutInterval`
        // before handing off to `performLLMRequest`, which overrides the
        // session default for that request. `streamResponse` additionally
        // enforces a 3s first-byte watchdog of its own so reachability
        // fast-fail is preserved even when the per-request override is
        // generous.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    /// Articulate a selection according to the user's spoken instruction.
    /// (Formerly `rewrite(…)` — renamed with the v1.5 "Articulate (Custom)"
    /// relabel. Behaviorally identical to v1.4 `rewrite`.)
    func articulate(selectedText: String, instruction: String) async throws -> String {
        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            let p = c.provider
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p),
                sharedInvariants: c.articulatePrompt
            )
        }

        // Route the instruction to a branch-specific tendency block.
        // The classifier is a hint, not a gate — the user's instruction
        // is embedded verbatim below and always wins over the tendency.
        let branch = ArticulateInstructionClassifier.classify(instruction)
        let systemPrompt = """
            \(config.sharedInvariants)

            \(ArticulateBranchPrompt.prompt(for: branch))
            """

        // On-device Apple Intelligence short-circuits the HTTP path entirely.
        if config.provider == .appleIntelligence {
            do {
                return try await appleClient.articulate(
                    selectedText: selectedText,
                    instruction: instruction,
                    branchPrompt: systemPrompt
                )
            } catch {
                let mapped = mapError(error)
                logLLMError(mapped, provider: config.provider, request: nil, streaming: false, op: "articulate")
                throw mapped
            }
        }

        if config.provider != .ollama {
            guard !config.apiKey.isEmpty else {
                Task { await ErrorLog.shared.error(component: "LLMClient", message: "Missing API key", context: ["provider": config.provider.rawValue, "op": "articulate"]) }
                throw LLMError.noAPIKey
            }
        }

        // XML-tag delimiters (OWASP 2025 prompt-injection hardening) and
        // an explicit "instruction is the primary directive" framing so
        // the LLM attends to the user's voice instruction over any
        // residual bias from the tendency block.
        let userPrompt = """
            <instruction>
            \(instruction)
            </instruction>

            <selection>
            \(selectedText)
            </selection>

            Follow the <instruction> above. Rewrite the <selection> and return only the rewritten text.
            """

        var request = try buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.1,
            stream: shouldStream(provider: config.provider)
        )
        // Per-request override: once streaming starts, between-byte gaps
        // can exceed the 3s session default (model producing tokens at
        // varying rates, backpressure, etc.). The 3s reachability check is
        // still enforced by the first-byte watchdog inside streamResponse
        // — this override only affects what happens AFTER the first byte.
        request.timeoutInterval = 60

        return try await performLLMRequest(provider: config.provider, request: request)
    }

    private func buildRequest(
        provider: LLMProvider,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.3,
        stream: Bool = false
    ) throws -> URLRequest {
        switch provider {
        case .appleIntelligence:
            // Apple Intelligence is dispatched before request building.
            // If this branch is reached it's a programmer error — callers
            // must route `.appleIntelligence` through `AppleIntelligenceClient`.
            throw LLMError.appleIntelligenceUnavailable
        case .openai, .ollama:
            return try buildOpenAIRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: temperature, stream: stream
            )
        case .anthropic:
            return try buildAnthropicRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: temperature, stream: stream
            )
        case .gemini:
            return try buildGeminiRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: temperature, stream: stream
            )
        }
    }

    private func buildOpenAIRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        temperature: Double,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
        ]
        if stream {
            body["stream"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildAnthropicRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        temperature: Double,
        stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/messages") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
        ]
        if stream {
            body["stream"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildGeminiRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        temperature: Double,
        stream: Bool
    ) throws -> URLRequest {
        let endpoint = stream ? "streamGenerateContent?alt=sse&key=\(apiKey)" : "generateContent?key=\(apiKey)"
        guard let url = URL(string: "\(baseURL)/models/\(model):\(endpoint)") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let combinedPrompt = "System: \(systemPrompt)\n\nUser: \(userPrompt)"
        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": combinedPrompt]]]
            ],
            "generationConfig": ["temperature": temperature],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func shouldStream(provider: LLMProvider) -> Bool {
        switch provider {
        case .openai, .anthropic, .gemini, .ollama:
            return true
        case .appleIntelligence:
            return false
        }
    }

    private func performLLMRequest(provider: LLMProvider, request: URLRequest) async throws -> String {
        do {
            if shouldStream(provider: provider) {
                return try await streamResponse(provider: provider, request: request)
            }

            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response, data: data)
            return try parseResponse(provider: provider, data: data)
        } catch {
            let mapped = mapError(error)
            logLLMError(mapped, provider: provider, request: request, streaming: false)
            throw mapped
        }
    }

    private func logLLMError(_ error: LLMError, provider: LLMProvider, request: URLRequest?, streaming: Bool, op: String = "request") {
        let host = request?.url.map { ErrorLog.redactedURL($0) } ?? "n/a"
        var context: [String: String] = [
            "provider": provider.rawValue,
            "host": host,
            "stream": streaming ? "true" : "false",
            "op": op,
        ]
        let message: String
        switch error {
        case .noAPIKey:
            message = "Missing API key"
        case .invalidURL:
            message = "Invalid endpoint URL"
        case .httpError(let statusCode, let body):
            message = ErrorLog.redactedHTTPError(statusCode: statusCode, provider: provider.rawValue, bodyLength: body.count)
            context["status"] = String(statusCode)
            context["bodyLength"] = String(body.count)
        case .decodingError(let inner):
            message = "Failed to decode response"
            context["error"] = ErrorLog.redactedAppleError(inner)
        case .emptyResponse:
            message = "Empty response from provider"
        case .networkError(let inner):
            message = "Network error"
            context["error"] = ErrorLog.redactedAppleError(inner)
        case .suspiciousResponse:
            message = "Suspicious response length (transform clamp tripped)"
        case .appleIntelligenceUnavailable:
            message = "Apple Intelligence unavailable"
        case .appleIntelligenceFailure(let detail):
            message = "Apple Intelligence failure"
            // detail is our own string (e.g. "stalled"); fine to include shape, redact body content.
            context["detail"] = String(detail.prefix(80))
        }
        Task { await ErrorLog.shared.error(component: "LLMClient", message: message, context: context) }
    }

    private func streamResponse(provider: LLMProvider, request: URLRequest) async throws -> String {
        // First-byte watchdog: reachability fail-fast. If the server
        // doesn't send its response headers within 3 seconds of us firing
        // the request, we assume the host is unreachable/dead and surface
        // a network timeout error right away — without waiting out the
        // generous per-request `timeoutInterval` (which exists only to
        // protect against between-byte gaps once streaming has started).
        //
        // `URLSession.bytes(for:)` blocks until response headers arrive,
        // then returns a byte stream we can iterate. Racing that call
        // against a 3s `Task.sleep` in a TaskGroup gives us the split
        // "3s reachability / 60s streaming" behavior URLSession doesn't
        // expose natively. Losing tasks are cancelled — for the bytes
        // task, cancellation propagates through URLSession and aborts
        // the underlying HTTP request cleanly.
        let (bytes, response) = try await firstByteOrTimeout(
            request: request,
            timeout: .seconds(3)
        )

        var eventLines: [String] = []
        var accumulated = ""
        var rawResponseLines: [String] = []

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .newlines)
            rawResponseLines.append(line)
            if line.isEmpty {
                if let chunk = try parseSSEEvent(provider: provider, lines: eventLines) {
                    accumulated += chunk
                }
                eventLines.removeAll(keepingCapacity: true)
                continue
            }

            // Some live providers stream one `data:` record per line, but
            // `AsyncBytes.lines` does not reliably surface the empty SSE
            // separator lines. When a new field arrives after we've already
            // captured a payload line, flush the current event first so we
            // don't concatenate multiple JSON objects into one parse attempt.
            if shouldFlushSSEEvent(existingLines: eventLines, nextLine: line) {
                if let chunk = try parseSSEEvent(provider: provider, lines: eventLines) {
                    accumulated += chunk
                }
                eventLines.removeAll(keepingCapacity: true)
            }
            eventLines.append(line)
        }

        if let chunk = try parseSSEEvent(provider: provider, lines: eventLines) {
            accumulated += chunk
        }

        try validateStreamingHTTPResponse(response, body: rawResponseLines.joined(separator: "\n"))

        guard !accumulated.isEmpty else {
            throw LLMError.emptyResponse
        }

        return accumulated
    }

    /// Races `session.bytes(for:)` — which blocks until response headers
    /// arrive — against a `Task.sleep` of `timeout`. On sleep-wins, the
    /// bytes task is cancelled (propagates through URLSession, aborts the
    /// HTTP request) and a timed-out `URLError` is thrown, shaped the
    /// same way a real URLSession timeout would be so the existing error
    /// mapping in `performLLMRequest` handles it uniformly.
    private func firstByteOrTimeout(
        request: URLRequest,
        timeout: Duration
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        enum Outcome {
            case bytes(URLSession.AsyncBytes, URLResponse)
            case timedOut
        }

        let session = self.session
        let outcome: Outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                return .bytes(bytes, response)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw LLMError.emptyResponse
            }
            group.cancelAll()
            return first
        }

        switch outcome {
        case .bytes(let bytes, let response):
            return (bytes, response)
        case .timedOut:
            throw URLError(.timedOut)
        }
    }

    private func shouldFlushSSEEvent(existingLines: [String], nextLine: String) -> Bool {
        guard existingLines.contains(where: { $0.hasPrefix("data:") }) else {
            return false
        }

        if nextLine.hasPrefix("data:") {
            return true
        }

        if nextLine.hasPrefix("event:") {
            return true
        }

        return false
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: String(body.prefix(200)))
        }
    }

    private func validateStreamingHTTPResponse(_ response: URLResponse, body: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }

        guard !(200...299).contains(httpResponse.statusCode) else {
            return
        }
        throw LLMError.httpError(statusCode: httpResponse.statusCode, body: String(body.prefix(200)))
    }

    private func parseSSEEvent(provider: LLMProvider, lines: [String]) throws -> String? {
        guard !lines.isEmpty else { return nil }

        let dataLines = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        guard !dataLines.isEmpty else { return nil }

        let payload = dataLines.joined(separator: "\n")
        if payload == "[DONE]" {
            return nil
        }

        guard let data = payload.data(using: .utf8) else {
            throw LLMError.decodingError(
                NSError(
                    domain: "LLMClient",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 in streaming payload"]
                )
            )
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMError.decodingError(error)
        }

        guard let root = json as? [String: Any] else {
            throw LLMError.decodingError(
                NSError(
                    domain: "LLMClient",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Streaming response is not a JSON object"]
                )
            )
        }

        switch provider {
        case .openai, .ollama:
            return parseOpenAIStreamChunk(root)
        case .anthropic:
            return parseAnthropicStreamChunk(root)
        case .gemini:
            return parseGeminiStreamChunk(root)
        case .appleIntelligence:
            return nil
        }
    }

    private func parseOpenAIStreamChunk(_ root: [String: Any]) -> String? {
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else {
            return nil
        }

        if let content = delta["content"] as? String {
            return content
        }

        if let contentParts = delta["content"] as? [[String: Any]] {
            let joined = contentParts.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func parseAnthropicStreamChunk(_ root: [String: Any]) -> String? {
        if let delta = root["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        if let contentBlock = root["content_block"] as? [String: Any],
           let text = contentBlock["text"] as? String {
            return text
        }

        return nil
    }

    private func parseGeminiStreamChunk(_ root: [String: Any]) -> String? {
        let text = (root["candidates"] as? [[String: Any]])?
            .first?["content"]
            .flatMap { $0 as? [String: Any] }?["parts"]
            .flatMap { $0 as? [[String: Any]] }?
            .compactMap { $0["text"] as? String }
            .joined()

        guard let text, !text.isEmpty else {
            return nil
        }
        return text
    }

    private func mapError(_ error: Error) -> LLMError {
        if let llmError = error as? LLMError {
            return llmError
        }
        return LLMError.networkError(error)
    }

    private func parseResponse(provider: LLMProvider, data: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LLMError.decodingError(error)
        }

        guard let root = json as? [String: Any] else {
            throw LLMError.decodingError(
                NSError(domain: "LLMClient", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Response is not a JSON object"])
            )
        }

        let text: String?
        switch provider {
        case .appleIntelligence:
            // Apple Intelligence never reaches parse — responses are in-memory
            // strings from FoundationModels. If we're here it's a programmer error.
            throw LLMError.appleIntelligenceUnavailable
        case .openai, .ollama:
            text = (root["choices"] as? [[String: Any]])?
                .first?["message"]
                .flatMap { $0 as? [String: Any] }?["content"] as? String

        case .anthropic:
            text = (root["content"] as? [[String: Any]])?
                .first?["text"] as? String

        case .gemini:
            text = (root["candidates"] as? [[String: Any]])?
                .first?["content"]
                .flatMap { $0 as? [String: Any] }?["parts"]
                .flatMap { $0 as? [[String: Any]] }?
                .first?["text"] as? String
        }

        guard let result = text, !result.isEmpty else {
            throw LLMError.emptyResponse
        }

        return result
    }

    func transform(transcript: String) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return transcript
        }

        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            let p = c.provider
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p),
                systemPrompt: c.transformPrompt
            )
        }

        // On-device Apple Intelligence short-circuits the HTTP path entirely.
        if config.provider == .appleIntelligence {
            do {
                return try await appleClient.transform(
                    transcript: transcript,
                    instruction: config.systemPrompt
                )
            } catch {
                let mapped = mapError(error)
                logLLMError(mapped, provider: config.provider, request: nil, streaming: false, op: "transform")
                throw mapped
            }
        }

        guard config.provider == .ollama || !config.apiKey.isEmpty else {
            Task { await ErrorLog.shared.error(component: "LLMClient", message: "Missing API key", context: ["provider": config.provider.rawValue, "op": "transform"]) }
            throw LLMError.noAPIKey
        }

        let systemPrompt = config.systemPrompt

        var request = try buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: transcript,
            stream: shouldStream(provider: config.provider)
        )
        // See the matching comment in `articulate(...)`: per-request override
        // keeps between-byte gaps from tripping the tight session default.
        // Reachability is enforced separately via the first-byte watchdog
        // inside `streamResponse`.
        request.timeoutInterval = 60

        let result = try await performLLMRequest(provider: config.provider, request: request)

        let inputLength = Double(transcript.count)
        let minRatio = inputLength < 50 ? 0.15 : 0.3
        if Double(result.count) < inputLength * minRatio || Double(result.count) > inputLength * 3.0 {
            Task { await ErrorLog.shared.warn(component: "LLMClient", message: "Suspicious response length — rejected", context: [
                "provider": config.provider.rawValue,
                "op": "transform",
                "inputLen": String(Int(inputLength)),
                "outputLen": String(result.count),
            ]) }
            throw LLMError.suspiciousResponse
        }

        return result
    }

    // MARK: - Test Helpers

    func testParseResponse(provider: LLMProvider, data: Data) throws -> String {
        try parseResponse(provider: provider, data: data)
    }

    func testBuildRequest(
        provider: LLMProvider, baseURL: String, apiKey: String,
        model: String, systemPrompt: String, userPrompt: String,
        stream: Bool = false
    ) throws -> URLRequest {
        try buildRequest(provider: provider, baseURL: baseURL, apiKey: apiKey,
                         model: model, systemPrompt: systemPrompt, userPrompt: userPrompt,
                         stream: stream)
    }

    func testParseSSEEvent(provider: LLMProvider, lines: [String]) throws -> String? {
        try parseSSEEvent(provider: provider, lines: lines)
    }

    func testPerformLLMRequest(provider: LLMProvider, request: URLRequest) async throws -> String {
        try await performLLMRequest(provider: provider, request: request)
    }

    // MARK: - Health Check

    func healthCheck() async -> Bool {
        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            let p = c.provider
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p)
            )
        }

        if config.provider == .appleIntelligence {
            return AppleIntelligenceClient.isAvailable
        }

        if config.provider != .ollama {
            guard !config.apiKey.isEmpty else { return false }
        }

        do {
            var request = try buildRequest(
                provider: config.provider,
                baseURL: config.baseURL,
                apiKey: config.apiKey,
                model: config.model,
                systemPrompt: "Respond with the word OK.",
                userPrompt: "OK",
                stream: shouldStream(provider: config.provider)
            )
            request.timeoutInterval = 15

            let text = try await performLLMRequest(provider: config.provider, request: request)
            return !text.isEmpty
        } catch {
            return false
        }
    }
}
