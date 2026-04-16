import Foundation

enum LLMError: Error, LocalizedError {
    case noAPIKey
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case emptyResponse
    case networkError(Error)
    case suspiciousResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No API key configured. Add your API key in Settings → AI Rewrite."
        case .invalidURL:
            "Invalid API endpoint URL."
        case .httpError(let statusCode, let body):
            "API request failed (HTTP \(statusCode)): \(body)"
        case .decodingError(let error):
            "Failed to parse API response: \(error.localizedDescription)"
        case .emptyResponse:
            "The API returned an empty response."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .suspiciousResponse:
            "The API returned a suspiciously short or long response."
        }
    }
}
