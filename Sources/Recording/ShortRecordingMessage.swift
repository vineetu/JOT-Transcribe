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
    if shortRecordingLooksLikeMicRedirect(for: recording, now: now) {
        let cap = String(format: "%.1f", recording.duration)
        let wall = String(format: "%.1f", now.timeIntervalSince(recording.createdAt))
        return "Jot captured only \(cap)s from \(wall)s of speech. A connected Bluetooth audio device may be redirecting the microphone — disconnect it or pick a specific input in Settings → General → Input device."
    }

    return "Recording was too short."
}

/// True when a rejected-as-too-short recording carries the mic-redirect
/// signature described above: real wall-clock time elapsed, but almost no
/// audio arrived.
///
/// Split out because callers that otherwise read "too short" as "the user said
/// nothing" — and quietly fall back — must NOT do so here. In this case the
/// user did speak; a silent fallback would hide a broken microphone behind a
/// result they didn't ask for, so these callers keep surfacing the diagnostic.
public func shortRecordingLooksLikeMicRedirect(
    for recording: AudioRecording,
    now: Date = Date()
) -> Bool {
    let wallClock = now.timeIntervalSince(recording.createdAt)
    guard wallClock > 1.0 else { return false }
    return recording.duration / wallClock < 0.3
}
