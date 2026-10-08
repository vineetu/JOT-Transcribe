import Accelerate
import Foundation
import SwiftData
import os.log

/// Live semantic-search controller, held as `@State` inside `RecordingsListView`.
///
/// Ported from jot-mobile (`jot-mobile/Jot/App/Search/SemanticSearchController.swift`).
///
/// ## Hybrid contract
/// The controller publishes ONLY the semantic half of the result — substring
/// matching is cheap and stays in the view's existing filter. The view composes
/// `searchText.contains(...)` ∪ `semanticMatches.contains(recording.id)`.
/// The view debounces typing and calls `search(query:)` once the user pauses;
/// the semantic set lands ~10-50 ms later (query embed + one matrix-vector
/// multiply over the in-memory vector index).
///
/// ## Vector index
/// Every chunk vector for the current model version is loaded once, off the
/// main actor, into one flat pre-normalised `[Float]` matrix. A search is a
/// single `vDSP_mmul` against it, not a database fetch. The index is rebuilt
/// only when the chunk table changes (row count or newest `embeddedAt`), which
/// a cheap count + one-row fetch detects before each search.
///
/// ## Chunk-based retrieval
/// Each recording is split into chunks at index time; every chunk gets its own
/// 384-d unit-norm e5 vector (`role: .document`). At search time the query is
/// embedded with `role: .query` (asymmetric prompt) and scored against every
/// chunk. A recording matches if ANY of its chunks clears the threshold; we dedup
/// to the single best-scoring chunk per recording.
///
/// ## Graceful degradation
/// If the e5 model fails to load (missing/corrupt model, or feature off),
/// `semanticMatches` stays empty and the substring union still works — the search
/// field is never blocked on the embedder.
@MainActor
@Observable
final class SemanticSearchController {
    /// Last completed semantic-match set for the currently-published query.
    /// Empty when the query is blank or the search is in flight. Read from the
    /// view body — SwiftUI re-renders when it changes via `@Observable`.
    private(set) var semanticMatches: Set<UUID> = []

    /// `true` while a search task is in flight (post-debounce).
    private(set) var isSearching: Bool = false

    /// Cosine cutoff. Higher = more precise, fewer results. e5 scores run
    /// high (unrelated text still lands ~0.7), so this is not comparable to the
    /// old Gemma 0.35. Chosen on MIRACL (public, 11 languages: en es fr de ru
    /// fi ja zh ko ar hi; 498 judged-relevant passages) to keep the operating
    /// point Gemma shipped with: 0.81 keeps 99.2% of relevant passages (Gemma
    /// at 0.35: 99.0%) and lets 0.6% of unrelated ones through (Gemma 0.3%).
    /// Owner recordings were not used. Script: docs/ai-search/e5-swap.md.
    private let defaultThreshold: Float = 0.81

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private static let log = Logger(
        subsystem: "com.jot.Jot", category: "semantic-search"
    )

    init(container: ModelContainer) {
        self.container = container
    }

    /// Runs the semantic half for `query`. Cancels any in-flight search. The
    /// caller debounces typing; empty / whitespace / feature-off clears
    /// matches synchronously.
    func search(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, SemanticSearchSettings.isEnabled else {
            semanticMatches = []
            isSearching = false
            return
        }
        isSearching = true
        let container = self.container
        let threshold = self.defaultThreshold
        searchTask = Task { [weak self] in
            // Asymmetric prompt: chunks were indexed with `role: .document`, so
            // the query MUST use `role: .query` to land in the same space.
            guard let queryVector = try? await E5EmbeddingService.shared.encode(trimmed, role: .query) else {
                self?.isSearching = false
                return
            }
            guard !Task.isCancelled, let self else { return }
            let index = await self.currentIndex(container: container)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                index.matches(for: queryVector, threshold: threshold)
            }.value
            guard !Task.isCancelled else { return }
            self.semanticMatches = matches
            self.isSearching = false
        }
    }

    /// Convenience reset when the consuming view goes away.
    func clear() {
        searchTask?.cancel()
        semanticMatches = []
        isSearching = false
    }

    // MARK: - Vector index

    @ObservationIgnored private var index: VectorIndex?
    @ObservationIgnored private var indexBuild: Task<VectorIndex, Never>?

    /// The cached index, rebuilt off-main when the chunk table has changed.
    private func currentIndex(container: ModelContainer) async -> VectorIndex {
        let stamp = await Task.detached(priority: .userInitiated) {
            VectorIndex.Stamp.current(container: container)
        }.value
        if let index, index.stamp == stamp { return index }
        if let indexBuild {
            let built = await indexBuild.value
            if built.stamp == stamp { return built }
        }
        let build = Task.detached(priority: .userInitiated) {
            VectorIndex.build(container: container, stamp: stamp)
        }
        indexBuild = build
        let built = await build.value
        index = built
        indexBuild = nil
        Self.log.info("Search index loaded: \(built.count, privacy: .public) chunks")
        return built
    }
}

