import Foundation

/// LM Studio model probe.
///
/// Prefers LM Studio's **native** `GET <host>/api/v0/models`, which reports each
/// model's `type` (`llm` / `vlm` / `embeddings`). We use that to FILTER OUT
/// embedding models — they can't run chat / cleanup / rewrite and must not show
/// up in the model picker. Falls back to the OpenAI-compatible `/v1/models`
/// (id-only; embeddings dropped by an id heuristic) if the native endpoint is
/// unavailable. **Auth:** none (local server).
struct LMStudioProbe: AIProviderProbe {
    let provider: LLMProvider = .lmStudio

    init() {}

    func probe(
        baseURL: String,
        apiKey _: String,
        session: URLSession
    ) async -> ProbeResult {
        // 1. Native endpoint — has `type`, so embedding filtering is reliable.
        if let url = Self.nativeModelsURL(baseURL) {
            switch await Self.get(url, session: session) {
            case .data(let data): return .success(Self.parseNative(data: data))
            case .auth:           return .authFailure
            case .failed:         break   // fall through to the OpenAI endpoint
            }
        }
        // 2. Fallback — OpenAI `/v1/models` (id-only; heuristic embed filter).
        guard let url = URL(string: "\(Self.trimmedBaseURL(baseURL))/models") else {
            return .unreachable
        }
        switch await Self.get(url, session: session) {
        case .data(let data): return .success(Self.parse(data: data))
        case .auth:           return .authFailure
        case .failed(let detail):
            if let detail { return .networkError(detail) }
            return .unreachable
        }
    }

    private enum Fetch { case data(Data); case auth; case failed(String?) }

    private static func get(_ url: URL, session: URLSession) async -> Fetch {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(nil) }
            if http.statusCode == 401 || http.statusCode == 403 { return .auth }
            guard (200...299).contains(http.statusCode) else { return .failed(nil) }
            return .data(data)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Native `/api/v0/models`: `{ data: [{ id, type, ... }] }`. Keep everything
    /// that is NOT an embedding model (by `type`, with an id backstop).
    static func parseNative(data: Data) -> [DiscoveredModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let type = (entry["type"] as? String)?.lowercased() ?? ""
            if type == "embeddings" || isEmbeddingID(id) { return nil }
            return DiscoveredModel(id: id)
        }
        .sorted { $0.id < $1.id }
    }

    /// OpenAI `/v1/models`: `{ data: [{ id }] }` (no `type`). Drop embeddings by
    /// id heuristic — the best we can do without the native `type` field.
    static func parse(data: Data) -> [DiscoveredModel] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = root["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry -> DiscoveredModel? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            if isEmbeddingID(id) { return nil }
            return DiscoveredModel(id: id)
        }
        .sorted { $0.id < $1.id }
    }

    /// Heuristic embedding detector for the id-only fallback (and a backstop on
    /// the native path). Catches the common `text-embedding-*` / `*-embed-*`
    /// families; not exhaustive (bge / e5 / gte don't say "embed"), which is why
    /// the native `type` field is the primary signal.
    static func isEmbeddingID(_ id: String) -> Bool {
        id.lowercased().contains("embed")
    }

    /// `<scheme>://<host>/api/v0/models`, derived from the stored base URL by
    /// dropping a trailing `/v1` (the OpenAI suffix) — LM Studio's native REST
    /// API lives at the server root, not under `/v1`.
    static func nativeModelsURL(_ baseURL: String) -> URL? {
        var s = trimmedBaseURL(baseURL)
        if s.hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: "\(s)/api/v0/models")
    }

    /// Strip trailing slashes so URL composition doesn't double up.
    static func trimmedBaseURL(_ baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
