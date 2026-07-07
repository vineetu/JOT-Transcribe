import Foundation
import SwiftData
import os.log

/// "Never lose audio" safety net (docs/resilient-transcription/design.md).
///
/// Runs once at launch: lists everything in `RecordingStore.audioDirectory`,
/// subtracts the `audioFileName`s already referenced by a `Recording` row,
/// and adopts each leftover file as a PENDING row (`pendingSince = .now`,
/// empty transcript). This recovers audio orphaned by a crash mid-
/// transcription, a force-quit, or any edge the failure-path persistence in
/// `RecorderController`/`FileTranscriptionIngest` doesn't catch (e.g. a user
/// cancel that lands during the `.transcribing` phase, after the WAV was
/// already finalized) — plus the already-shipping orphans that predate this
/// feature. The adopted rows are re-transcribable from Recents exactly like
/// any other pending row.
///
/// Mirrors `RetentionService`'s shape (weak `ModelContext`, deferred
/// off-launch-critical-path start, best-effort logging) but runs ONCE, not
/// on a repeating timer — there's no ongoing drift to correct, only a
/// one-time reconciliation between what's on disk and what SwiftData knows
/// about.
@MainActor
final class OrphanRecordingScanner {
    private let log = Logger(subsystem: "com.jot.Jot", category: "OrphanRecordingScanner")
    private weak var context: ModelContext?
    private let holder: TranscriberHolder
    /// Audio files newer than this are skipped — guards against adopting a
    /// WAV that's still being written by an in-flight recording that
    /// happens to start right at launch (extremely unlikely, but free to
    /// guard against: a mid-write file has no `Recording` row yet either).
    private let minimumAge: TimeInterval
    /// The transcriber rejects audio shorter than ~1s (`.audioTooShort`), so a
    /// sub-1s orphan is an accidental hotkey tap / aborted recording that can
    /// NEVER be transcribed — adopting it would create a permanent, unfixable
    /// "Needs transcription" clutter row. Skip these on adoption, and prune any
    /// this scanner wrongly adopted before this guard existed.
    private let minimumDuration: TimeInterval

    private static let audioExtensions: Set<String> = ["wav", "m4a"]

    init(context: ModelContext, transcriberHolder: TranscriberHolder, minimumAge: TimeInterval = 5, minimumDuration: TimeInterval = 1.0) {
        self.context = context
        self.holder = transcriberHolder
        self.minimumAge = minimumAge
        self.minimumDuration = minimumDuration
    }

    func start() {
        // Same idiom as `RetentionService.start()` — defer off the launch
        // critical path via a plain `Task`, not `Task.detached`, since the
        // SwiftData half needs the main-actor `ModelContext`. The directory
        // listing itself IS pushed to a detached background task below.
        Task { @MainActor [weak self] in await self?.scanOnce() }
    }

    func scanOnce() async {
        guard let context else { return }

        let all: [Recording]
        do {
            all = try context.fetch(FetchDescriptor<Recording>())
        } catch {
            log.error("Orphan scan: failed to fetch existing Recording rows: \(String(describing: error), privacy: .public)")
            Task { await ErrorLog.shared.error(component: "OrphanRecordingScanner", message: "Fetch failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            return
        }
        let known = Set(all.map(\.audioFileName))

        // Self-heal: prune any PENDING row below the transcriber's ~1s floor —
        // it can never be transcribed (re-transcribe throws `.audioTooShort`),
        // so it's permanent "Needs transcription" clutter. This also cleans up
        // sub-1s files a prior scan (before the `minimumDuration` guard in
        // `adopt`) wrongly adopted. Delete the row AND its tiny audio file.
        let junk = all.filter { $0.pendingSince != nil && $0.durationSeconds < minimumDuration }
        if !junk.isEmpty {
            for r in junk {
                let audioURL = RecordingStore.audioURL(for: r)
                context.delete(r)
                try? FileManager.default.removeItem(at: audioURL)
            }
            try? context.save()
            log.info("Orphan scan: pruned \(junk.count) sub-1s pending row(s) (untranscribable)")
        }

        let directory = RecordingStore.audioDirectory
        let extensions = Self.audioExtensions
        let minimumAge = self.minimumAge
        let orphanURLs: [URL] = await Task.detached(priority: .utility) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            let now = Date()
            return entries.filter { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                guard !known.contains(url.lastPathComponent) else { return false }
                guard let modDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    return false
                }
                return now.timeIntervalSince(modDate) > minimumAge
            }
        }.value

        guard !orphanURLs.isEmpty else { return }

        var adopted = 0
        for url in orphanURLs {
            if adopt(url: url, context: context) {
                adopted += 1
            }
        }
        guard adopted > 0 else { return }

        do {
            try context.save()
            log.info("Orphan scan: adopted \(adopted) audio file(s) with no Recording row as pending")
        } catch {
            log.error("Orphan scan: save failed: \(String(describing: error), privacy: .public)")
            Task { await ErrorLog.shared.error(component: "OrphanRecordingScanner", message: "Save failed", context: ["error": ErrorLog.redactedAppleError(error), "count": String(adopted)]) }
        }
    }

    /// Insert a pending `Recording` row for one orphaned audio file.
    /// Returns `false` (skip, don't insert) for a file that reads as
    /// zero-duration — most likely a zero-byte/corrupt leftover, not a
    /// real recording worth surfacing.
    private func adopt(url: URL, context: ModelContext) -> Bool {
        let duration = AudioFormat.duration(ofFileAt: url)
        // Skip sub-1s files (below the transcriber floor — accidental taps /
        // aborted recordings that can never be transcribed) and zero-duration
        // corrupt leftovers.
        guard duration >= minimumDuration else { return false }
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now

        let recording = Recording(
            createdAt: createdAt,
            title: Recording.defaultTitle(from: ""),
            durationSeconds: duration,
            transcript: "",
            rawTranscript: "",
            audioFileName: url.lastPathComponent,
            modelIdentifier: holder.primaryModelID.rawValue,
            pendingSince: .now
        )
        context.insert(recording)
        return true
    }
}
