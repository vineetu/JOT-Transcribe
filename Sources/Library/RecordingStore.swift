import Foundation
import SwiftData

/// Date-bucketed sections the recordings list renders. Order is declared by
/// `allCases`; every recording falls into exactly one bucket.
enum RecordingDateGroup: Int, CaseIterable, Identifiable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case earlier

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 Days"
        case .previous30Days: return "Previous 30 Days"
        case .earlier: return "Earlier"
        }
    }
}

/// Helpers around `Recording` that don't belong on the `@Model` itself
/// (anything filesystem- or context-aware). Keeping them here means views can
/// stay declarative and the model stays a plain value bag.
@MainActor
enum RecordingStore {
    /// Root directory for all WAVs: `~/Library/Application Support/Jot/Recordings/`.
    /// Matches `AudioCapture.defaultRecordingsDirectory` — kept in lockstep so
    /// a recording saved by one can be read back by the other.
    static var audioDirectory: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Jot/Recordings", isDirectory: true)
    }

    static func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.audioFileName)
    }

    /// Bucket a `createdAt` against `now` into a display group. The boundaries
    /// use `Calendar.current.startOfDay(for:)` so "today" means *the calendar
    /// day*, not "within the last 24 hours".
    static func group(for date: Date, now: Date = .now, calendar: Calendar = .current) -> RecordingDateGroup {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              let startOf7DaysAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday),
              let startOf30DaysAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) else {
            return .earlier
        }
        if date >= startOfToday { return .today }
        if date >= startOfYesterday { return .yesterday }
        if date >= startOf7DaysAgo { return .previous7Days }
        if date >= startOf30DaysAgo { return .previous30Days }
        return .earlier
    }

    /// Group a list of recordings into `[group: [recording]]`, preserving
    /// sort order within each bucket. Callers are expected to hand in a list
    /// already sorted by `createdAt` descending.
    static func grouped(_ recordings: [Recording], now: Date = .now) -> [(RecordingDateGroup, [Recording])] {
        var buckets: [RecordingDateGroup: [Recording]] = [:]
        for r in recordings {
            buckets[group(for: r.createdAt, now: now), default: []].append(r)
        }
        return RecordingDateGroup.allCases.compactMap { g in
            guard let rs = buckets[g], !rs.isEmpty else { return nil }
            return (g, rs)
        }
    }

    /// Delete a recording from the context *and* its backing WAV. We remove
    /// the file first so a failed deletion can't leave a dangling row; if the
    /// file is already gone (user deleted it in Finder, retention cleaned up
    /// later, etc.) we swallow the error and proceed with the DB delete.
    static func delete(_ recording: Recording, from context: ModelContext) {
        let url = audioURL(for: recording)
        try? FileManager.default.removeItem(at: url)
        context.delete(recording)
    }

    /// Rename is in-place — SwiftData tracks the change automatically. Kept
    /// as a function so the call site reads at intent-level.
    static func rename(_ recording: Recording, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.title = trimmed.isEmpty ? "Untitled recording" : trimmed
    }
}

/// Relative "2 min ago" formatter, cached because `RelativeDateTimeFormatter`
/// is expensive to spin up per row.
enum RelativeTimestamp {
    static let shared: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(for date: Date, relativeTo reference: Date = .now) -> String {
        shared.localizedString(for: date, relativeTo: reference)
    }
}
