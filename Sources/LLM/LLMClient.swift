import Foundation

actor LLMClient {
    private let session = URLSession.shared
    private let appleClient = AppleIntelligenceClient()

    /// Articulate a selection according to the user's spoken instruction.
    /// (Formerly `rewrite(…)` — renamed with the v1.5 "Articulate (Custom)"
    /// relabel. Behaviorally identical to v1.4 `rewrite`.)
    func articulate(selectedText: String, instruction: String) async throws -> String {
        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            return (
                provider: c.provider,
                apiKey: c.apiKey,
                baseURL: c.effectiveBaseURL,
                model: c.effectiveModel,
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
            return try await appleClient.articulate(
                selectedText: selectedText,
                instruction: instruction,
                branchPrompt: systemPrompt
            )
        }

        if config.provider != .ollama {
            guard !config.apiKey.isEmpty else { throw LLMError.noAPIKey }
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

        let request = try buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.1
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            let truncatedBody = String(body.prefix(200))
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: truncatedBody)
        }

        return try parseResponse(provider: config.provider, data: data)
    }

    private func buildRequest(
        provider: LLMProvider,
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.3
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
                temperature: temperature
            )
        case .anthropic:
            return try buildAnthropicRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: temperature
            )
        case .gemini, .vertexGemini:
            // Vertex Gemini accepts the same contents/parts body shape and
            // the same `?key=apiKey` auth pattern as Google AI Studio. Route
            // to the same builder.
            return try buildGeminiRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: temperature
            )
        }
    }

    private func buildOpenAIRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        temperature: Double
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildAnthropicRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        temperature: Double
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/messages") else {
            throw LLMError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt],
            ],
            "temperature": temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildGeminiRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String,
        temperature: Double
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/models/\(model):generateContent?key=\(apiKey)") else {
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

        case .gemini, .vertexGemini:
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
        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            return (
                provider: c.provider,
                apiKey: c.apiKey,
                baseURL: c.effectiveBaseURL,
                model: c.effectiveModel,
                systemPrompt: c.transformPrompt
            )
        }

        // On-device Apple Intelligence short-circuits the HTTP path entirely.
        if config.provider == .appleIntelligence {
            return try await appleClient.transform(
                transcript: transcript,
                instruction: config.systemPrompt
            )
        }

        guard config.provider == .ollama || !config.apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        let systemPrompt = config.systemPrompt

        var request = try buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: transcript
        )
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(URLError(.badServerResponse))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            let truncatedBody = String(body.prefix(200))
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: truncatedBody)
        }

        let result = try parseResponse(provider: config.provider, data: data)

        let inputLength = Double(transcript.count)
        let minRatio = inputLength < 50 ? 0.15 : 0.3
        if Double(result.count) < inputLength * minRatio || Double(result.count) > inputLength * 3.0 {
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
        model: String, systemPrompt: String, userPrompt: String
    ) throws -> URLRequest {
        try buildRequest(provider: provider, baseURL: baseURL, apiKey: apiKey,
                         model: model, systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    // MARK: - Health Check

    func healthCheck() async -> Bool {
        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            return (
                provider: c.provider,
                apiKey: c.apiKey,
                baseURL: c.effectiveBaseURL,
                model: c.effectiveModel
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
                userPrompt: "OK"
            )
            request.timeoutInterval = 15

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return false
            }

            let text = try parseResponse(provider: config.provider, data: data)
            return !text.isEmpty
        } catch {
            return false
        }
    }
}
