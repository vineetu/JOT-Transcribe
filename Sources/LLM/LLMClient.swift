import Foundation

actor LLMClient {
    private let session: URLSession
    private let appleClient: any AppleIntelligenceClienting
    private let logSink: any LogSink
    /// Phase 3 #29: per-graph `LLMConfiguration` replaces
    /// `LLMConfiguration.shared` reads. Captured at init from the
    /// composition root.
    private let llmConfiguration: LLMConfiguration

    init(
        session: URLSession,
        appleClient: (any AppleIntelligenceClienting)? = nil,
        logSink: any LogSink = ErrorLog.shared,
        llmConfiguration: LLMConfiguration
    ) {
        self.session = session
        self.appleClient = appleClient ?? AppleIntelligenceClient()
        self.logSink = logSink
        self.llmConfiguration = llmConfiguration
    }

    /// Phase 0.5 dropped this from LLMClient's init path — the live
    /// session now comes from `AppServices.urlSession`, which is built
    /// from `SystemServices.urlSessionConfiguration` (default URLSession
    /// posture). The 3 s reachability fast-fail that this factory used to
    /// install on LLMClient's session was defensive — every shipping
    /// LLMClient call path uses either a per-request `timeoutInterval`
    /// override or the explicit 3 s `firstByteOrTimeout` watchdog inside
    /// `streamResponse`, so the session default was never the operative
    /// timeout. Kept here so a future test can construct a tighter-timeout
    /// session if needed.
    static func makeSessionConfiguration(
        requestTimeout: TimeInterval = 3,
        resourceTimeout: TimeInterval = 120
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }

    /// Rewrite a selection. Used by both Rewrite with Voice (pass the
    /// spoken instruction) and fixed Rewrite (pass `nil` — the system
    /// prompt's no-instruction fallback governs behavior).
    ///
    /// When `systemPromptOverride` is non-nil (Prompt Picker path), the
    /// override REPLACES the classifier-composed system prompt for this
    /// single call. Shared invariants and branch routing are skipped —
    /// the picked prompt is hand-written to do its job in a single
    /// block. `instruction` is still respected; pass `nil` for ⏎-apply,
    /// pass a voice tweak for ⌘⏎-apply.
    func rewrite(selectedText: String, instruction: String?, systemPromptOverride: String? = nil) async throws -> String {
        let config = await MainActor.run { [llmConfiguration] in
            let c = llmConfiguration
            let p = c.provider
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p),
                sharedInvariants: c.rewritePrompt
            )
        }

        // System-prompt composition — three paths:
        // 1. Override present (picker row picked) → use the override
        //    verbatim. Picked prompts are self-contained; no classifier
        //    branch, no shared invariants.
        // 2. No instruction (⌥/ tap, default Rewrite) → use the user-
        //    editable Rewrite prompt (`config.sharedInvariants`) verbatim.
        //    No classifier branch is appended: the prompt already says
        //    everything the `.voicePreserving` branch was saying.
        // 3. With instruction (⌥. Rewrite with Voice, picker ⌘⏎ voice-
        //    augment) → use the internal with-voice prompt + the
        //    classifier-routed branch tendency. The user's voice
        //    instruction is the primary signal; the prompt is thin
        //    scaffolding.
        let systemPrompt: String
        if let override = systemPromptOverride, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt = override
        } else if instruction == nil {
            // No-instruction path. The user-editable Rewrite prompt is
            // the entire system prompt; the model has everything it
            // needs to articulate the dictation.
            systemPrompt = config.sharedInvariants
        } else {
            // With-instruction path. Route the spoken instruction to a
            // branch-specific tendency block and append it to the
            // (non-user-editable) with-voice prompt.
            let branch: RewriteBranch = instruction.map(RewriteInstructionClassifier.classify) ?? .voicePreserving
            systemPrompt = """
                \(RewritePrompt.withVoiceInternal)

                \(RewriteBranchPrompt.prompt(for: branch))
                """
        }

        // On-device Apple Intelligence short-circuits the HTTP path entirely.
        if config.provider == .appleIntelligence {
            do {
                return try await appleClient.rewrite(
                    selectedText: selectedText,
                    instruction: instruction,
                    branchPrompt: systemPrompt
                )
            } catch {
                let mapped = mapError(error)
                logLLMError(mapped, provider: config.provider, request: nil, streaming: false, op: "rewrite")
                throw mapped
            }
        }

        if config.provider.requiresUserAPIKey {
            guard !config.apiKey.isEmpty else {
                Task { await self.logSink.error(component: "LLMClient", message: "Missing API key", context: ["provider": config.provider.rawValue, "op": "rewrite"]) }
                throw LLMError.noAPIKey
            }
        }

        // XML-tag delimiters (OWASP 2025 prompt-injection hardening).
        // Voice path embeds the spoken instruction in `<instruction>`
        // so the LLM treats it as the primary directive. Fixed path
        // omits the block entirely and relies on the system prompt's
        // no-instruction fallback.
        let userPrompt: String
        if let instruction, !instruction.isEmpty {
            userPrompt = """
                <instruction>
                \(instruction)
                </instruction>

                <selection>
                \(selectedText)
                </selection>

                Follow the <instruction> above. Rewrite the <selection> and return only the rewritten text.
                """
        } else {
            userPrompt = """
                <selection>
                \(selectedText)
                </selection>

                Rewrite the <selection> and return only the rewritten text.
                """
        }

        var request = try await buildRequest(
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

    /// Generic system+user completion. No XML wrapping, no rewrite-specific
    /// shaping — used by authoring surfaces (PromptEditorSheet's
    /// "Generate sample" path) that need a one-shot completion against
    /// the user's configured provider.
    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        let config = await MainActor.run { [llmConfiguration] in
            let c = llmConfiguration
            let p = c.provider
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p)
            )
        }

        if config.provider == .appleIntelligence {
            return try await appleClient.transform(
                transcript: userPrompt,
                instruction: systemPrompt
            )
        }

        if config.provider.requiresUserAPIKey, config.apiKey.isEmpty {
            throw LLMError.noAPIKey
        }

        var request = try await buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: 0.4,
            stream: false
        )
        request.timeoutInterval = 60
        return try await performLLMRequest(provider: config.provider, request: request, stream: false)
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
    ) async throws -> URLRequest {
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
        #if JOT_FLAVOR_1
        case .flavor1:
            return try await Flavor1Client.buildRequest(
                baseURL: baseURL, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                temperature: temperature, stream: stream
            )
        #endif
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
        ]
        // GPT-5 (the reasoning model — not "gpt-5-mini" or other
        // variants) rejects any temperature value other than the
        // default. Empirically: passing `temperature: 0.1` returns a
        // 400 with `"Unsupported value: 'temperature' does not support
        // 0.1 with this model. Only the default (1) value is
        // supported."` (verified 2026-05-18 against the PFB gateway's
        // `gpt-5` route, which is OpenAI-compatible). Scope intentionally
        // narrow per design discussion: just `gpt-5`, not the broader
        // o1/o3/o4 reasoning-model family — if those land later, extend
        // explicitly with their own model-ID match here.
        if model != "gpt-5" {
            body["temperature"] = temperature
        }
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
            // Long-form rewrites (a paragraphs-long dictation, a whole
            // chat transcript) routinely exceed the 4096-token cap
            // that shipped with v1.5; the response truncates mid-sentence
            // and the paste-back surfaces a half-rewritten selection.
            // Haiku 4.5 supports 64K output tokens — 16K is well within
            // budget and covers every dictation-length we've observed
            // in practice. Anthropic doesn't bill for unused output, so
            // setting this high has no cost when the rewrite is short.
            "max_tokens": 16384,
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
        #if JOT_FLAVOR_1
        case .flavor1:
            return true
        #endif
        }
    }

    private func performLLMRequest(provider: LLMProvider, request: URLRequest, stream: Bool? = nil) async throws -> String {
        let useStreaming = stream ?? shouldStream(provider: provider)
        do {
            if useStreaming {
                return try await streamResponse(provider: provider, request: request)
            }

            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response, data: data)
            return try parseResponse(provider: provider, data: data)
        } catch {
            let mapped = mapError(error)
            logLLMError(mapped, provider: provider, request: request, streaming: useStreaming)
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
        Task { await self.logSink.error(component: "LLMClient", message: message, context: context) }
    }

    private func streamResponse(provider: LLMProvider, request: URLRequest) async throws -> String {
        // First-byte watchdog: reachability fail-fast. If the server
        // doesn't send its response headers within the watchdog window
        // of us firing the request, we assume the host is unreachable/dead
        // and surface a network timeout error right away — without waiting
        // out the generous per-request `timeoutInterval` (which exists only
        // to protect against between-byte gaps once streaming has started).
        //
        // `URLSession.bytes(for:)` blocks until response headers arrive,
        // then returns a byte stream we can iterate. Racing that call
        // against a `Task.sleep` in a TaskGroup gives us the split
        // "reachability / streaming" behavior URLSession doesn't expose
        // natively. Losing tasks are cancelled — for the bytes task,
        // cancellation propagates through URLSession and aborts the
        // underlying HTTP request cleanly.
        //
        // Ollama is exempt from the first-byte watchdog entirely. Even
        // though the daemon is local, `:cloud`-suffixed models proxy to
        // Ollama's hosted infra and routinely exhibit 2–8s streaming
        // TTFB (DeepSeek 671b measured at 7.6s; cold-start for larger
        // models easily exceeds 15s). The watchdog's "fast unreachability
        // detection" assumption holds for always-warm cloud endpoints
        // but breaks for local-proxy-but-cloud-hosted models, which
        // caused Test Connection failures in Settings → AI. A dead
        // local Ollama daemon still fails fast — the OS rejects the
        // TCP connection immediately, and the outer per-request
        // `timeoutInterval` (15s for healthCheck, 60s for rewrite/
        // transform) still bounds the wait. Reachability semantics are
        // preserved for cloud providers (OpenAI/Anthropic/Gemini),
        // which stay at 3s.
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        if !provider.usesFirstByteWatchdog {
            (bytes, response) = try await session.bytes(for: request)
        } else {
            (bytes, response) = try await firstByteOrTimeout(
                request: request,
                timeout: .seconds(3)
            )
        }

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
        #if JOT_FLAVOR_1
        case .flavor1:
            return Flavor1Client.parseStreamChunk(root)
        #endif
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
        #if JOT_FLAVOR_1
        case .flavor1:
            text = Flavor1Client.parseResponse(root)
        #endif
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

        let config = await MainActor.run { [llmConfiguration] in
            let c = llmConfiguration
            let p = c.provider
            // Homophone rule appends only for cloud providers. Apple
            // Intelligence's on-device model regresses with it (reverts
            // correct fixes, over-edits). See TransformPrompt.homophoneRule.
            let systemPrompt = p == .appleIntelligence
                ? c.transformPrompt
                : c.transformPrompt + "\n\n" + TransformPrompt.homophoneRule
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p),
                systemPrompt: systemPrompt
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

        guard !config.provider.requiresUserAPIKey || !config.apiKey.isEmpty else {
            Task { await self.logSink.error(component: "LLMClient", message: "Missing API key", context: ["provider": config.provider.rawValue, "op": "transform"]) }
            throw LLMError.noAPIKey
        }

        let systemPrompt = config.systemPrompt

        var request = try await buildRequest(
            provider: config.provider,
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model,
            systemPrompt: systemPrompt,
            userPrompt: transcript,
            stream: shouldStream(provider: config.provider)
        )
        // See the matching comment in `rewrite(...)`: per-request override
        // keeps between-byte gaps from tripping the tight session default.
        // Reachability is enforced separately via the first-byte watchdog
        // inside `streamResponse`.
        request.timeoutInterval = 60

        let result = try await performLLMRequest(provider: config.provider, request: request)

        let inputLength = Double(transcript.count)
        let minRatio = inputLength < 50 ? 0.15 : 0.3
        if Double(result.count) < inputLength * minRatio || Double(result.count) > inputLength * 3.0 {
            Task { await self.logSink.warn(component: "LLMClient", message: "Suspicious response length — rejected", context: [
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
    ) async throws -> URLRequest {
        try await buildRequest(provider: provider, baseURL: baseURL, apiKey: apiKey,
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
        let config = await MainActor.run { [llmConfiguration] in
            let c = llmConfiguration
            let p = c.provider
            return (
                provider: p,
                apiKey: c.apiKey(for: p),
                baseURL: c.effectiveBaseURL(for: p),
                model: c.effectiveModel(for: p)
            )
        }

        if config.provider == .appleIntelligence {
            return appleClient.isAvailable
        }

        #if JOT_FLAVOR_1
        if config.provider == .flavor1 {
            // JWT-aware reachability probe lives in Flavor1Client — it
            // checks sign-in state + endpoint reachability without
            // touching the generic API-key path.
            return await Flavor1Client.healthCheck(
                baseURL: config.baseURL,
                model: config.model,
                urlSession: session
            )
        }
        #endif

        if config.provider.requiresUserAPIKey {
            guard !config.apiKey.isEmpty else { return false }
        }

        do {
            var request = try await buildRequest(
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
