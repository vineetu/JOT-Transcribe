import Foundation
import SwiftData
import os.log

/// Shared chunk-embedding pipeline for `Recording`s. ONE call site for the
/// on-save hook (`RecordingPersister.persist`), the first-launch backfill, and
/// the manual "Rebuild index" button — so they can never drift on guard /
/// chunking / persistence semantics.
///
/// Ported from jot-mobile's `TranscriptIndexer`. macOS differences:
/// - The `ModelContainer` is injected (no global `JotModelContainer.shared`).
/// - The gate is `SemanticSearchSettings.isEnabled` (default ON, opt-out), same
///   posture as mobile's `AppGroup.isEmbeddingsEnabled` (default ON).
/// - The backfill pauses while dictation is live (`recorderIsIdle == false`) so
///   it never contends with Parakeet for the ANE.
///
/// ## Pipeline (per recording)
/// 1. Bail if the feature is off, or the text is empty.
/// 2. Split into ~110-token chunks (`TranscriptChunker`).
/// 3. Embed each chunk with EmbeddingGemma (`role: .document`).
/// 4. Persist via `ChunkStore.replaceChunks(...)` (delete-then-insert),
///    denormalizing the parent's `createdAt` / `durationSeconds`.
///
/// Failures are logged + swallowed — the backfill / manual rebuild are the
/// durable backstops. A failed embed must never break the save path.
@MainActor
@Observable
final class RecordingIndexer {
    /// Process-wide instance, wired by the composition root once the container
    /// exists. `RecordingPersister` reads this from its main-actor save hook.
    @ObservationIgnored static var shared: RecordingIndexer?

    /// Live backfill/rebuild progress, for the ADVANCED-ONLY indexing-status row
    /// in Settings. `total == 0` means no sweep is running. Normal users never
    /// see this — the index fills silently.
    private(set) var sweepDone: Int = 0
    private(set) var sweepTotal: Int = 0
    var isSweeping: Bool { sweepTotal > 0 && sweepDone < sweepTotal }

    @ObservationIgnored private let container: ModelContainer
    /// Reads `RecorderController.state == .idle`. Used by the backfill to yield
    /// the ANE to live dictation. Optional so test harnesses can omit it.
    private let recorderIsIdle: @MainActor () -> Bool

    @ObservationIgnored private let log = Logger(subsystem: "com.jot.Jot", category: "recording-indexer")

    /// Trickle delay between recordings during the historical backfill so it
    /// never hammers the ANE — the library drains slowly in the background. New
    /// recordings still index immediately on save (the on-save hook ignores
    /// this). Rebuild (user-initiated) skips the delay for responsiveness.
    @ObservationIgnored private let backfillBatchDelayNanos: UInt64 = 750_000_000

    /// Guards against two concurrent sweeps (e.g. launch backfill racing a
    /// manual rebuild).
    @ObservationIgnored private var sweepRunning = false

    /// Chunk to ~110 tokens, NOT the chunker's 256 default: the bundled
    /// EmbeddingGemma model has `max_seq_len = 128`, so longer chunks are
    /// silently truncated. 110 leaves headroom for the task-prefix tokens the
    /// encoder prepends. (Ported verbatim from mobile.)
    private let targetTokens = 110

    init(
        container: ModelContainer,
        recorderIsIdle: @escaping @MainActor () -> Bool = { true }
    ) {
        self.container = container
        self.recorderIsIdle = recorderIsIdle
    }

    // MARK: - On-save hook (fire-and-forget)

    /// Fire-and-forget. Returns immediately; chunk + embed + persist runs on a
    /// detached `.utility` task so the encode never hitches the UI.
    func index(recordingID: UUID, text: String) {
        guard SemanticSearchSettings.isEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let container = self.container
        let targetTokens = self.targetTokens
        Task.detached(priority: .utility) {
            await RecordingIndexer.runIndexPipeline(
                recordingID: recordingID,
                text: text,
                targetTokens: targetTokens,
                container: container
            )
        }
    }

    // MARK: - Backfill (existing un-indexed recordings)

