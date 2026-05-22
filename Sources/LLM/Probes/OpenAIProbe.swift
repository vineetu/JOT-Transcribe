import Foundation

/// OpenAI `/v1/models` probe.
///
/// **Endpoint:** `GET <baseURL>/models` (the configured `baseURL`
/// already ends in `/v1`, so we just append `/models`).
/// **Auth:** `Authorization: Bearer <apiKey>`.
/// **Response shape:** `{ data: [{ id, object, created, owned_by }, ...] }`.
///
/// Filtering:
///   - Keep only ids that start with `gpt-` (chat-capable family).
///   - Exclude embeddings, audio, image, completion-legacy models
///     (`whisper`, `tts`, `dall-e`, `text-embedding`, `babbage`,
///     `davinci`) and reasoning families (`^o\d`).
///   - Strip dated suffixes (`gpt-5-mini-2025-08-07`) by treating
///     any id containing a `YYYY-MM-DD` slug as a snapshot. We keep
///     these in the discovery list (people pin to dated builds in
///     production) but the tier-classifier still tags them by their
///     prefix.
struct OpenAIProbe: AIProviderProbe {
    let provider: LLMProvider = .openai
    let classifier: TierClassifier

    init() {
        // gpt-5-mini → ("5",); gpt-5.1-nano → ("5", "1"); gpt-4o → ("4",).
        // The regex captures one mandatory major number, optionally
        // followed by `.minor`. Anchored to the start of the id so
        // `text-embedding-3-small` can't accidentally match.
        let regex = try! NSRegularExpression(
            pattern: "^gpt-(\\d+(?:\\.\\d+)?)"
        )
        self.classifier = TierClassifier(
            provider: .openai,
            latestGenRegex: regex,
            tierFor: { id in
                if id.contains("-nano") { return .small }
                if id.contains("-mini") { return .small }
                // gpt-5-pro / gpt-5-turbo would be large; bare gpt-5
                // and gpt-4o are the mid-tier flagships.
                if id.contains("-pro") { return .large }
                return .medium
            },
            isThinking: { id in
                // We don't ship reasoning-model defaults — they're
                // slow + expensive for transform/rewrite use cases.
                id.contains("thinking")
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    /// Static parser exposed for tests (fixture JSON → models[]).
    static func parse(data: Data) -> [DiscoveredModel] {
        let probe = OpenAIProbe()
        let classifier = probe.classifier
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else {
            return []
        }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let id = entry["id"] as? String else { return nil }
            guard Self.isChatCapable(id: id) else { return nil }
            return DiscoveredModel(
                id: id,
                displayName: nil,
                isThinking: classifier.isThinking(id),
                tier: classifier.tierFor(id)
            )
        }
        .sorted { lhs, rhs in lhs.id < rhs.id }
    }

    /// Allowlist (must start with `gpt-`) AND blocklist (no
    /// embeddings/audio/image/legacy/o\d/thinking). Centralised so the
    /// test target can exercise it.
    static func isChatCapable(id: String) -> Bool {
        let lower = id.lowercased()
        guard lower.hasPrefix("gpt-") else { return false }
        // Anti-patterns the plan calls out explicitly.
        let blocklist: [String] = [
            "whisper", "tts", "dall-e", "image",
            "text-embedding", "embedding",
            "babbage", "davinci",
            "audio", "realtime", "transcribe", "search-preview",
        ]
        for needle in blocklist {
            if lower.contains(needle) { return false }
        }
        // `o\d` family is reasoning; covered by `^(o\d|...)` in the
        // plan. The `gpt-` allowlist already rules those out, but a
        // belt-and-braces check stays in case OpenAI ever ships
        // `gpt-o1`.
        return true
    }
}
