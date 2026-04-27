import Foundation

/// OS-boundary seam for microphone capture. The live conformer is
/// `AudioCapture` (actor-backed `AVAudioEngine` tap → 16 kHz mono Float32
/// samples + on-disk WAV); the harness conformer in
/// `Tests/JotHarness/` plays back fixture `.wav` data without touching
/// CoreAudio.
///
/// The four methods mirror `AudioCapture`'s existing public surface
/// verbatim; this protocol carries no behavior, only the shape that
/// `JotComposition.build` injects and `VoiceInputPipeline` consumes.
///
/// `Sendable` because conformers cross actor isolation domains —
/// `AudioCapture` is itself an actor (implicitly `Sendable`), and
/// `VoiceInputPipeline` is `@MainActor` while reading the seam.
protocol AudioCapturing: Sendable {
    /// Begin a recording session. Throws `AudioCaptureError` on engine
    /// failure / timeout / file-create failure / converter unavailable.
    func start() async throws

    /// Stop the current session and return the captured audio. Throws
    /// `AudioCaptureError.notRunning` if no session is active.
    func stop() async throws -> AudioRecording

    /// Abort the current session and discard the on-disk WAV. Idempotent
    /// — safe to call when no session is active.
    func cancel() async

    /// Hand the seam a publisher to receive ~10 Hz RMS amplitude values
    /// during recording. Pass `nil` to detach.
    func setAmplitudePublisher(_ publisher: AmplitudePublisher?) async
}
