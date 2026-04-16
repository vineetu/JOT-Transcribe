import Foundation

/// Output of a single transcription pass.
///
/// `rawText` is the model's output before Jot's `PostProcessing` runs —
/// preserved so a future "re-apply post-processing" operation (e.g. after a
/// custom-vocabulary edit) doesn't need to rerun the model.
/// `text` is the user-facing version — post-processing applied.
public struct TranscriptionResult: Sendable {
    public let text: String
    public let rawText: String
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let confidence: Float

    public init(
        text: String,
        rawText: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        confidence: Float
    ) {
        self.text = text
        self.rawText = rawText
        self.duration = duration
        self.processingTime = processingTime
        self.confidence = confidence
    }
}
