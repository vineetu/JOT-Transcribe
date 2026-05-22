import Foundation

/// Factory: `LLMProvider` → the concrete probe instance that handles
/// it. `nil` for providers without a `/models` discovery story (Apple
/// Intelligence is a single OS-managed model; `flavor1` exposes its
/// own curated picker and authenticates via JWT — both bypass this
/// path entirely).
///
/// Kept tiny and stateless so callers can construct probes on demand
/// without worrying about lifetime; each `probe(...)` call captures
/// the URLSession it should use.
enum ProbeRegistry {
    static func probe(for provider: LLMProvider) -> (any AIProviderProbe)? {
        switch provider {
        case .openai:    return OpenAIProbe()
        case .anthropic: return AnthropicProbe()
        case .gemini:    return GeminiProbe()
        case .ollama:    return OllamaProbe()
        case .appleIntelligence: return nil
        #if JOT_FLAVOR_1
        case .flavor1: return nil
        #endif
        }
    }
}
