import Foundation

/// Server response shape for `GET /summary` on
/// `jot-donations.ideaflow.page`. JSON arrives in snake_case so the
/// `CodingKeys` map back to Swift's camelCase. Mirrors the iOS port
/// in `jot-mobile` 1:1 — keep the field set + names identical so a
/// shared server change doesn't fork the two clients.
struct DonationsSummary: Codable, Equatable, Sendable {
    let totalDonations: Int
    let totalRaisedUSD: Double
    let perCharity: [DonationCharity]
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case totalDonations = "total_donations"
        case totalRaisedUSD = "total_raised_usd"
        case perCharity = "per_charity"
        case lastUpdated = "last_updated"
    }
}

/// One charity row in `DonationsSummary.perCharity`. The `slug` is
/// the row identity (used both as `Identifiable.id` and to build the
/// outbound every.org donate URL) and is stable across releases.
struct DonationCharity: Codable, Equatable, Hashable, Identifiable, Sendable {
    let slug: String
    let name: String
    let count: Int
    let totalRaisedUSD: Double

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case count
        case totalRaisedUSD = "total_raised_usd"
    }
}
