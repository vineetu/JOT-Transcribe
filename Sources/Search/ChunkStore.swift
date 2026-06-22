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
///   `modelVersion`. Used by the retrieval cosine scan.
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
@MainActor
enum ChunkStore {
    private static let log = Logger(subsystem: "com.jot.Jot", category: "chunk-store")

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

    /// All chunk rows at the given `modelVersion`. Full-row fetch (the cosine
    /// scan needs `vectorData`), so callers pull once and reuse per-query.
    static func allChunks(modelVersion: String, container: ModelContainer) -> [RecordingChunk] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RecordingChunk>(
            predicate: #Predicate<RecordingChunk> { $0.modelVersion == modelVersion }
        )
        return (try? context.fetch(descriptor)) ?? []
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
