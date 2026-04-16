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
                chimeRow("Recording start", isOn: $recordingStart, effect: .recordingStart,
                         help: "Play a chime when recording begins.")
                chimeRow("Recording stop", isOn: $recordingStop, effect: .recordingStop,
                         help: "Play a chime when recording stops and transcription starts.")
                chimeRow("Recording canceled", isOn: $recordingCancel, effect: .recordingCancel,
                         help: "Play a chime when you cancel a recording with Escape.")
                chimeRow("Transcription complete", isOn: $transcriptionComplete, effect: .transcriptionComplete,
                         help: "Play a chime when the transcript is ready and delivered.")
                chimeRow("Error", isOn: $errorSound, effect: .error,
                         help: "Play a chime when transcription fails.")
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

    private func chimeRow(_ label: String, isOn: Binding<Bool>, effect: SoundEffect, help: String) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
                .help(help)
            Spacer()
            Button("Test") { SoundPlayer.shared.play(effect) }
                .controlSize(.small)
                .disabled(!isOn.wrappedValue)
        }
    }
}
