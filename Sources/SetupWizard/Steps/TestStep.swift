import AVFoundation
import SwiftUI

/// Step 6 — end-to-end smoke test. Records 3 seconds, transcribes, shows what
/// was heard. Uses a dedicated `AudioCapture` so the test does NOT kick
/// delivery / paste / library-persistence pipelines, but reuses the recorder's
/// shared `Transcriber` (injected into the coordinator) so the ANE warm-up
/// performed here carries over — otherwise the first post-wizard hotkey press
/// hits a cold `AsrManager` and sits in "still loading" until relaunch.
struct TestStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @AppStorage("jot.defaultModelID") private var defaultModelID: String = ParakeetModelID.tdt_0_6b_v3.rawValue

    @State private var phase: TestPhase = .idle
    @State private var transcript: String = ""
    @State private var errorMessage: String?

    private var selectedModel: ParakeetModelID {
        ParakeetModelID(rawValue: defaultModelID) ?? .tdt_0_6b_v3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try it out")
                    .font(.system(size: 22, weight: .semibold))
                Text("Tap to record a short test. Jot will capture three seconds of audio and show what it heard.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            remediationBanner

            HStack {
                Spacer()
                TestButton(phase: phase, action: runTest)
                Spacer()
            }

            transcriptBlock

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { updateChrome() }
        .onChange(of: phase) { updateChrome() }
    }

    // MARK: - Banner

    @ViewBuilder
    private var remediationBanner: some View {
        let mic = PermissionsService.shared.statuses[.microphone] == .granted
        let modelReady = ModelCache.shared.isCached(selectedModel)
        if !mic || !modelReady {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(!mic ? "Microphone permission is not granted." : "Model isn't downloaded yet.")
                        .font(.system(size: 12, weight: .semibold))
                    Button(!mic ? "Go back to Permissions" : "Go back to Model") {
                        coordinator.goTo(!mic ? .permissions : .model)
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptBlock: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .recording:
            Text("Listening…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                Text("You said:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(transcript.isEmpty ? "(nothing recognized)" : transcript)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
                HStack {
                    Button("Try again") { runTest() }
                        .controlSize(.small)
                    Spacer()
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(errorMessage ?? "Test failed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { runTest() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Coordinator chrome

    private func updateChrome() {
        coordinator.setChrome(WizardStepChrome(
            primaryTitle: "Continue",
            canAdvance: true,
            isPrimaryBusy: false,
            showsSkip: false
        ))
    }

    // MARK: - Test run

    private func runTest() {
        guard phase != .recording && phase != .transcribing else { return }
        transcript = ""
        errorMessage = nil
        phase = .recording

        let transcriber = coordinator.transcriber
        Task {
            let capture = AudioCapture()
            do {
                try await transcriber.ensureLoaded()
                try await capture.start()
                try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                let recording = try await capture.stop()
                await MainActor.run { phase = .transcribing }
                let result = try await transcriber.transcribe(recording.samples)
                await MainActor.run {
                    transcript = result.text
                    coordinator.testTranscript = result.text
                    phase = .done
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Test failed: \(error.localizedDescription)"
                    phase = .failed
                }
            }
        }
    }
}

fileprivate enum TestPhase: Equatable {
    case idle
    case recording
    case transcribing
    case done
    case failed
}

private struct TestButton: View {
    let phase: TestPhase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: 96, height: 96)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .recording || phase == .transcribing)
        .help(tooltip)
    }

    private var background: Color {
        switch phase {
        case .idle, .done, .failed: return .accentColor
        case .recording: return .red
        case .transcribing: return Color.accentColor.opacity(0.7)
        }
    }

    private var symbol: String {
        switch phase {
        case .idle, .done, .failed: return "mic.fill"
        case .recording: return "stop.fill"
        case .transcribing: return "waveform"
        }
    }

    private var tooltip: String {
        switch phase {
        case .idle: return "Record 3 seconds"
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .done: return "Run again"
        case .failed: return "Try again"
        }
    }
}