/// Flat, pre-normalised chunk vectors for one model version, plus the
/// recording each row belongs to. Immutable once built, so it is shared across
/// searches and scanned off the main actor.
struct VectorIndex: Sendable {
    /// What the index was built from; a different stamp means the chunk
    /// table changed (rows added, removed or re-embedded).
    struct Stamp: Equatable, Sendable {
        let count: Int
        let newest: Date?

        static func current(container: ModelContainer) -> Stamp {
            let context = ModelContext(container)
            let version = E5EmbeddingService.modelVersion
            let match = #Predicate<RecordingChunk> { $0.modelVersion == version }
            let count = (try? context.fetchCount(FetchDescriptor(predicate: match))) ?? 0
            var newest = FetchDescriptor(predicate: match, sortBy: [SortDescriptor(\.embeddedAt, order: .reverse)])
            newest.fetchLimit = 1
            newest.propertiesToFetch = [\.embeddedAt]
            return Stamp(count: count, newest: (try? context.fetch(newest))?.first?.embeddedAt)
        }
    }

    let stamp: Stamp
    let recordingIDs: [UUID]
    /// Row-major `count × dim`, each row unit-norm.
    let vectors: [Float]
    let dim: Int
    var count: Int { recordingIDs.count }

    static func build(container: ModelContainer, stamp: Stamp) -> VectorIndex {
        let dim = E5EmbeddingService.outputDim
        let context = ModelContext(container)
        let version = E5EmbeddingService.modelVersion
        var descriptor = FetchDescriptor<RecordingChunk>(
            predicate: #Predicate { $0.modelVersion == version }
        )
        descriptor.propertiesToFetch = [\.recordingID, \.vectorData]
        let chunks = (try? context.fetch(descriptor)) ?? []

        // Existence backstop: chunks of a recording deleted mid-index never match.
        var live = FetchDescriptor<Recording>()
        live.propertiesToFetch = [\.id]
        let liveIDs = Set(((try? context.fetch(live)) ?? []).map(\.id))

        var ids: [UUID] = []
        var flat: [Float] = []
        ids.reserveCapacity(chunks.count)
        flat.reserveCapacity(chunks.count * dim)
        for chunk in chunks where liveIDs.contains(chunk.recordingID) {
            let v = chunk.vector
            guard v.count == dim else { continue }
            var norm: Float = 0
            vDSP_svesq(v, 1, &norm, vDSP_Length(dim))
            norm = norm.squareRoot()
            guard norm.isFinite, norm > 0 else { continue }
            ids.append(chunk.recordingID)
            flat.append(contentsOf: v.map { $0 / norm })
        }
        return VectorIndex(stamp: stamp, recordingIDs: ids, vectors: flat, dim: dim)
    }

    /// Recordings whose best chunk scores at least `threshold` against `query`.
    func matches(for query: [Float], threshold: Float) -> Set<UUID> {
        guard count > 0, query.count == dim else { return [] }
        var norm: Float = 0
        vDSP_svesq(query, 1, &norm, vDSP_Length(dim))
        norm = norm.squareRoot()
        guard norm.isFinite, norm > 0 else { return [] }
        let q = query.map { $0 / norm }

        // scores (count × 1) = vectors (count × dim) · q (dim × 1)
        var scores = [Float](repeating: 0, count: count)
        vDSP_mmul(vectors, 1, q, 1, &scores, 1, vDSP_Length(count), 1, vDSP_Length(dim))

        var result = Set<UUID>()
        for i in 0..<count where scores[i] >= threshold {
            result.insert(recordingIDs[i])
        }
        return result
    }
}
