import Foundation
import SwiftData
import os.log

/// One retrieved transcript chunk, carrying everything a RAG caller needs:
/// the chunk's own text, its relevance score, the character span back into the
/// parent transcript, and the `recordingID` link. Unlike
/// `SemanticSearchController` (which collapses results down to `Set<UUID>` for a
/// live search filter), this keeps `text` + `score` so an LLM can be grounded on
/// the actual passages.
///
/// `Sendable` so a freshly-computed result set can hop back to the main actor.
struct RetrievedChunk: Sendable {
    let recordingID: UUID
    let chunkIndex: Int
    let text: String
    let score: Float
    let charStart: Int
    let charEnd: Int
    let createdAt: Date
}

/// Top-k transcript retriever for RAG.
///
/// Given a natural-language query, returns the most relevant transcript chunks
/// (text + cosine score + recording link), computed **off the main actor**.
///
/// ## Relationship to `SemanticSearchController`
/// `SemanticSearchController` is the live, `@MainActor`, `@Observable` search
/// filter — it debounces keystrokes and publishes a `Set<UUID>` for the
/// recordings list to union with substring matches. `TranscriptRetriever` is the
/// non-UI sibling: a one-shot `async` call that preserves the chunk text and
/// score so a downstream LLM prompt can be grounded on real passages. The cosine
/// math (unit-norm dot, defensive re-normalize) is intentionally identical.
///
/// ## Threading / actor isolation
/// SwiftData `ModelContext`s are actor-bound, and `ChunkStore` is `@MainActor`,
/// so the **fetch** must run on the main actor. But a fetch returns
/// `RecordingChunk` model objects, which are NOT `Sendable` — we cannot carry
/// them off-actor. So the flow is:
///   1. Embed the query on the `EmbeddingGemmaService` actor (`await`).
///   2. Hop to `@MainActor` to fetch chunks and immediately project each row
///      into a plain `Sendable` value (`ScannableChunk`) — copying the decoded
///      `[Float]` vector + text + ids + offsets out of the model object. After
///      this hop we never touch a `RecordingChunk` again.
///   3. Run the heavy cosine scan over those value types in a
///      `Task.detached` (utility QoS) — off the main actor — so a large library
///      never stutters the UI.
/// The query embed (step 1) is the slow part for small libraries (~40 ms) and the
/// scan (step 3) dominates for large ones; both are off the main actor, only the
/// SwiftData fetch (step 2) briefly touches it.
enum TranscriptRetriever {
    private static let log = Logger(
        subsystem: "com.jot.Jot",
        category: "transcript-retriever"
    )

    /// A `Sendable` snapshot of a `RecordingChunk` — everything the cosine scan
    /// and the `RetrievedChunk` result need, with the vector already decoded.
    /// Lets us leave the non-`Sendable` SwiftData model objects on the main
    /// actor while the scan runs off-actor.
    private struct ScannableChunk: Sendable {
        let recordingID: UUID
        let chunkIndex: Int
        let text: String
        let vector: [Float]
        let charStart: Int
        let charEnd: Int
        let createdAt: Date
    }

    /// Retrieve the top-`k` transcript chunks most relevant to `query`.
    ///
    /// - Parameters:
    ///   - query: Natural-language query. Trimmed; empty → `[]`.
    ///   - k: Maximum number of chunks to return (after sort + dedup).
    ///   - minScore: Cosine cutoff. Defaults to 0.30 — slightly below the live
    ///     search gate (0.35) because a RAG caller wants a few extra candidate
    ///     passages and the LLM can ignore weak ones; ranking still puts the
    ///     strongest first.
    ///   - allowMultiplePerRecording: When `false`, keeps only the single
    ///     best-scoring chunk per `recordingID` (mirrors the live search dedup).
    ///     When `true` (default), multiple chunks from the same recording may
    ///     appear — useful when one long recording holds several relevant ideas.
    ///   - container: The injected SwiftData container.
    /// - Returns: Up to `k` `RetrievedChunk`, sorted by score descending. Empty
    ///   on empty query, embed failure, or empty chunk pool — never throws.
    ///
    /// Not `@MainActor`: callable from any context. See the type doc for the
    /// fetch-on-main / scan-off-main split.
    static func retrieve(
        query: String,
        k: Int,
        minScore: Float = 0.30,
        allowMultiplePerRecording: Bool = true,
        dateInterval: DateInterval? = nil,
        container: ModelContainer
    ) async -> [RetrievedChunk] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, k > 0 else { return [] }

        // Step 1 — embed the query off the main actor (on the Gemma actor).
        // Asymmetric prompt: chunks were indexed with `role: .document`, so the
        // query MUST use `role: .query` to land in the same vector space.
        let modelVersion = EmbeddingGemmaService.modelVersion
        guard let queryVector = try? await EmbeddingGemmaService.shared.encode(trimmed, role: .query) else {
            log.debug("retrieve: query embed failed or feature unavailable")
            return []
        }

