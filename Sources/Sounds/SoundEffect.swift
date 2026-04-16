import Foundation

/// The five chimes Jot plays in response to recorder / delivery state changes.
///
/// Each case pairs a bundled WAV filename with its user-facing `@AppStorage`
/// toggle key. Settings and `SoundPlayer` read the same keys so they stay in
/// sync — if the user flips "Recording start" off in Settings, playback
/// respects it immediately without a restart.
enum SoundEffect: String, CaseIterable, Sendable {
    case recordingStart
    case recordingStop
    case recordingCancel
    case transcriptionComplete
    case error

    /// Bundled filename (WAV, `Resources/Sounds/`). Extension is stripped
    /// because `Bundle.url(forResource:withExtension:)` prefers that shape.
    var fileName: String {
        switch self {
        case .recordingStart: return "recording-start"
        case .recordingStop: return "recording-stop"
        case .recordingCancel: return "recording-cancel"
        case .transcriptionComplete: return "transcription-complete"
        case .error: return "error"
        }
    }

    /// `@AppStorage` key Settings writes. Used by `SoundPlayer` to gate
    /// playback so a muted effect is silent even if triggered.
    var settingsKey: String {
        switch self {
        case .recordingStart: return "jot.sound.recordingStart"
        case .recordingStop: return "jot.sound.recordingStop"
        case .recordingCancel: return "jot.sound.recordingCancel"
        case .transcriptionComplete: return "jot.sound.transcriptionComplete"
        case .error: return "jot.sound.error"
        }
    }
}
