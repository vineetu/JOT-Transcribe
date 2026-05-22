import Foundation

/// Anthropic `/v1/models` probe.
///
/// **Endpoint:** `GET <baseURL>/models` (the configured `baseURL`
/// already ends in `/v1`).
/// **Auth:** `x-api-key: <apiKey>` + `anthropic-version: 2023-06-01`.
/// **Response shape:**
///   `{ data: [{ id, type, display_name, created_at }, ...], has_more, first_id, last_id }`.
///
/// Anthropic's catalog is small (haiku/sonnet/opus per generation),
/// every entry is chat-capable, no thinking-only models in the public
/// listing. Filtering is trivial — keep everything that has a `claude-`
/// prefix.
struct AnthropicProbe: AIProviderProbe {
    let provider: LLMProvider = .anthropic
    let classifier: TierClassifier

    init() {
        // claude-haiku-4-5 / claude-sonnet-4-5-20251001 / claude-opus-3-5.
        // Captures (major, minor) from the version pair. Snapshots
        // append `-YYYYMMDD` after the version pair and are ignored
        // by this regex.
        let regex = try! NSRegularExpression(
            pattern: "^claude-\\w+-(\\d+)-(\\d+)"
        )
        self.classifier = TierClassifier(
            provider: .anthropic,
            latestGenRegex: regex,
            tierFor: { id in
                if id.contains("haiku") { return .small }
                if id.contains("sonnet") { return .medium }
                if id.contains("opus") { return .large }
                return nil
            },
            isThinking: { _ in
                // Anthropic doesn't ship `thinking` as a separate
                // model id today — extended thinking is a per-request
                // parameter on the same id. Nothing to exclude here.
                false
            }
        )
    }

    func probe(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async -> ProbeResult {
        guard let url = URL(string: "\(baseURL)/models") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authFailure
            }
            guard (200...299).contains(http.statusCode) else {
                return .unreachable
            }
            return .success(Self.parse(data: data))
        } catch {
            return .networkError(String(describing: error))
        }
    }

    static func parse(data: Data) -> [DiscoveredModel] {
        let probe = AnthropicProbe()
        let classifier = probe.classifier
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else {
            return []
        }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let id = entry["id"] as? String else { return nil }
            // All public Anthropic models are chat-capable.
            guard id.lowercased().hasPrefix("claude-") else { return nil }
            let displayName = entry["display_name"] as? String
            return DiscoveredModel(
                id: id,
                displayName: displayName,
                isThinking: classifier.isThinking(id),
                tier: classifier.tierFor(id)
            )
        }
        .sorted { lhs, rhs in lhs.id < rhs.id }
    }
}
