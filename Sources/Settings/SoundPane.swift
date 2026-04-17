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
                         help: "Play a chime when recording begins.",
                         popoverBody: "A short chime confirms Jot heard your hotkey. When on: you get audible feedback the moment capture starts, without needing to look at the menu bar.")
                chimeRow("Recording stop", isOn: $recordingStop, effect: .recordingStop,
                         help: "Play a chime when recording stops and transcription starts.",
                         popoverBody: "Plays when recording ends and Jot hands off to the transcription model. When on: you know capture finished before transcription latency kicks in.")
                chimeRow("Recording canceled", isOn: $recordingCancel, effect: .recordingCancel,
                         help: "Play a chime when you cancel a recording with Escape.",
                         popoverBody: "A distinct chime that signals Jot dropped the recording. When on: you get clear auditory confirmation that nothing was transcribed or delivered.")
                chimeRow("Transcription complete", isOn: $transcriptionComplete, effect: .transcriptionComplete,
                         help: "Play a chime when the transcript is ready and delivered.",
                         popoverBody: "Plays when the transcript is pasted (or copied, if auto-paste is off). When on: you can look away from the screen and still know delivery succeeded.")
                chimeRow("Error", isOn: $errorSound, effect: .error,
                         help: "Play a chime when transcription fails.",
                         popoverBody: "A distinct error chime plays when transcription or delivery fails. When on: failures surface immediately instead of silently dropping.")
            }

            Section {
                HStack {
                    Label("Volume", systemImage: "speaker.wave.1")
                        .labelStyle(.titleOnly)
                    Slider(value: $volume, in: 0...1)
                    Image(systemName: "speaker.wave.3")
                        .foregroundStyle(.secondary)
                    InfoPopoverButton(
                        title: "Chime volume",
                        body: "Controls the loudness of every Jot chime relative to your system output. Applies uniformly to start, stop, cancel, complete, and error sounds.",
                        helpAnchor: "help.sound.chimes"
                    )
                }
                Text("Applies to all Jot chimes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chimeRow(_ label: String, isOn: Binding<Bool>, effect: SoundEffect, help: String, popoverBody: String) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
                .help(help)
            Spacer()
            Button("Test") { SoundPlayer.shared.play(effect) }
                .controlSize(.small)
                .disabled(!isOn.wrappedValue)
            InfoPopoverButton(
                title: label,
                body: popoverBody,
                helpAnchor: "help.sound.chimes"
            )
        }
    }
}
