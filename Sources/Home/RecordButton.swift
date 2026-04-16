import SwiftUI

/// The 88 pt mic disc on the Home view. Drives `RecorderController.toggle()`
/// and mirrors the recorder's state as fill color + outer-ring pulse.
struct RecordButton: View {
    @EnvironmentObject private var recorder: RecorderController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPulsing = false

    private var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    private var isTranscribing: Bool {
        if case .transcribing = recorder.state { return true }
        return false
    }

    var body: some View {
        Button(action: tap) {
            ZStack {
                pulseRing
                Circle()
                    .fill(fillColor)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                Image(systemName: symbolName)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(iconColor)
                    .symbolRenderingMode(.monochrome)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeInOut(duration: 0.14), value: isRecording)
        .animation(.easeInOut(duration: 0.14), value: isTranscribing)
        .onChange(of: isRecording) { _, recording in
            if recording, !reduceMotion {
                isPulsing = true
            } else {
                isPulsing = false
            }
        }
    }

    @ViewBuilder
    private var pulseRing: some View {
        if isRecording, !reduceMotion {
            Circle()
                .stroke(Color(nsColor: .systemRed), lineWidth: 2)
                .frame(width: 88, height: 88)
                .scaleEffect(isPulsing ? 1.2 : 1.0)
                .opacity(isPulsing ? 0.0 : 0.6)
                .animation(
                    .easeOut(duration: 0.9).repeatForever(autoreverses: false),
                    value: isPulsing
                )
        }
    }

    private var fillColor: Color {
        if isRecording { return Color(nsColor: .systemRed) }
        if isTranscribing { return Color.accentColor.opacity(0.25) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var iconColor: Color {
        if isRecording { return .white }
        if isTranscribing { return .accentColor }
        return .primary
    }

    private var symbolName: String {
        if isTranscribing { return "waveform" }
        return "mic.fill"
    }

    private var accessibilityLabel: String {
        if isRecording { return "Stop recording" }
        if isTranscribing { return "Transcribing" }
        return "Start recording"
    }

    private func tap() {
        Task { await recorder.toggle() }
    }
}
