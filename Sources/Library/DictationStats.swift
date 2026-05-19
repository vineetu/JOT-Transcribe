import Foundation

/// Lifetime + 14-day usage counters for dictation. Pure-Foundation,
/// thread-safe via `UserDefaults`, no UI in this file.
///
/// Ported from `jot-mobile`'s `Jot/Shared/DictationStats.swift`. Two
/// deliberate differences on the Mac side:
///   1. **No App Group.** iOS needs a shared container because the
///      keyboard extension writes from a separate process; the Mac
///      app is single-process (the menu-bar status item, hotkeys,
///      capture, transcription, and delivery all live inside one
///      `Jot` binary). `UserDefaults.standard` is sufficient.
///   2. **Donation-card gating not consumed.** The Mac home card
///      already has its own gating in `DonationLogic` /
///      `DonationStore` (count-based, with soft/hard dismiss). The
///      `shouldShowDonationCard` accessor here is a faithful port
///      but currently has no caller — left in so a later spec can
///      adopt it without rewriting the helper. Today only
///      `DonationsView` reads `totalSeconds` (for the
///      personalization line).
///
/// Spec is in `docs/plans/dictation-stats.md` (or wherever the team
/// drops the port spec); the constants below are the source of
/// truth and must not be re-declared elsewhere.
enum DictationStats {

    // MARK: - Tuning constants

    /// Threshold cumulative dictation before the home donation card
    /// would be allowed to render. Currently advisory only on Mac
    /// (see file-level note #2).
    static let donationThresholdSeconds: TimeInterval = 2 * 60 * 60

    /// Recorded duration × this = estimated time saved over typing.
    /// Speaking ≈ 150 WPM, typing ≈ 40 WPM → 2.5× is the defensible
    /// midpoint. Conservative on purpose; pick a higher number only
    /// if you can defend it.
    static let timeSavedMultiplier: Double = 2.5

    /// Grace period — don't ask for donations in the first week.
    /// Wikipedia-banner anti-pattern.
    static let donationCardMinDaysSinceFirstStat: Int = 7

    /// Upper sanity bound on a single dictation. Past this the call
    /// is clock skew or a logic bug; drop it rather than poison the
    /// counter.
    static let singleSessionCeilingSeconds: TimeInterval = 6 * 60 * 60

    /// Rolling window for the per-day rollups consumed by Settings
    /// sparkline (when ported).
    static let sparklineWindowDays: Int = 14

    // MARK: - UserDefaults keys

    private enum Keys {
        static let dictationCount = "jot.stats.dictationCount"
        static let dictationSeconds = "jot.stats.dictationSeconds"
        static let firstStatDate = "jot.stats.firstStatDate"
        static let donationCardState = "jot.stats.donationCardState"
        static let perDaySeconds = "jot.stats.perDaySeconds"
        static let perDayCount = "jot.stats.perDayCount"
    }

    private static var defaults: UserDefaults { .standard }

    // MARK: - Read-only accessors

    static var totalCount: Int {
        defaults.integer(forKey: Keys.dictationCount)
    }

    static var totalSeconds: TimeInterval {
        defaults.double(forKey: Keys.dictationSeconds)
    }

    static var firstStatDate: Date? {
        defaults.object(forKey: Keys.firstStatDate) as? Date
    }

    static var donationCardState: DonationCardState {
        get {
            guard let raw = defaults.string(forKey: Keys.donationCardState),
                  let state = DonationCardState(rawValue: raw) else {
                return .unseen
            }
            return state
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.donationCardState)
        }
    }

    static var estimatedTimeSavedSeconds: TimeInterval {
        totalSeconds * timeSavedMultiplier
    }

    // MARK: - Per-day rollups

    static var todaySeconds: TimeInterval {
        let key = dateKey(for: Date())
        return perDaySecondsDict[key] ?? 0
    }

    static var todayCount: Int {
        let key = dateKey(for: Date())
        return perDayCountDict[key] ?? 0
    }

    /// Oldest first. Always length `sparklineWindowDays`. Missing
    /// days are 0 so the sparkline can render a stable grid.
    static var last14DaysSeconds: [TimeInterval] {
        let dict = perDaySecondsDict
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<sparklineWindowDays).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dateKey(for: day)
            return dict[key] ?? 0
        }
    }

    // MARK: - Write

    /// Fire-and-forget. Bounded by `singleSessionCeilingSeconds`
    /// and ignored for non-positive durations. Stamps
    /// `firstStatDate` on the 0→1 transition. Compacts per-day
    /// rollups on every call (keeps the dict at ≤ 14 entries).
    static func record(durationSeconds: TimeInterval) {
        guard durationSeconds > 0,
              durationSeconds < singleSessionCeilingSeconds else { return }

        defaults.set(totalCount + 1, forKey: Keys.dictationCount)
        defaults.set(totalSeconds + durationSeconds, forKey: Keys.dictationSeconds)

        if firstStatDate == nil {
            defaults.set(Date(), forKey: Keys.firstStatDate)
        }

        // Per-day rollups. Read-modify-write each dict; UserDefaults
        // handles the disk fence.
        let key = dateKey(for: Date())
        var seconds = perDaySecondsDict
        var counts = perDayCountDict
        seconds[key, default: 0] += durationSeconds
        counts[key, default: 0] += 1

        // Compact: drop anything outside the rolling window. Compute
        // the cutoff once per write so a backlog of stale keys can't
        // linger across many writes.
        let cal = Calendar.current
        let cutoff = cal.startOfDay(
            for: cal.date(byAdding: .day, value: -(sparklineWindowDays - 1), to: Date()) ?? Date()
        )
        let cutoffKey = dateKey(for: cutoff)
        seconds = seconds.filter { $0.key >= cutoffKey }
        counts = counts.filter { $0.key >= cutoffKey }

        defaults.set(seconds, forKey: Keys.perDaySeconds)
        defaults.set(counts, forKey: Keys.perDayCount)
    }

    // MARK: - Donation card gating

    /// Three gates ANDed together (spec §3). Currently unused on
    /// Mac — kept for parity with iOS so a future spec can adopt it
    /// in one place.
    static var shouldShowDonationCard: Bool {
        guard donationCardState == .unseen else { return false }
        guard totalSeconds >= donationThresholdSeconds else { return false }
        guard let first = firstStatDate else { return false }
        let days = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
        return days >= donationCardMinDaysSinceFirstStat
    }

    // MARK: - Internals

    private static var perDaySecondsDict: [String: Double] {
        (defaults.dictionary(forKey: Keys.perDaySeconds) as? [String: Double]) ?? [:]
    }

    private static var perDayCountDict: [String: Int] {
        (defaults.dictionary(forKey: Keys.perDayCount) as? [String: Int]) ?? [:]
    }

    /// `"YYYY-MM-DD"` for the local calendar's start-of-day for the
    /// given date. Two calls inside the same calendar day produce
    /// the same key.
    private static func dateKey(for date: Date) -> String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let comps = cal.dateComponents([.year, .month, .day], from: start)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}

/// Donation-card lifecycle state. Terminal once moved off
/// `.unseen` — no cooldown, no re-asking. Ported as-is from iOS
/// even though the Mac home card uses a parallel state machine in
/// `DonationStore`; future consolidation can collapse them.
enum DonationCardState: String {
    case unseen
    case dismissed
    case donated
}
