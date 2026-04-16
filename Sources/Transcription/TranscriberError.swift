import Foundation

/// Errors surfaced from the Transcription layer.
///
/// `busy` is the single-in-flight guard — used by RecorderController to
/// refuse overlapping transcription requests rather than queueing them.
/// `fluidAudio` wraps anything the SDK throws so upstream types stay at
/// Jot's boundary.
public enum TranscriberError: Error, Sendable {
    case busy
    case modelNotLoaded
    case modelMissing
    case audioTooShort
    case fluidAudio(Error)
}
