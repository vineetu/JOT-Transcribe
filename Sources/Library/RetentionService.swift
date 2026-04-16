import Foundation
import SwiftData
import os.log

/// Enforces the `jot.retentionDays` preference: on launch and hourly
/// thereafter, delete any `Recording` (and its WAV on disk) older than the
/// cutoff. `retentionDays == 0` means "keep forever" and short-circuits.
///
/// A single shared timer is cheap; the purge itself is a one-shot SwiftData
/// fetch bounded by `createdAt < cutoff`. Hourly cadence is overkill for the
/// day-granularity setting but it's free, and it means a user who flips the
/// dropdown from "Forever" to "7 days" sees expired rows disappear within an
/// hour instead of having to quit + relaunch.
@MainActor
final class RetentionService {
    private let log = Logger(subsystem: "com.jot.Jot", category: "Retention")
    private weak var context: ModelContext?
    private var timer: Timer?

    init(context: ModelContext) {
        self.context = context
    }

    func start() {
        purgeOnce()
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
        let days = UserDefaults.standard.integer(forKey: "jot.retentionDays")
        guard days > 0 else { return }

        guard let context else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.createdAt < cutoff }
        )

        let expired: [Recording]
        do {
            expired = try context.fetch(descriptor)
        } catch {
            log.error("Retention fetch failed: \(String(describing: error), privacy: .public)")
            return
        }

        guard !expired.isEmpty else { return }

        for recording in expired {
            // `RecordingStore.delete` removes the WAV on disk + the row.
            RecordingStore.delete(recording, from: context)
        }

        do {
            try context.save()
            log.info("Retention purge: \(expired.count) recording(s) older than \(days)d removed")
        } catch {
            log.error("Retention save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
