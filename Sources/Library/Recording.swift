import Foundation
import SwiftData

/// Persisted record of a single dictation pass. Audio is stored on disk (the
/// WAV written by `AudioCapture`) and referenced by filename only so the
/// Application Support directory remains the source of truth for audio.
///
/// The unique `id` doubles as the identity key SwiftData uses for updates and
/// as the key the UI binds to — safe because `UUID` is both stable and
/// collision-resistant.
@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var title: String
    var durationSeconds: Double
    var transcript: String
    var rawTranscript: String
    var audioFileName: String
    var modelIdentifier: String

    /// Speaker Labels piece A: JSON-encoded array of
    /// `{speakerID, startSec, endSec, text}` segments. Populated only when
    /// Speaker Labels were on at recording time AND Sortformer detected
    /// more than one speaker (Decision #13's solo-recording detect-and-skip
    /// — solo recordings keep this `nil` and remain indistinguishable from
    /// pre-feature recordings).
    var speakerTimeline: Data?

    /// User-curated tags (chips), independent of the transcript text. Stored
    /// canonicalized (trimmed, leading `#` stripped, lowercased, single-token)
    /// so dedupe is exact — see `TagChipsEditor.normalize`. Default `[]` makes
    /// this an additive SwiftData lightweight migration (no `VersionedSchema` —
    /// an explicit migration plan would BREAK additive-default migration on a
    /// never-versioned store; see docs/transcript-editing-tags/design.md).
    var tags: [String] = []

    /// Set when the user hand-edits the transcript in the detail view. Purely
    /// informational (drives a subtle "edited" affordance); the immutable
    /// `rawTranscript` + the "Show original" toggle remain the recovery path.
    /// Optional default `nil` = unconditionally-safe additive migration.
    var editedAt: Date?

    /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
    /// Non-nil = the audio is saved to disk but the transcript is empty and
    /// still needs a (re)transcription pass — set when a recorder dictation's
    /// or a file import's transcription failed (busy engine, model error,
    /// crash) after the audio was already finalized, or when the startup
    /// orphan scan adopts a WAV/m4a with no `Recording` row. Cleared by the
    /// existing re-transcribe flow once it fills in the transcript. Optional
    /// default `nil` = unconditionally-safe additive migration, same pattern
    /// as `editedAt` above.
    var pendingSince: Date?

    /// AI summary (recording-detail "Summarize" feature). The generated text, the
    /// `SummaryKind.rawValue` that produced it, and when it was generated —
    /// overwritten each time the user picks a summary action or regenerates.
    /// Each optional-default-`nil` = unconditionally-safe additive SwiftData
    /// lightweight migration (same never-versioned pattern as `editedAt` /
    /// `pendingSince` above — no `VersionedSchema`).
    var summaryText: String?
    var summaryKind: String?
    var summaryGeneratedAt: Date?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        title: String,
        durationSeconds: Double,
        transcript: String,
        rawTranscript: String,
        audioFileName: String,
        modelIdentifier: String,
        speakerTimeline: Data? = nil,
        tags: [String] = [],
        editedAt: Date? = nil,
        pendingSince: Date? = nil,
        summaryText: String? = nil,
        summaryKind: String? = nil,
        summaryGeneratedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.rawTranscript = rawTranscript
        self.audioFileName = audioFileName
        self.modelIdentifier = modelIdentifier
        self.speakerTimeline = speakerTimeline
        self.tags = tags
        self.editedAt = editedAt
        self.pendingSince = pendingSince
        self.summaryText = summaryText
        self.summaryKind = summaryKind
        self.summaryGeneratedAt = summaryGeneratedAt
    }
}

extension Recording {
    /// Best-guess title from a fresh transcript: first 40 chars, trimmed, or a
    /// placeholder if the transcript is empty.
    static func defaultTitle(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Untitled recording" }
        if trimmed.count <= 40 { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: 40)
        return String(trimmed[..<idx]).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `m:ss` style duration — matches what the list and detail render.
    var formattedDuration: String {
        let total = Int(durationSeconds.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
