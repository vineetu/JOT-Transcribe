import SwiftUI

/// Makes the shared `Transcriber` actor available to SwiftUI views without
/// piping it through EnvironmentObject (which requires an ObservableObject).
/// Re-transcribe actions in the Library read it off the environment.
private struct TranscriberEnvironmentKey: EnvironmentKey {
    static let defaultValue: Transcriber? = nil
}

extension EnvironmentValues {
    var transcriber: Transcriber? {
        get { self[TranscriberEnvironmentKey.self] }
        set { self[TranscriberEnvironmentKey.self] = newValue }
    }
}
