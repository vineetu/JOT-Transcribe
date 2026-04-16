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

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        title: String,
        durationSeconds: Double,
        transcript: String,
        rawTranscript: String,
        audioFileName: String,
        modelIdentifier: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.rawTranscript = rawTranscript
        self.audioFileName = audioFileName
        self.modelIdentifier = modelIdentifier
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
