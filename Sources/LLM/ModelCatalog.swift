import Foundation

/// Static, hand-curated list of selectable model IDs per provider. The
/// picker UI in Settings → AI reads from this enum; there is no network
/// probe for the cloud vendors. We tried unauthenticated probes against
/// OpenAI / Anthropic / Gemini `/v1/models` — all three return 401/403,
/// so an auth-free network catalog isn't available and a hand-maintained
/// list is the simplest honest answer. Ollama is the lone exception:
/// `localhost:11434/api/tags` is local, unauthenticated, and reflects the
/// models the user has pulled — that one keeps its live probe.
///
/// Update cadence: bump these strings when a new model lands that we want
/// users to see in the picker. Old IDs the user has stored continue to
/// work — the user's stored selection is honored even if it's not in this
/// catalog, so legacy picks survive a list update.
enum ModelCatalog {
    static func options(for provider: LLMProvider) -> [String] {
        switch provider {
        case .openai:
            return ["gpt-5.4-mini", "gpt-5.5"]
        case .anthropic:
            return ["claude-sonnet-4-6", "claude-haiku-4-5-20251001"]
        case .gemini:
            return ["gemini-3.1-flash-lite", "gemini-3.5-flash"]
        case .ollama, .lmStudio, .appleIntelligence:
            return []
        #if JOT_FLAVOR_1
        case .flavor1:
            return []
        #endif
        }
    }

    /// First-launch placeholder shown in the picker before the user has
    /// made an explicit selection. Read-only: never written to AppStorage.
    /// Matches `LLMProvider.defaultModel` so the value the picker shows
    /// matches what the actual LLM client will request if Cleanup /
    /// Rewrite fires before the user opens Settings.
    static func defaultOption(for provider: LLMProvider) -> String {
        provider.defaultModel
    }
}
