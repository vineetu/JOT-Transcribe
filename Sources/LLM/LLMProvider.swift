import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai
    case anthropic
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: "gpt-4o"
        case .anthropic: "claude-sonnet-4-20250514"
        case .gemini: "gemini-2.0-flash"
        }
    }
}
