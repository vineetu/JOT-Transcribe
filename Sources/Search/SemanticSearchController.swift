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
/// Substring matches surface instantly on keystroke; the semantic set fills in
/// ~250-400 ms later (200 ms debounce + ~40 ms query embed + ~15 ms cosine scan).
///
/// ## Chunk-based retrieval
/// Each recording is split into chunks at index time; every chunk gets its own
/// 256-d unit-norm Gemma vector (`role: .document`). At search time the query is
/// embedded with `role: .query` (asymmetric prompt) and scored against every
/// chunk. A recording matches if ANY of its chunks clears the threshold; we dedup
/// to the single best-scoring chunk per recording.
///
/// ## Graceful degradation
/// If EmbeddingGemma fails to load (missing/corrupt model, or feature off),
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

    /// Cosine cutoff. Higher = more precise, fewer results. Mobile shipped 0.50
    /// (English-primary), but the macOS multilingual sweep (2026-06-20, 13
    /// languages) showed correct #1-ranked matches in Spanish/French/etc. score
    /// 0.34–0.49 — a 0.50 gate silently drops them. Lowered to 0.35 to retain the
    /// proven-correct non-English matches; ranking/dedup keep noise bounded.
    /// (English typically clears 0.45+, so this mainly rescues other languages.)
    private let defaultThreshold: Float = 0.35

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private static let log = Logger(
        subsystem: "com.jot.Jot", category: "semantic-search"
    )

    init(container: ModelContainer) {
        self.container = container
    }

    /// Updates the search query. Cancels any in-flight task, debounces ~200 ms,
    /// then embeds + matches. Empty / whitespace / feature-off clears matches
    /// synchronously.
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
            // Debounce — keystroke storms shouldn't spawn one embed per stroke.
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            // Asymmetric prompt: chunks were indexed with `role: .document`, so
            // the query MUST use `role: .query` to land in the same space.
            guard let queryVector = try? await EmbeddingGemmaService.shared.encode(trimmed, role: .query) else {
                await MainActor.run { self?.isSearching = false }
                return
            }
            if Task.isCancelled { return }
            let matches = await Self.findMatches(
                queryVector: queryVector,
                threshold: threshold,
                container: container
            )
            if Task.isCancelled { return }
            await MainActor.run {
                self?.semanticMatches = matches
                self?.isSearching = false
            }
        }
    }

    /// Convenience reset when the consuming view goes away.
    func clear() {
        searchTask?.cancel()
        semanticMatches = []
        isSearching = false
    }

    // MARK: - Cosine scan

    @MainActor
    private static func findMatches(
        queryVector: [Float],
        threshold: Float,
        container: ModelContainer
    ) async -> Set<UUID> {
        let normalizedQuery = normalize(queryVector)
        guard !normalizedQuery.isEmpty else { return [] }

        // Version-scope the pool so stale vectors from a prior model can't match.
        let chunks = ChunkStore.allChunks(
            modelVersion: EmbeddingGemmaService.modelVersion,
            container: container
        )
        guard !chunks.isEmpty else { return [] }

        // Both query and chunk vectors are unit-norm out of Gemma (cosine == dot);
        // we defensively re-normalize so a stray blob can't poison the score.
        var bestByRecording: [UUID: Float] = [:]
        for chunk in chunks {
            let vector = chunk.vector
            guard vector.count == normalizedQuery.count else { continue }
            let normalizedRow = normalize(vector)
            guard !normalizedRow.isEmpty else { continue }
            let cosine = dot(normalizedQuery, normalizedRow)
            guard cosine >= threshold else { continue }
            let id = chunk.recordingID
            if let existing = bestByRecording[id] {
                if cosine > existing { bestByRecording[id] = cosine }
            } else {
                bestByRecording[id] = cosine
            }
        }
        return Set(bestByRecording.keys)
    }

    // MARK: - Math

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
