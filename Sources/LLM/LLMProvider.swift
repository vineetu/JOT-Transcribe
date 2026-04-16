import Foundation

enum LLMProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openai
    case anthropic
    case gemini
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Gemini"
        case .ollama: "Ollama (local)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .ollama: "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: "gpt-5.4-mini"
        case .anthropic: "claude-haiku-4-5-20251001"
        case .gemini: "gemini-3.1-flash-lite-preview"
        case .ollama: "llama3.2:3b"
        }
    }
}
