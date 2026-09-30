import Foundation
import SwiftData
import os.log

/// Typed wrapper around the `RecordingChunk` SwiftData entity.
///
/// Ported from jot-mobile (`jot-mobile/Jot/Shared/DerivedData/ChunkStore.swift`).
/// The macOS difference: mobile reaches a global `JotModelContainer.shared`; here
/// the `ModelContainer` is injected (the composition root owns the one true
/// container), so every static call takes it explicitly. A fresh `ModelContext`
/// is constructed per call — SwiftData contexts are actor-bound and cheap.
///
/// ## Read shape
/// - `allChunks(modelVersion:container:)` — every chunk row at the current
///   `modelVersion` whose recording still exists. Used by the retrieval
///   cosine scan and the live search filter.
/// - `recordingIDsMissingChunks(modelVersion:limit:container:)` — recording IDs
///   with no chunk row for the given `modelVersion`, most-recent first. Drives
///   the backfill backlog.
/// - `count(modelVersion:container:)` — diagnostic count for Settings.
///
/// ## Write shape
/// - `replaceChunks(...)` — delete-then-insert ALL chunks for one
///   `(recordingID, modelVersion)` pair in a single `save()`.
/// - `deleteAll(modelVersion:container:)` — drop every chunk row at a model
///   version for a from-scratch rebuild.
/// - `deleteChunks(recordingIDs:container:)` — drop deleted recordings' chunks
///   (all model versions) in one store-level delete.
/// - `purgeOrphanedChunksOnce(container:)` — one-time launch cleanup, off the
///   main thread, of chunks left behind by recordings deleted before deletion
///   removed them.
@MainActor
enum ChunkStore {
    nonisolated private static let log = Logger(subsystem: "com.jot.Jot", category: "chunk-store")

    /// Replaces ALL chunks for one recording at the given `modelVersion`:
    /// deletes the existing rows under `(recordingID, modelVersion)`, inserts the
    /// supplied set, and persists with one `context.save()`.
    static func replaceChunks(
        recordingID: UUID,
        chunks: [(chunkIndex: Int, text: String, vector: [Float], charStart: Int, charEnd: Int)],
        modelVersion: String,
        createdAt: Date,
        durationSeconds: Double?,
        container: ModelContainer
    ) throws {
        let context = ModelContext(container)

        let existingDescriptor = FetchDescriptor<RecordingChunk>(
            predicate: #Predicate<RecordingChunk> {
                $0.recordingID == recordingID && $0.modelVersion == modelVersion
            }
        )
        for existing in try context.fetch(existingDescriptor) {
            context.delete(existing)
        }

