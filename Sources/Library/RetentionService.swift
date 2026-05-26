import Foundation
import SwiftData
import os.log

/// Enforces the `jot.retentionDays` preference: on launch and hourly
/// thereafter, delete any expired library item older than the cutoff.
/// Both kinds participate: dictation `Recording` rows are deleted along
/// with their WAV files on disk, and `RewriteSession` rows are deleted
/// row-only (rewrite sessions don't persist audio). `retentionDays == 0`
/// means "keep forever" and short-circuits.
///
/// A single shared timer is cheap; the purge itself is two one-shot
/// SwiftData fetches bounded by `createdAt < cutoff`. Hourly cadence is
/// overkill for the day-granularity setting but it's free, and it means
/// a user who flips the dropdown from "Forever" to "7 days" sees expired
/// rows disappear within an hour instead of having to quit + relaunch.
@MainActor
final class RetentionService {
    private let log = Logger(subsystem: "com.jot.Jot", category: "Retention")
    private weak var context: ModelContext?
    private var timer: Timer?

    init(context: ModelContext) {
        self.context = context
    }

    func start() {
        // Defer the initial purge off the launch critical path. `purgeOnce`
        // is `@MainActor`-isolated, so it still runs on main — but it lands
        // after the first runloop turn instead of synchronously at launch.
        Task { @MainActor [weak self] in self?.purgeOnce() }
        // Why `Timer.scheduledTimer` rather than a repeating `Task.sleep`:
        // we want this to run on the main runloop without tying up a Task,
        // and `Timer` tolerates the app being backgrounded (missed ticks
        // coalesce rather than piling up).
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.purgeOnce() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        // Can't touch `timer` here (non-isolated deinit under strict
        // concurrency), but a lapsed context means the timer's callback
        // becomes a no-op anyway.
    }

    func purgeOnce() {
        // Default 90 days (bumped from 7 in the compressed-history migration —
        // AAC 16 kbps mono brings the on-disk footprint of 90 days to ~1.1 GB
        // at typical usage). Must stay in sync with the default on the
        // `@AppStorage("jot.retentionDays")` declaration in GeneralPane.swift.
        let days = (UserDefaults.standard.object(forKey: "jot.retentionDays") as? Int) ?? 90
        guard days > 0 else { return }

        guard let context else { return }

        // Compute the cutoff once and reuse it for both fetches so a row
        // straddling the boundary is judged by the same instant.
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        // 1. Expired Recording rows. A failed fetch is logged but does
        //    NOT short-circuit the RewriteSession sweep — see plan §4.
        let recordingDescriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )
        var expiredRecordings: [Recording] = []
        var recordingFetchFailed = false
        do {
            expiredRecordings = try context.fetch(recordingDescriptor)
        } catch {
            recordingFetchFailed = true
            log.error("Retention fetch failed (Recording): \(String(describing: error), privacy: .public)")
            Task { await ErrorLog.shared.error(component: "RetentionService", message: "Retention fetch failed (Recording)", context: ["error": ErrorLog.redactedAppleError(error)]) }
        }

        // 2. Expired RewriteSession rows. Same predicate, same cutoff —
        //    one purge tick handles both kinds. Independent of the
        //    Recording fetch's success.
        let sessionDescriptor = FetchDescriptor<RewriteSession>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )
        var expiredSessions: [RewriteSession] = []
        var sessionFetchFailed = false
        do {
            expiredSessions = try context.fetch(sessionDescriptor)
        } catch {
            sessionFetchFailed = true
            log.error("Retention fetch failed (RewriteSession): \(String(describing: error), privacy: .public)")
            Task { await ErrorLog.shared.error(component: "RetentionService", message: "Retention fetch failed (RewriteSession)", context: ["error": ErrorLog.redactedAppleError(error)]) }
        }

        // 3. Bail only when nothing succeeded AND there's nothing to
        //    delete. If both fetches failed, there's no work to do; if
        //    both lists are empty, same. Otherwise proceed to delete
        //    whatever survived its fetch.
        if recordingFetchFailed && sessionFetchFailed { return }
        guard !expiredRecordings.isEmpty || !expiredSessions.isEmpty else { return }

        for recording in expiredRecordings {
            // `RecordingStore.delete` removes the WAV on disk + the row.
            RecordingStore.delete(recording, from: context)
        }
        for session in expiredSessions {
            // No WAV to clean up; row-only delete.
            RecordingStore.delete(session, from: context)
        }

        do {
            try context.save()
            log.info("Retention purge: \(expiredRecordings.count) recording(s), \(expiredSessions.count) rewrite session(s) older than \(days)d removed")
        } catch {
            log.error("Retention save failed: \(String(describing: error), privacy: .public)")
            Task { await ErrorLog.shared.error(component: "RetentionService", message: "Retention save failed", context: ["error": ErrorLog.redactedAppleError(error), "expiredRecordings": String(expiredRecordings.count), "expiredSessions": String(expiredSessions.count)]) }
        }
    }
}
