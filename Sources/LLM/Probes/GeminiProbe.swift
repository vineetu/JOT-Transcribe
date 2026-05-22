import Foundation

/// Gemini `/v1beta/models` probe.
///
/// **Endpoint:** `GET <baseURL>/models?key=<apiKey>` (Gemini's API
/// auths via query param, not header; `baseURL` already includes
/// `/v1beta`).
/// **Response shape:**
///   `{ models: [{ name, baseModelId, version, displayName, description,
///                  inputTokenLimit, outputTokenLimit,
///                  supportedGenerationMethods: [...], temperature, topP, topK }, ...] }`.
///
/// Filtering:
///   - Keep only entries whose `supportedGenerationMethods` contains
///     `generateContent` (drops embedding-only and TTS-only models).
///   - Strip the leading `models/` prefix from `name` so the id
///     written to AppStorage matches what `LLMClient.buildGeminiRequest`
///     consumes (it concatenates `models/<id>` itself).
///   - Drop `thinking` ids per the plan; reasoning models don't fit
///     the transform/rewrite latency budget.
struct GeminiProbe: AIProviderProbe {
    let provider: LLMProvider = .gemini
    let classifier: TierClassifier

    init() {
        // gemini-2.5-flash → ("2", "5"); gemini-3.1-flash-lite → ("3", "1").
        // Captures the major.minor version after the family prefix.
        let regex = try! NSRegularExpression(
            pattern: "^gemini-(\\d+)\\.(\\d+)-"
        )
        self.classifier = TierClassifier(
            provider: .gemini,
            latestGenRegex: regex,
            tierFor: { id in
                // Order matters: `-flash-lite` contains `-flash`, so
                // check the more specific suffix first.
                if id.contains("-flash-lite") { return .small }
                if id.contains("-flash") { return .medium }
                if id.contains("-pro") { return .large }
                return nil
            },
            isThinking: { id in
                id.contains("thinking")
            }
        )
    }

    func probe(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async -> ProbeResult {
        guard let url = URL(string: "\(baseURL)/models?key=\(apiKey)") else {
            return .unreachable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
        let probe = GeminiProbe()
        let classifier = probe.classifier
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["models"] as? [[String: Any]]
        else {
            return []
        }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let rawName = entry["name"] as? String else { return nil }
            // Gemini returns `models/gemini-1.5-flash` — drop the
            // prefix so the id round-trips through LLMClient's request
            // builder cleanly.
            let id: String
            if rawName.hasPrefix("models/") {
                id = String(rawName.dropFirst("models/".count))
            } else {
                id = rawName
            }
            guard id.lowercased().hasPrefix("gemini-") else { return nil }
            // Only chat-capable entries (must support generateContent).
            let methods = entry["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { return nil }
            let displayName = entry["displayName"] as? String
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
