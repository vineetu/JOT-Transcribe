import Foundation

/// A completed audio capture: the in-memory Float32 mono 16 kHz buffer plus
/// the WAV file written alongside it on disk.
///
/// `samples` is what Parakeet consumes directly. `fileURL` exists so Phase 4
/// Library can persist / play back / re-transcribe recordings without us
/// having to re-encode the buffer.
public struct AudioRecording: Sendable {
    public let samples: [Float]
    public let fileURL: URL
    public let duration: TimeInterval
    public let createdAt: Date

    public init(samples: [Float], fileURL: URL, duration: TimeInterval, createdAt: Date) {
        self.samples = samples
        self.fileURL = fileURL
        self.duration = duration
        self.createdAt = createdAt
    }
}
