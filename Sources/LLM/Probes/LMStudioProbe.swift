import Foundation

/// LM Studio `/v1/models` probe.
///
/// **Endpoint:** `GET <baseURL>/models`. LM Studio exposes an
/// OpenAI-compatible server, so the stored `baseURL` already ends in
/// `/v1` (default `http://localhost:1234/v1`) and the models endpoint
/// lives at `<baseURL>/models` — i.e. `.../v1/models`. Unlike the Ollama
/// probe we do NOT strip `/v1`; LM Studio has no `/api/tags` equivalent.
/// **Auth:** none. LM Studio is a local server.
/// **Response shape (OpenAI-compatible):**
///   `{ "object": "list", "data": [{ "id": "<model>", "object": "model", ... }, ...] }`.
///
/// LM Studio lists models that are downloaded; `id` is the loadable model
/// identifier. No filtering — show everything LM Studio reports.
struct LMStudioProbe: AIProviderProbe {
    let provider: LLMProvider = .lmStudio

    init() {}

    func probe(
        baseURL: String,
        apiKey _: String,
        session: URLSession
    ) async -> ProbeResult {
        let host = Self.trimmedBaseURL(baseURL)
        guard let url = URL(string: "\(host)/models") else {
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
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .authFailure
                }
                return .unreachable
            }
            return .success(Self.parse(data: data))
        } catch {
            return .networkError(String(describing: error))
        }
    }

    /// Parse the OpenAI-shaped `{ data: [{ id }] }` payload into
    /// `DiscoveredModel`s, sorted by id.
    static func parse(data: Data) -> [DiscoveredModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else {
            return []
        }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return DiscoveredModel(id: id)
        }
        .sorted { lhs, rhs in lhs.id < rhs.id }
    }

    /// Strip trailing slashes so `\(host)/models` doesn't produce a
    /// double slash. Unlike Ollama, the `/v1` suffix is kept — LM Studio's
    /// models endpoint lives under `/v1`.
    static func trimmedBaseURL(_ baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