    /// Gentle, incremental backfill of the EXISTING library: indexes only
    /// recordings lacking chunks at the current `modelVersion`, ONE recording at
    /// a time, on a low-priority task, with a trickle delay between each, and
    /// yielding entirely while dictation is live (never competes with Parakeet
    /// for the ANE). Progress is naturally persisted: each finished recording
    /// gains chunk rows, so a relaunch only processes the un-indexed remainder.
    func backfillMissing() async {
        guard SemanticSearchSettings.isEnabled else { return }
        guard !sweepRunning else { return }
        let missing = ChunkStore.recordingIDsMissingChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            limit: Int.max,
            container: container
        )
        guard !missing.isEmpty else { return }
        let missingSet = Set(missing)
        let items = fetchItems(matching: missingSet)
        await runSweep(items: items, trickle: true)
    }

    /// Manual full re-index ("Rebuild index" button): re-chunks + re-embeds
    /// EVERY recording at the current model. Honors cancellation between rows.
    /// No trickle delay — the user asked for it, so run it promptly (still
    /// yielding to live dictation).
    func rebuildAll() async {
        guard SemanticSearchSettings.isEnabled else { return }
        guard !sweepRunning else { return }
        let items = fetchItems(matching: nil)
        await runSweep(items: items, trickle: false)
    }

    /// Diagnostic count of recordings not yet indexed at the current version.
    func unindexedCount() -> Int {
        let missing = ChunkStore.recordingIDsMissingChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            limit: Int.max,
            container: container
        )
        let missingSet = Set(missing)
        return fetchItems(matching: missingSet).count
    }

    // MARK: - Sweep body

    private func fetchItems(matching ids: Set<UUID>?) -> [(id: UUID, text: String)] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.compactMap { r in
            if let ids, !ids.contains(r.id) { return nil }
            let trimmed = r.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (r.id, r.transcript)
        }
    }

    private func runSweep(items: [(id: UUID, text: String)], trickle: Bool) async {
        let total = items.count
        guard total > 0 else { return }
        sweepRunning = true
        sweepDone = 0
        sweepTotal = total
        defer {
            sweepRunning = false
            sweepTotal = 0
            sweepDone = 0
        }
        log.info("Index sweep: \(total, privacy: .public) recordings trickle=\(trickle, privacy: .public)")
        let container = self.container
        let targetTokens = self.targetTokens
        for item in items {
            if Task.isCancelled { return }
            // ANE contention guard: while dictation is in progress, Parakeet
            // wants the Neural Engine. Yield in short sleeps until idle.
            while !recorderIsIdle() {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await RecordingIndexer.runIndexPipeline(
                recordingID: item.id,
                text: item.text,
                targetTokens: targetTokens,
                container: container
            )
            sweepDone += 1
            // Trickle: a small delay between recordings so the historical
            // backfill drains slowly rather than hammering the ANE in a burst.
            if trickle {
                try? await Task.sleep(nanoseconds: backfillBatchDelayNanos)
            }
        }
        log.info("Index sweep complete: \(self.sweepDone, privacy: .public)/\(total, privacy: .public)")
    }

    // MARK: - Pipeline

    /// `nonisolated` so the detached on-save Task and the awaited sweep share one
    /// body. The embed loop runs off-main; only the SwiftData write hops to Main.
    private static func runIndexPipeline(
        recordingID: UUID,
        text: String,
        targetTokens: Int,
        container: ModelContainer
    ) async {
        let log = Logger(subsystem: "com.jot.Jot", category: "recording-indexer")
        let drafts = TranscriptChunker.chunk(text, targetTokens: targetTokens)
        guard !drafts.isEmpty else { return }
        do {
            var embedded: [(chunkIndex: Int, text: String, vector: [Float], charStart: Int, charEnd: Int)] = []
            embedded.reserveCapacity(drafts.count)
            for draft in drafts {
                if Task.isCancelled { return }
                let vector = try await EmbeddingGemmaService.shared.encode(draft.text, role: .document)
                embedded.append((draft.chunkIndex, draft.text, vector, draft.charStart, draft.charEnd))
            }
            let chunks = embedded
            try await MainActor.run {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<Recording>(
                    predicate: #Predicate<Recording> { $0.id == recordingID }
                )
                descriptor.fetchLimit = 1
                let parent = try? context.fetch(descriptor).first
                try ChunkStore.replaceChunks(
                    recordingID: recordingID,
                    chunks: chunks,
                    modelVersion: EmbeddingGemmaService.modelVersion,
                    createdAt: parent?.createdAt ?? Date(),
                    durationSeconds: parent?.durationSeconds,
                    container: container
                )
            }
        } catch {
            log.debug("index pipeline failed id=\(recordingID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
