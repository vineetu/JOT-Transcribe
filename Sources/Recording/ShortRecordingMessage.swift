import Foundation

/// Builds the user-facing error string when Parakeet rejects a recording as
/// too short. If wall-clock elapsed > 1 s but captured audio is under 30 %
/// of that, the microphone is almost certainly being redirected (common on
/// macOS when a Bluetooth audio device is connected), so surface that hint
/// instead of the generic "Recording was too short."
public func shortRecordingMessage(
    for recording: AudioRecording,
    now: Date = Date()
) -> String {
    let wallClock = now.timeIntervalSince(recording.createdAt)
    let captured = recording.duration

    if wallClock > 1.0, captured / wallClock < 0.3 {
        let cap = String(format: "%.1f", captured)
        let wall = String(format: "%.1f", wallClock)
        return "Jot captured only \(cap)s from \(wall)s of speech. A connected Bluetooth audio device may be redirecting the microphone — disconnect it or pick a specific input in Settings → General → Input device."
    }

    return "Recording was too short."
}
