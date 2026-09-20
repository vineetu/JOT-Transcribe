import Foundation

/// The five chimes Jot plays in response to recorder / delivery state changes.
///
/// Each case pairs a bundled WAV filename with its user-facing `@AppStorage`
/// toggle key. Settings and `SoundPlayer` read the same keys so they stay in
/// sync — if the user flips "Recording start" off in Settings, playback
/// respects it immediately without a restart.
enum SoundEffect: String, CaseIterable, Sendable {
    case recordingStart
    case rewriteStart
    case recordingStop
    case recordingCancel
    case transcriptionComplete
    case error

    /// Bundled filename (WAV, `Resources/Sounds/`). Extension is stripped
    /// because `Bundle.url(forResource:withExtension:)` prefers that shape.
    /// `rewriteStart`'s asset filename is preserved as `articulate-start`
    /// to avoid renaming the bundled WAV resource.
    var fileName: String {
        switch self {
        case .recordingStart: return "recording-start"
        case .rewriteStart: return "articulate-start"
        case .recordingStop: return "recording-stop"
        case .recordingCancel: return "recording-cancel"
        case .transcriptionComplete: return "transcription-complete"
        case .error: return "error"
        }
    }

    /// Bundled filename for `theme`, or the stock filename when the theme has
    /// no chime set of its own.
    ///
    /// Theme chimes are flat, distinctly-named files (`theme-<id>-recording-start`)
    /// because `Bundle.url(forResource:withExtension:)` searches a **flat**
    /// namespace — resources from `Sources/` subfolders are copied to the top
    /// level of `Contents/Resources`, so a same-named file in a subfolder would
    /// collide with the stock chime rather than sit beside it.
    func fileName(for theme: JotTheme) -> String {
        guard let prefix = theme.soundPrefix else { return fileName }
        return "\(prefix)-\(fileName)"
    }

    /// `@AppStorage` key Settings writes. Used by `SoundPlayer` to gate
    /// playback so a muted effect is silent even if triggered.
    /// `rewriteStart`'s key is preserved as `jot.sound.articulateStart`
    /// so users' existing chime preference survives the rename.
    var settingsKey: String {
        switch self {
        case .recordingStart: return "jot.sound.recordingStart"
        case .rewriteStart: return "jot.sound.articulateStart"
        case .recordingStop: return "jot.sound.recordingStop"
        case .recordingCancel: return "jot.sound.recordingCancel"
        case .transcriptionComplete: return "jot.sound.transcriptionComplete"
        case .error: return "jot.sound.error"
        }
    }
}
