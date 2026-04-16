import SwiftUI

struct SoundPane: View {
    @AppStorage("jot.sound.recordingStart") private var recordingStart: Bool = true
    @AppStorage("jot.sound.recordingStop") private var recordingStop: Bool = true
    @AppStorage("jot.sound.recordingCancel") private var recordingCancel: Bool = true
    @AppStorage("jot.sound.transcriptionComplete") private var transcriptionComplete: Bool = true
    @AppStorage("jot.sound.error") private var errorSound: Bool = true
    @AppStorage("jot.sound.volume") private var volume: Double = 0.7

    var body: some View {
        Form {
            Section {
                chimeRow("Recording start", isOn: $recordingStart, effect: .recordingStart)
                chimeRow("Recording stop", isOn: $recordingStop, effect: .recordingStop)
                chimeRow("Recording canceled", isOn: $recordingCancel, effect: .recordingCancel)
                chimeRow("Transcription complete", isOn: $transcriptionComplete, effect: .transcriptionComplete)
                chimeRow("Error", isOn: $errorSound, effect: .error)
            }

            Section {
                HStack {
                    Label("Volume", systemImage: "speaker.wave.1")
                        .labelStyle(.titleOnly)
                    Slider(value: $volume, in: 0...1)
                    Image(systemName: "speaker.wave.3")
                        .foregroundStyle(.secondary)
                }
                Text("Applies to all Jot chimes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chimeRow(_ label: String, isOn: Binding<Bool>, effect: SoundEffect) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
            Spacer()
            Button("Test") { SoundPlayer.shared.play(effect) }
                .controlSize(.small)
                .disabled(!isOn.wrappedValue)
        }
    }
}
