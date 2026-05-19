import Foundation

/// Thin HTTP client for the feedback service at
/// `jot-donations.ideaflow.page`. Tiny enough to live next to the
/// composer sheet rather than under `LLM/` — this is not a
/// provider-neutral abstraction, just one endpoint that takes a
/// plain `{platform, version, message}` payload and returns
/// `{status, id?}` or `{status: "error", error}`.
///
/// Network paths in Jot are user-visible (the privacy invariant in
/// CLAUDE.md says a Little-Snitch user must see only the Parakeet
/// download, the daily appcast, and configured LLM endpoints). The
/// feedback submission is an explicit user-initiated action — the
/// user types a message and presses Send — so the outbound call is
/// expected and acceptable. No automatic / background calls live in
/// this file.
@MainActor
enum FeedbackClient {

    /// Where the feedback service accepts POSTs. Constant on purpose:
    /// keeping this in one place makes it grep-able and easy to swap
    /// later (e.g. if a Sony flavor ever wants to route feedback to
    /// an internal endpoint instead — would be a one-line addition
    /// gated on `#if JOT_FLAVOR_1`).
    static let endpoint = URL(string: "https://jot-donations.ideaflow.page/feedback")!

    /// Submit a single feedback message. Returns the server-assigned
    /// id on success; throws `FeedbackError` with a user-presentable
    /// `localizedDescription` on rate-limit / validation / transport
    /// errors so the sheet can surface them verbatim.
    static func send(message: String, session: URLSession = .shared) async throws -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "platform": "macos",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "message": message
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)

        // The API returns the same JSON shape on both 200 and error
        // status codes ({status: "ok", id} vs {status: "error",
        // error}). Decode first; only fall back to a synthetic
        // transport error if decoding fails on a non-2xx response.
        let decoded = try? JSONDecoder().decode(FeedbackResponse.self, from: data)

        if let decoded {
            if decoded.status == "ok", let id = decoded.id {
                return id
            }
            // Server reported error. Prefer the server's own message
            // (e.g. "Rate limit exceeded. Please try again later.")
            // since that's the most actionable thing for the user.
            throw FeedbackError.server(decoded.error ?? "The server rejected the feedback.")
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeedbackError.transport("Server returned HTTP \(http.statusCode).")
        }

        throw FeedbackError.transport("The server returned an unexpected response.")
    }
}

/// Decodable shape that matches both the success and error responses
/// documented in the API. `id` and `error` are both optional so a
/// single struct covers both branches.
private struct FeedbackResponse: Decodable {
    let status: String
    let id: Int?
    let error: String?
}

/// User-facing feedback submission errors. `localizedDescription`
/// is what the composer sheet shows under the editor.
enum FeedbackError: LocalizedError {
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .transport(let message): return message
        }
    }
}
