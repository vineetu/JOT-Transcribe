import Foundation

/// One model entry returned by a provider's `/models` (or equivalent)
/// endpoint, normalized across providers.
///
/// Post-v1.14 simplification: vendor `/v1/models` probing was removed
/// because OpenAI / Anthropic / Gemini all gate that endpoint behind an
/// API key. The cloud picker now reads a hand-curated `ModelCatalog`
/// instead. `DiscoveredModel` and `AIProviderProbe` survive solely for
/// the **local** Ollama probe (`localhost:11434/api/tags`, no auth),
/// which is the only network probe still in the picker.
struct DiscoveredModel: Codable, Hashable, Sendable {
    let id: String
    let displayName: String?

    init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// Outcome of a single probe run. Distinguishes the failure modes the
/// UI cares about:
///
///   - `success([])` — probe completed, zero usable models. Ollama-
///     specific: the daemon is reachable but nothing's pulled.
///   - `authFailure` — provider returned 401/403. (Not expected for the
///     local Ollama probe today, but kept in the enum so future probes
///     can reuse the shape.)
///   - `unreachable` — DNS / connection refused / 404.
///   - `networkError` — offline / transient.
enum ProbeResult: Sendable {
    case success([DiscoveredModel])
    case authFailure
    case unreachable
    case networkError(String)
}

/// Behaviour for model discovery. Only Ollama implements this now.
protocol AIProviderProbe: Sendable {
    var provider: LLMProvider { get }

    func probe(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async -> ProbeResult
}
