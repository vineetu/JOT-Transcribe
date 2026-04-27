import Foundation

enum LLMError: Error, LocalizedError {
    case noAPIKey
    case invalidURL
    case httpError(statusCode: Int, body: String)
    case decodingError(Error)
    case emptyResponse
    case networkError(Error)
    case suspiciousResponse
    case appleIntelligenceUnavailable
    case appleIntelligenceFailure(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            "No API key configured. Add your API key in Settings → AI."
        case .invalidURL:
            "Invalid API endpoint URL."
        case .httpError(let statusCode, _):
            // I2 fix: do NOT interpolate `body` into the user-facing
            // error message. The body has already been logged
            // server-side via `LLMClient.logLLMError → ErrorLog.redactedHTTPError`
            // (which records only `bodyLength`, not contents). Surfacing
            // the raw body to the pill leaks provider-specific error
            // strings (e.g. OpenAI's `internal_server_error: ...`) up
            // to the user. The status code alone is enough for the
            // user-facing pill copy.
            "API request failed (HTTP \(statusCode))."
        case .decodingError(let error):
            "Failed to parse API response: \(error.localizedDescription)"
        case .emptyResponse:
            "The API returned an empty response."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .suspiciousResponse:
            "The API returned a suspiciously short or long response."
        case .appleIntelligenceUnavailable:
            "Apple Intelligence isn't available on this Mac. Requires macOS 26.0 or later on Apple Silicon with Apple Intelligence enabled."
        case .appleIntelligenceFailure(let message):
            "Apple Intelligence failed: \(message)"
        }
    }
}
