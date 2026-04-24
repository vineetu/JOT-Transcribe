import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleIntelligence
    case openai
    case anthropic
    case gemini
    case ollama
    #if JOT_FLAVOR_1
    case flavor1
    #endif

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence (on-device)"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .ollama: "Ollama (local)"
        #if JOT_FLAVOR_1
        case .flavor1: (Bundle.main.infoDictionary?["FLAVOR_1_DISPLAY_NAME"] as? String) ?? "PFB Enterprise"
        #endif
        }
    }

    /// Case name as a plain string, used to build Info.plist override keys.
    /// Kept separate from `rawValue` so we can evolve `rawValue` independently
    /// without breaking override lookups.
    private var rawValueForInfoPlist: String { String(describing: self) }

    /// Default endpoint for this provider. Can be overridden per-provider at
    /// build time by injecting `JotDefaultEndpoint.<case>` into Info.plist
    /// (e.g. `JotDefaultEndpoint.openai`). If no override is present, the
    /// public vendor endpoint is used.
    ///
    /// Apple Intelligence has no endpoint — calls go through the on-device
    /// `FoundationModels` framework. The Info.plist override system does not
    /// apply; returns `""`.
    var defaultBaseURL: String {
        if self == .appleIntelligence { return "" }
        #if JOT_FLAVOR_1
        if self == .flavor1 {
            // Flavor-1 has no vendor-public fallback — the endpoint is
            // injected via Info.plist at build time. Return "" if absent
            // so the pane surfaces a configuration error instead of
            // silently hitting the wrong host.
            return (Bundle.main.infoDictionary?["FLAVOR_1_DEFAULT_ENDPOINT"] as? String) ?? ""
        }
        #endif
        let key = "JotDefaultEndpoint.\(rawValueForInfoPlist)"
        if let override = Bundle.main.infoDictionary?[key] as? String, !override.isEmpty {
            return override
        }
        switch self {
        case .appleIntelligence: return ""
        case .openai:       return "https://api.openai.com/v1"
        case .anthropic:    return "https://api.anthropic.com/v1"
        case .gemini:       return "https://generativelanguage.googleapis.com/v1beta"
        case .ollama:       return "http://localhost:11434/v1"
        #if JOT_FLAVOR_1
        case .flavor1:      return ""
        #endif
        }
    }

    /// Default model for this provider. Can be overridden per-provider at
    /// build time by injecting `JotDefaultModel.<case>` into Info.plist
    /// (e.g. `JotDefaultModel.openai`). If no override is present, a sensible
    /// public default is used.
    ///
    /// Apple Intelligence routes through `SystemLanguageModel.default`; the
    /// model identifier is managed by the OS, so returns `""`.
    var defaultModel: String {
        if self == .appleIntelligence { return "" }
        #if JOT_FLAVOR_1
        if self == .flavor1 {
            // Flavor-1's default model is injected via Info.plist — no
            // vendor-public fallback. Return "" if absent.
            return (Bundle.main.infoDictionary?["FLAVOR_1_DEFAULT_MODEL"] as? String) ?? ""
        }
        #endif
        let key = "JotDefaultModel.\(rawValueForInfoPlist)"
        if let override = Bundle.main.infoDictionary?[key] as? String, !override.isEmpty {
            return override
        }
        switch self {
        case .appleIntelligence: return ""
        case .openai:       return "gpt-5.4-mini"
        case .anthropic:    return "claude-haiku-4-5-20251001"
        case .gemini:       return "gemini-3.1-flash-lite-preview"
        case .ollama:       return "gemma4:31b-cloud"
        #if JOT_FLAVOR_1
        case .flavor1:      return ""
        #endif
        }
    }

    /// Whether this provider requires the user to paste an API key in
    /// Settings → AI for requests to succeed. Cloud vendors need a key;
    /// local/on-device providers do not.
    var requiresUserAPIKey: Bool {
        switch self {
        case .openai, .anthropic, .gemini: return true
        case .ollama, .appleIntelligence:  return false
        #if JOT_FLAVOR_1
        // Flavor-1 authenticates via short-lived JWT (not an API key);
        // credential handling lives entirely in Sources/Private/Flavor1/.
        case .flavor1:                     return false
        #endif
        }
    }

    /// Whether the streaming path should wrap `session.bytes(for:)` in a
    /// 3s first-byte timeout race. Cloud endpoints are always-warm, so a
    /// tight reachability check catches dead hosts fast. Ollama's
    /// `:cloud`-suffixed models routinely exceed 3s TTFB and are bounded
    /// by the outer per-request `timeoutInterval` instead. Apple
    /// Intelligence never reaches this path — value is moot, kept false
    /// so the enum is total.
    var usesFirstByteWatchdog: Bool {
        switch self {
        case .openai, .anthropic, .gemini: return true
        case .ollama, .appleIntelligence:  return false
        #if JOT_FLAVOR_1
        // Flavor-1 is a cloud endpoint (always-warm); use the same 3s
        // first-byte reachability check as other cloud providers.
        case .flavor1:                     return true
        #endif
        }
    }
}
