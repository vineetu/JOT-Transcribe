import Foundation

/// Ollama `/api/tags` probe.
///
/// **Endpoint:** `GET <host>/api/tags`. The stored `baseURL` defaults
/// to `http://localhost:11434/v1` (LLMClient uses the OpenAI-compat
/// shim), but `/api/tags` lives at the root, not under `/v1`. We
/// strip a trailing `/v1` (with or without trailing slash) before
/// appending `/api/tags`.
/// **Auth:** none. Ollama is a local daemon.
/// **Response shape:**
///   `{ models: [{ name, model, modified_at, size, digest, details: { format, family, parameter_size, ... } }, ...] }`.
///
/// All locally-pulled models are chat-capable as far as Ollama is
/// concerned (embedding-only models are tagged as such in `details`
/// but still respond to chat completions). No filtering — show
/// everything the user has pulled.
struct OllamaProbe: AIProviderProbe {
    let provider: LLMProvider = .ollama

    init() {}

    func probe(
        baseURL: String,
        apiKey _: String,
        session: URLSession
    ) async -> ProbeResult {
        let host = Self.stripOpenAICompatSuffix(from: baseURL)
        guard let url = URL(string: "\(host)/api/tags") else {
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
                return .unreachable
            }
            return .success(Self.parse(data: data))
        } catch {
            return .networkError(String(describing: error))
        }
    }

    static func parse(data: Data) -> [DiscoveredModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["models"] as? [[String: Any]]
        else {
            return []
        }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let name = entry["name"] as? String else { return nil }
            return DiscoveredModel(id: name)
        }
        .sorted { lhs, rhs in lhs.id < rhs.id }
    }

    /// `http://localhost:11434/v1` → `http://localhost:11434`. Leaves
    /// a host without `/v1` untouched so a user pointing Jot at a
    /// custom Ollama proxy that doesn't expose the OpenAI shim still
    /// hits `/api/tags` at the right place.
    static func stripOpenAICompatSuffix(from baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") {
            s.removeLast()
        }
        if s.hasSuffix("/v1") {
            s.removeLast("/v1".count)
        }
        return s
    }
}
