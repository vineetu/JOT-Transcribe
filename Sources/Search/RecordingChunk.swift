import Foundation
import SwiftData

/// One chunk of a `Recording`'s transcript for the semantic-search retrieval
/// pipeline. Ported from jot-mobile's `TranscriptChunk`
/// (`jot-mobile/Jot/Shared/Schema/JotSchemaV7.swift`); the join field is renamed
/// `transcriptID` → `recordingID` to match macOS Jot's `Recording` model.
///
/// A transcript is split into ~110-token windows (`TranscriptChunker`); each
/// window gets its own 256-d EmbeddingGemma vector so a specific idea inside a
/// long recording is retrievable (vs. a blurry whole-transcript average).
///
/// ## Storage
/// `vectorData` packs 256 IEEE-754 little-endian float32s. `modelVersion` is the
/// discriminator (e.g. `"embeddinggemma-300m-256"`). A model swap writes rows
/// under a new `modelVersion`; readers filter by the current version, so stale
/// vectors never poison retrieval.
///
/// ## Logical join (NOT `@Relationship`)
/// `recordingID` is a plain `UUID` copy of `Recording.id`, not a SwiftData
/// relationship — chunks are re-buildable independent of the parent's lifecycle,
/// and there is **no `@Attribute(.unique)`** on the join key (lightweight
/// migration on a new-entity unique constraint is inconsistent across OS
/// versions). Replace semantics are delete-then-insert per
/// `(recordingID, modelVersion)`.
///
/// ## Denormalized parent fields
/// `createdAt` / `durationSeconds` are stamped from the parent `Recording` at
/// index time so a future retrieval pre-filter (date / duration) can scope the
/// chunk pool in a single fetch without a per-chunk `Recording` join.
@Model
final class RecordingChunk {
    @Attribute(.unique) var id: UUID
    var recordingID: UUID
    var chunkIndex: Int
    var text: String
    var vectorData: Data
    var charStart: Int
    var charEnd: Int
    var modelVersion: String
    var embeddedAt: Date

    // Denormalized parent-recording metadata (see doc above).
    var createdAt: Date
    var durationSeconds: Double?

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        chunkIndex: Int,
        text: String,
        vectorData: Data,
        charStart: Int,
        charEnd: Int,
        modelVersion: String,
        embeddedAt: Date = Date(),
        createdAt: Date,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.recordingID = recordingID
        self.chunkIndex = chunkIndex
        self.text = text
        self.vectorData = vectorData
        self.charStart = charStart
        self.charEnd = charEnd
        self.modelVersion = modelVersion
        self.embeddedAt = embeddedAt
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
    }
}

extension RecordingChunk {
    /// Unpacks `vectorData` (little-endian packed float32) into `[Float]`.
    /// Mirrors the packing in `ChunkStore.replaceChunks`.
    var vector: [Float] {
        vectorData.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }
}
