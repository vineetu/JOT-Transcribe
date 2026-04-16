import Foundation

actor LLMClient {
    private let session = URLSession.shared

    func rewrite(selectedText: String, instruction: String) async throws -> String {
        let config = await MainActor.run {
            let c = LLMConfiguration.shared
            return (
                provider: c.provider,
                apiKey: c.apiKey,
                baseURL: c.effectiveBaseURL,
                model: c.effectiveModel
            )
        }

        guard !config.apiKey.isEmpty else { throw LLMError.noAPIKey }

        let systemPrompt = """
            You are a text rewriting assistant. You receive selected text and a voice instruction. \
            Rewrite the text according to the instruction. Output ONLY the rewritten text — no explanations, \
            no quotes, no markdown formatting, no preamble.
            """

        let userPrompt = """
            Selected text:
            ---
            \(selectedText)
            ---

            Instruction: \(instruction)
            """

        let request = try buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
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
        userPrompt: String
    ) throws -> URLRequest {
        switch provider {
        case .openai:
            return try buildOpenAIRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt
            )
        case .anthropic:
            return try buildAnthropicRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt
            )
        case .gemini:
            return try buildGeminiRequest(
                baseURL: baseURL, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt
            )
        }
    }

    private func buildOpenAIRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String
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
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildAnthropicRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String
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
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func buildGeminiRequest(
        baseURL: String, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String
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
            "generationConfig": ["temperature": 0.3],
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
        case .openai:
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
}