        let now = Date()
        for chunk in chunks {
            let blob = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
            context.insert(RecordingChunk(
                recordingID: recordingID,
                chunkIndex: chunk.chunkIndex,
                text: chunk.text,
                vectorData: blob,
                charStart: chunk.charStart,
                charEnd: chunk.charEnd,
                modelVersion: modelVersion,
                embeddedAt: now,
                createdAt: createdAt,
                durationSeconds: durationSeconds
            ))
        }
        try context.save()
    }

    /// All chunk rows at the given `modelVersion` whose recording still exists.
    /// Full-row fetch (the cosine scan needs `vectorData`), so callers pull
    /// once and reuse per-query. The existence filter is the backstop that
    /// keeps a deleted recording out of Ask Jot and search even if its chunks
    /// outlived it (an index write racing the delete, a pre-fix orphan).
    static func allChunks(modelVersion: String, container: ModelContainer) -> [RecordingChunk] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RecordingChunk>(
            predicate: #Predicate<RecordingChunk> { $0.modelVersion == modelVersion }
        )
        let chunks = (try? context.fetch(descriptor)) ?? []
        let live = recordingIDs(in: context)
        return chunks.filter { live.contains($0.recordingID) }
    }

    /// Deletes every chunk of the given recordings, at every model version —
    /// called when the recordings themselves are deleted. Returns whether the
    /// delete was saved.
    @discardableResult
    nonisolated static func deleteChunks(recordingIDs: [UUID], container: ModelContainer) -> Bool {
        guard !recordingIDs.isEmpty else { return true }
        let context = ModelContext(container)
        do {
            // A store-level delete: no chunk (or vector blob) is loaded.
            try context.delete(
                model: RecordingChunk.self,
                where: #Predicate<RecordingChunk> { recordingIDs.contains($0.recordingID) }
            )
            try context.save()
            return true
        } catch {
            log.error("Deleting chunks failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// One-time launch cleanup: deletes chunks whose recording no longer
    /// exists (left behind before deleting a recording removed its chunks).
    /// Runs off the main thread; gated by a defaults flag so it runs once per
    /// install.
    nonisolated static func purgeOrphanedChunksOnce(container: ModelContainer) {
        Task.detached(priority: .background) {
            let flag = "jot.search.orphanChunksPurged"
            guard !UserDefaults.standard.bool(forKey: flag) else { return }
            if let removed = purgeOrphanedChunks(container: container) {
                UserDefaults.standard.set(true, forKey: flag)
                log.info("Purged \(removed, privacy: .public) orphaned search chunk(s)")
            }
        }
    }

    /// Deletes chunks whose recording no longer exists, fetching ids only.
    /// Returns how many recordings' chunks were removed, or nil when the
    /// delete could not be saved.
    @discardableResult
    nonisolated static func purgeOrphanedChunks(container: ModelContainer) -> Int? {
        let context = ModelContext(container)
        let live = recordingIDs(in: context)
        var descriptor = FetchDescriptor<RecordingChunk>()
        descriptor.propertiesToFetch = [\.recordingID]
        let chunked = Set(((try? context.fetch(descriptor)) ?? []).map(\.recordingID))
        let orphaned = Array(chunked.subtracting(live))
        guard !orphaned.isEmpty else { return 0 }
        return deleteChunks(recordingIDs: orphaned, container: container) ? orphaned.count : nil
    }

    /// Ids of every existing recording (id-only fetch).
    nonisolated private static func recordingIDs(in context: ModelContext) -> Set<UUID> {
        var descriptor = FetchDescriptor<Recording>()
        descriptor.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
    }

    /// Up to `limit` Recording IDs that do NOT yet have any chunk row under
    /// `modelVersion`, most-recent first. ID-only fetches + a Set diff so a
    /// rebuild backlog scan doesn't pull every chunk's vector blob.
    static func recordingIDsMissingChunks(
        modelVersion: String,
        limit: Int,
        container: ModelContainer
    ) -> [UUID] {
        let context = ModelContext(container)

        var chunkedDescriptor = FetchDescriptor<RecordingChunk>(
            predicate: #Predicate<RecordingChunk> { $0.modelVersion == modelVersion }
        )
        chunkedDescriptor.propertiesToFetch = [\.recordingID]
        let chunked = (try? context.fetch(chunkedDescriptor)) ?? []
        let chunkedIDs = Set(chunked.map { $0.recordingID })

        var recordingDescriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        recordingDescriptor.propertiesToFetch = [\.id]
        let recordings = (try? context.fetch(recordingDescriptor)) ?? []

        var missing: [UUID] = []
        for recording in recordings {
            if chunkedIDs.contains(recording.id) { continue }
            missing.append(recording.id)
            if missing.count >= limit { break }
        }
        return missing
    }

    static func count(modelVersion: String, container: ModelContainer) -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RecordingChunk>(
            predicate: #Predicate<RecordingChunk> { $0.modelVersion == modelVersion }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Deletes every chunk row at the given `modelVersion` (from-scratch rebuild).
    static func deleteAll(modelVersion: String, container: ModelContainer) throws {
        let context = ModelContext(container)
        try context.delete(
            model: RecordingChunk.self,
            where: #Predicate<RecordingChunk> { $0.modelVersion == modelVersion }
        )
        try context.save()
    }
}
