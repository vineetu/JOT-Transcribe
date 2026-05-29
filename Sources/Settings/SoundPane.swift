import SwiftUI

/// v1.14: the Sound pane is no longer reachable from the sidebar
/// (`AppSidebar` removed the entry; `JotAppWindow.sanitize` redirects
/// `.settings(.sound)` to `.general`). The pane is left in the project
/// so the per-event toggles persisted under their `@AppStorage` keys
/// still bind to real defaults, and so any future re-introduction can
/// reuse the layout without reconstructing it from scratch.
struct SoundPane: View {
    @AppStorage("jot.sound.recordingStart") private var recordingStart: Bool = true
    @AppStorage("jot.sound.articulateStart") private var rewriteStart: Bool = true
    @AppStorage("jot.sound.recordingStop") private var recordingStop: Bool = true
    @AppStorage("jot.sound.recordingCancel") private var recordingCancel: Bool = true
    @AppStorage("jot.sound.transcriptionComplete") private var transcriptionComplete: Bool = true
    @AppStorage("jot.sound.error") private var errorSound: Bool = true
    @AppStorage("jot.sound.volume") private var volume: Double = 0.7

    var body: some View {
        Form {
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
                        helpAnchor: "sound-recording-chimes"
                    )
                }
                Text("Applies to all Jot chimes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                chimeRow("Recording start", isOn: $recordingStart, effect: .recordingStart,
                         help: "Play a chime when recording begins.",
                         popoverBody: "A short chime confirms Jot heard your hotkey. When on: you get audible feedback the moment capture starts, without needing to look at the menu bar.",
                         helpAnchor: "sound-recording-chimes")
                chimeRow("Rewrite start", isOn: $rewriteStart, effect: .rewriteStart,
                         help: "Play a chime when a Rewrite with Voice instruction begins.",
                         popoverBody: "A distinct chime — pitch-shifted from the dictation start chime — plays when Rewrite with Voice opens the mic for your voice instruction. When on: you can hear the difference between a dictation session and a Rewrite without looking at the menu bar.",
                         helpAnchor: "sound-recording-chimes")
                chimeRow("Recording stop", isOn: $recordingStop, effect: .recordingStop,
                         help: "Play a chime when recording stops and transcription starts.",
                         popoverBody: "Plays when recording ends and Jot hands off to the transcription model. When on: you know capture finished before transcription latency kicks in.",
                         helpAnchor: "sound-recording-chimes")
                chimeRow("Recording canceled", isOn: $recordingCancel, effect: .recordingCancel,
                         help: "Play a chime when you cancel a recording with Escape.",
                         popoverBody: "A distinct chime that signals Jot dropped the recording. When on: you get clear auditory confirmation that nothing was transcribed or delivered.",
                         helpAnchor: "sound-recording-chimes")
                chimeRow("Transcription complete", isOn: $transcriptionComplete, effect: .transcriptionComplete,
                         help: "Play a chime when the transcript is ready and delivered.",
                         popoverBody: "Plays when the transcript is pasted (or copied, if auto-paste is off). When on: you can look away from the screen and still know delivery succeeded.",
                         helpAnchor: "sound-transcription-complete")
                chimeRow("Error", isOn: $errorSound, effect: .error,
                         help: "Play a chime when transcription fails.",
                         popoverBody: "A distinct error chime plays when transcription or delivery fails. When on: failures surface immediately instead of silently dropping.",
                         helpAnchor: "sound-error-chime")
            }
        }
        .formStyle(.grouped)
    }

    private func chimeRow(_ label: String, isOn: Binding<Bool>, effect: SoundEffect, help: String, popoverBody: String, helpAnchor: String) -> some View {
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
                helpAnchor: helpAnchor
            )
        }
    }
}
