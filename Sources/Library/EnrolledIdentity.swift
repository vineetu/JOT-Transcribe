import Foundation
import SwiftData

/// A voice identity enrolled for the Speaker Labels feature. One per person
/// the user wants Jot to recognize and label by name (default device owner
/// plus up to 3 collaborators per plan Decision #7).
///
/// `voiceClips` is `[Data]` — each element is a `[Float]` 16 kHz mono audio
/// buffer encoded via `withUnsafeBytes`. v1.14 piece A ships with exactly
/// one clip per identity (the ~30 s prose-reading enrollment); the array
/// shape leaves room for multi-mic robustness clips in a later release
/// without requiring a SwiftData migration.
///
/// Concurrency: all writes happen on the `@MainActor` against
/// `modelContainer.mainContext`, matching existing `Recording` / `UserPrompt`
/// patterns.
@Model
final class EnrolledIdentity {
    @Attribute(.unique) var id: UUID

    /// Human-readable display name (e.g. "Vineet", "Alex"). Free-form
    /// because the enrollment flow lets the user type whatever they want.
    var name: String

    /// `true` for the device-owner identity created at the start of
    /// enrollment. Exactly one identity per user should have this set.
    var isUser: Bool

    /// One ~30 s 16 kHz mono Float32 clip per array entry, encoded as
    /// `Data` via `withUnsafeBytes`. v1.14 ships with exactly one element;
    /// `voiceClips: [Data]` future-proofs the schema for multi-mic clips.
    var voiceClips: [Data]

    /// When the user finished enrollment for this identity. Used purely
    /// for display in Settings → Speaker Labels rows.
    var enrolledAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        isUser: Bool,
        voiceClips: [Data],
        enrolledAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.isUser = isUser
        self.voiceClips = voiceClips
        self.enrolledAt = enrolledAt
    }
}

extension EnrolledIdentity {

    /// Encode a `[Float]` audio buffer as `Data` for storage in
    /// `voiceClips`. Native byte order — the buffer is read back on the
    /// same machine that wrote it, so endianness conversion is unnecessary.
    static func encode(samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    /// Decode a `Data` blob back into a `[Float]` audio buffer.
    static func decode(clip: Data) -> [Float] {
        let count = clip.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return clip.withUnsafeBytes { raw -> [Float] in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: count))
        }
    }

    /// Convenience: the first stored clip decoded as `[Float]`, suitable
    /// for handing to `enrollSpeaker(withAudio:)`. Returns `nil` when no
    /// clips are present.
    var primarySamples: [Float]? {
        guard let first = voiceClips.first else { return nil }
        return Self.decode(clip: first)
    }
}

/// Hard cap on identities (1 owner + 3 collaborators). Matches Sortformer's
/// per-recording slot cap. UI enforces; SwiftData does not constrain.
enum SpeakerLabelsConstants {
    static let identityCap = 4
}
