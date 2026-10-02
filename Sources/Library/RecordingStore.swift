import Foundation
import JotVocabCore
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

    /// Group a heterogeneous list of `LibraryItem`s (dictation `Recording`
    /// rows interleaved with `RewriteSession` rows) into `[group: [item]]`,
    /// preserving sort order within each bucket. Callers are expected to hand
    /// in a list already sorted by `createdAt` descending.
    static func grouped(libraryItems: [LibraryItem], now: Date = .now) -> [(RecordingDateGroup, [LibraryItem])] {
        var buckets: [RecordingDateGroup: [LibraryItem]] = [:]
        for item in libraryItems {
            buckets[group(for: item.createdAt, now: now), default: []].append(item)
        }
        return RecordingDateGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return (g, items)
        }
    }

    /// The newest saved dictation — what Paste Last / Copy Last give. Its
    /// text already carries AI cleanup, "Did you mean…?" answers, and edits.
    static func latest(in context: ModelContext) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The row with `id`, or nil when it was deleted.
    static func recording(id: UUID, in context: ModelContext) -> Recording? {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Delete a recording from the context *and* everything derived from it.
    static func delete(_ recording: Recording, from context: ModelContext) {
        delete([recording], from: context)
    }

    /// Delete recordings from the context *and* everything derived from them:
    /// their backing WAVs, correction provenance, semantic-search chunks (so a
    /// deleted recording can never answer Ask Jot), and any open edit draft.
    /// We remove the files first so a failed deletion can't leave a dangling
    /// row; a file already gone (user deleted it in Finder, retention cleaned
    /// up later, etc.) is ignored and the DB delete proceeds. One chunk delete
    /// and one save for the whole batch (the retention purge), saved at once
    /// so an index write still in flight for a row sees it gone.
    static func delete(_ recordings: [Recording], from context: ModelContext) {
        guard !recordings.isEmpty else { return }
        // Value-typed ids captured before the rows leave the context, so the
        // detached provenance `Task` is race-free.
        let ids = recordings.map(\.id)
        for recording in recordings {
            try? FileManager.default.removeItem(at: audioURL(for: recording))
        }
        Task {
            for id in ids { await CorrectionProvenance.shared.discard(transcriptID: id) }
        }
        for id in ids { TranscriptEditSessions.shared.end(id) }
        ChunkStore.deleteChunks(recordingIDs: ids, container: context.container)
        for recording in recordings { context.delete(recording) }
        try? context.save()
    }

    /// Delete a `RewriteSession` row. No filesystem cleanup needed —
    /// rewrite sessions don't persist any audio (the voice-instruction
    /// WAV is intentionally dropped at capture time).
    static func delete(_ session: RewriteSession, from context: ModelContext) {
        context.delete(session)
    }

    /// Rename is in-place — SwiftData tracks the change automatically. Kept
    /// as a function so the call site reads at intent-level.
    static func rename(_ recording: Recording, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.title = trimmed.isEmpty ? "Untitled recording" : trimmed
    }

    /// Rename a `RewriteSession` in place, mirroring the `Recording`
    /// variant. Empty / whitespace-only input falls back to a placeholder
    /// title.
    static func rename(_ session: RewriteSession, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        session.title = trimmed.isEmpty ? "Untitled rewrite" : trimmed
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
