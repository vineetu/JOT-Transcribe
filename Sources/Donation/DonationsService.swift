import Foundation

/// Read-only client for the donations summary endpoint at
/// `jot-donations.ideaflow.page/summary`. Stateless — no auth, no
/// device identifiers, no per-user state. The server learns about
/// donations via an every.org webhook (`POST /webhook`); the client
/// only ever GETs the totals.
///
/// Mirrors `jot-mobile`'s `DonationsService` 1:1 (CLAUDE.md flags
/// network calls as user-visible; this one is user-initiated: the
/// user opens the Donations page or pull-to-refreshes it).
enum DonationsService {
    enum Error: Swift.Error {
        case invalidResponse
        case badStatus(Int)
    }

    private static let endpoint = URL(string: "https://jot-donations.ideaflow.page/summary")!

    /// Fetch the latest totals. Throws `Error.invalidResponse` for a
    /// non-HTTPURLResponse (shouldn't happen in production but
    /// guards against odd URLSession harnesses) and
    /// `Error.badStatus(code)` for any non-2xx.
    static func fetchSummary(session: URLSession = .shared) async throws -> DonationsSummary {
        let (data, response) = try await session.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Error.badStatus(httpResponse.statusCode)
        }
        return try decoder.decode(DonationsSummary.self, from: data)
    }

    /// Decode a previously-cached payload from
    /// `@AppStorage("jot.donations.lastSummary")`. Returns `nil`
    /// for empty (first-launch) or malformed data — the caller
    /// treats `nil` as "no cache, fall back to loading state".
    static func decodeCachedSummary(from data: Data) -> DonationsSummary? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(DonationsSummary.self, from: data)
    }

    /// Encode for persistence into the same `@AppStorage` key. Cache
    /// is append-only — totals can only go up, so even very old
    /// cached data is still useful for "last known totals" framing.
    static func encodeForCache(_ summary: DonationsSummary) -> Data? {
        try? encoder.encode(summary)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