        // Step 2 — fetch on the main actor, project to Sendable value types, and
        // drop the SwiftData model objects before leaving the actor.
        let scannable: [ScannableChunk] = await MainActor.run {
            ChunkStore.allChunks(modelVersion: modelVersion, container: container).compactMap { chunk -> ScannableChunk? in
                // Hard date-window pre-filter (half-open [start, end)), applied
                // BEFORE the cosine scan so out-of-window chunks can't surface.
                if let iv = dateInterval,
                   !(chunk.createdAt >= iv.start && chunk.createdAt < iv.end) {
                    return nil
                }
                return ScannableChunk(
                    recordingID: chunk.recordingID,
                    chunkIndex: chunk.chunkIndex,
                    text: chunk.text,
                    vector: chunk.vector,
                    charStart: chunk.charStart,
                    charEnd: chunk.charEnd,
                    createdAt: chunk.createdAt
                )
            }
        }
        guard !scannable.isEmpty else { return [] }

        // Step 3 — heavy cosine scan off the main actor.
        let queryVectorCopy = queryVector
        return await Task.detached(priority: .utility) {
            scan(
                queryVector: queryVectorCopy,
                chunks: scannable,
                k: k,
                minScore: minScore,
                allowMultiplePerRecording: allowMultiplePerRecording
            )
        }.value
    }

    /// Pure chronological retrieval for a date-scoped summary that has NO topic
    /// to rank by ("summarize last week"): the recordings whose `createdAt` falls
    /// in `interval`, most-recent-first capped at `k`, then returned oldest→newest
    /// so the summary reads in order. Each recording becomes one `RetrievedChunk`
    /// carrying its full transcript (the prompt's snippet builder truncates), so
    /// `[cite: N]` still resolves per recording.
    static func retrieveByDate(interval: DateInterval, k: Int, container: ModelContainer) async -> [RetrievedChunk] {
        guard k > 0 else { return [] }
        let start = interval.start
        let end = interval.end
        return await MainActor.run {
            var descriptor = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { $0.createdAt >= start && $0.createdAt < end },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = k
            let recent = (try? ModelContext(container).fetch(descriptor)) ?? []
            return recent.reversed().map { r in
                RetrievedChunk(
                    recordingID: r.id,
                    chunkIndex: 0,
                    text: r.transcript,
                    score: 0,
                    charStart: 0,
                    charEnd: (r.transcript as NSString).length,
                    createdAt: r.createdAt
                )
            }
        }
    }

    /// `true` when retrieval can actually return results right now: the feature
    /// is enabled, the embedding model is downloaded, and the chunk pool is
    /// non-empty. A caller can use this to decide whether to offer a
    /// RAG-grounded answer or fall back. The `count(...)` fetch touches
    /// SwiftData, so it runs on the main actor.
    static func isAvailable(container: ModelContainer) async -> Bool {
        guard SemanticSearchSettings.isEnabled else { return false }
        guard EmbeddingGemmaService.isDownloaded() else { return false }
        let modelVersion = EmbeddingGemmaService.modelVersion
        let count = await MainActor.run {
            ChunkStore.count(modelVersion: modelVersion, container: container)
        }
        return count > 0
    }

    // MARK: - Cosine scan (off-actor, pure value types)

    private static func scan(
        queryVector: [Float],
        chunks: [ScannableChunk],
        k: Int,
        minScore: Float,
        allowMultiplePerRecording: Bool
    ) -> [RetrievedChunk] {
        let normalizedQuery = normalize(queryVector)
        guard !normalizedQuery.isEmpty else { return [] }

        // Both query and chunk vectors are unit-norm out of Gemma (cosine == dot);
        // we defensively re-normalize so a stray blob can't poison the score.
        var scored: [RetrievedChunk] = []
        scored.reserveCapacity(chunks.count)
        for chunk in chunks {
            let vector = chunk.vector
            guard vector.count == normalizedQuery.count else { continue }
            let normalizedRow = normalize(vector)
            guard !normalizedRow.isEmpty else { continue }
            let cosine = dot(normalizedQuery, normalizedRow)
            guard cosine >= minScore else { continue }
            scored.append(RetrievedChunk(
                recordingID: chunk.recordingID,
                chunkIndex: chunk.chunkIndex,
                text: chunk.text,
                score: cosine,
                charStart: chunk.charStart,
                charEnd: chunk.charEnd,
                createdAt: chunk.createdAt
            ))
        }

        scored.sort { $0.score > $1.score }

        if !allowMultiplePerRecording {
            // `scored` is already best-first, so the first sighting of each
            // recording IS its best-scoring chunk.
            var seen: Set<UUID> = []
            scored = scored.filter { seen.insert($0.recordingID).inserted }
        }

        if scored.count > k {
            scored = Array(scored.prefix(k))
        }
        return scored
    }

    // MARK: - Math (identical to SemanticSearchController)

    private static func normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return [] }
        return v.map { $0 / norm }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        for i in 0..<n { sum += a[i] * b[i] }
        return sum
    }
}
