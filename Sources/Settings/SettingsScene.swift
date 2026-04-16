import SwiftUI

struct JotSettings: Scene {
    var body: some Scene {
        Settings {
            TabView {
                GeneralPane()
                    .tabItem { Label("General", systemImage: "gearshape") }
                TranscriptionPane()
                    .tabItem { Label("Transcription", systemImage: "waveform") }
                SoundPane()
                    .tabItem { Label("Sound", systemImage: "speaker.wave.2") }
                ShortcutsPane()
                    .tabItem { Label("Shortcuts", systemImage: "command") }
            }
            .frame(width: 560, height: 420)
        }
    }
}
