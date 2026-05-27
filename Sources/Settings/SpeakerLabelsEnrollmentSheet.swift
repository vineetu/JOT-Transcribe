import SwiftUI

/// Inline enrollment sheet for the Speaker Labels feature. Three steps:
///
/// 1. **Name.** Owner enrollment asks "What should we call your voice?";
///    collaborator enrollment asks for the collaborator's name. Re-record
///    skips this step and reuses the existing name.
/// 2. **Read the passage.** A fixed ~30-second prose passage (Mary Had a
///    Little Lamb, per plan). The user taps "Start recording," reads the
///    passage, taps "Done." Auto-stop on min duration is left to a
///    follow-up — piece A treats the Done tap as the canonical end.
/// 3. **Save.** The recorded samples are handed back to the pane via
///    `onComplete(name, isOwner, samples)`. The pane writes the row to
///    SwiftData and re-enrolls Sortformer.
///
/// Cancellation at any point returns to the pre-enrollment pane state with
/// nothing persisted.
struct SpeakerLabelsEnrollmentSheet: View {

    let target: SpeakerLabelsPane.EnrollmentTarget
    let onComplete: (_ name: String, _ isOwner: Bool, _ samples: [Float]) -> Void
    let onCancel: () -> Void

    @StateObject private var recorder = EnrollmentRecorder()
    @State private var nameDraft: String = ""
    @State private var step: Step = .name
    @State private var capturedSamples: [Float] = []

    enum Step {
        case name
        case record
        case review
    }

    private static let ownerPassage = """
        Hey! Let's teach Jot what your voice sounds like. Fun fact — the very first thing ever recorded, way back in 1877 on Edison's phonograph, was a nursery rhyme. So let's join the club. Mary had a little lamb, its fleece was white as snow. And everywhere that Mary went, the lamb was sure to go. It followed her to school one day, which was against the rule. It made the children laugh and play to see a lamb at school.
        """

    /// Plan recommends >= 15 s as the SNR/duration sanity check; piece A
    /// is permissive — the UI surfaces the read-aloud and lets the user
    /// stop when they reach the end.
    private static let minDurationSec: Double = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .onAppear { configureInitialStep() }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleText)
                .font(.title3)
                .fontWeight(.semibold)
            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .name: nameStep
        case .record: recordStep
        case .review: reviewStep
        }
    }

    @ViewBuilder
    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(namePrompt)
                .font(.system(size: 13))
            TextField("Name", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
        }
    }

    @ViewBuilder
    private var recordStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read this passage")
                .font(.system(size: 13, weight: .medium))
            ScrollView {
                Text(passageText)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)

            HStack(spacing: 12) {
                switch recorder.state {
                case .idle, .failed, .stopped:
                    // Red bordered-prominent via `.tint(.red)` so the
                    // background AND foreground render with system-managed
                    // contrast — fixes the v0 blue-background-red-icon clash.
                    Button {
                        recorder.start()
                    } label: {
                        Label("Start recording", systemImage: "record.circle.fill")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                case .recording:
                    Button {
                        finalizeRecording()
                    } label: {
                        Label("Done", systemImage: "stop.fill")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text(String(format: "%.1f s", recorder.elapsedSeconds))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if case .failed(let message) = recorder.state {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            let durationSec = Double(capturedSamples.count) / 16_000.0
            if durationSec < Self.minDurationSec {
                Label(
                    "That clip was only \(Int(durationSec)) seconds. Try again with a longer reading (about 30 seconds).",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Button("Re-record") {
                    capturedSamples = []
                    step = .record
                }
                .buttonStyle(.bordered)
            } else {
                Label("Saved \(Int(durationSec)) seconds of audio.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready to save this voice profile.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                recorder.cancel()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .name:
            Button("Continue") {
                step = .record
            }
            .keyboardShortcut(.defaultAction)
            .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)

        case .record:
            EmptyView()

        case .review:
            let durationSec = Double(capturedSamples.count) / 16_000.0
            Button("Save voice") {
                completeSave()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(durationSec < Self.minDurationSec)
        }
    }

    // MARK: - Step logic

    private func configureInitialStep() {
        switch target {
        case .owner, .collaborator:
            step = .name
        case .replace(let identity):
            nameDraft = identity.name
            step = .record
        }
    }

    private func finalizeRecording() {
        guard let samples = recorder.stop() else { return }
        capturedSamples = samples
        step = .review
    }

    private func completeSave() {
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespaces)
        let isOwner: Bool
        switch target {
        case .owner: isOwner = true
        case .collaborator: isOwner = false
        case .replace(let identity): isOwner = identity.isUser
        }
        onComplete(trimmedName, isOwner, capturedSamples)
    }

    // MARK: - Copy

    private var titleText: String {
        switch target {
        case .owner: return "Set up speaker labels"
        case .collaborator: return "Add another person"
        case .replace(let identity): return "Re-record \(identity.name)"
        }
    }

    private var subtitleText: String? {
        switch target {
        case .owner:
            return "Jot will learn your voice so it can label who said what in meeting recordings. Voice profiles stay on this Mac."
        case .collaborator:
            return "Hand the Mac to the person you want to add. Their voice profile stays on this Mac."
        case .replace:
            return "Record a fresh voice sample. Your existing one will be replaced."
        }
    }

    private var namePrompt: String {
        switch target {
        case .owner: return "What should we call your voice?"
        case .collaborator: return "What's their name?"
        case .replace: return "Name"
        }
    }

    private var passageText: String {
        switch target {
        case .owner, .replace:
            return Self.ownerPassage
        case .collaborator:
            let owner = "Jot"
            let collaborator = nameDraft.trimmingCharacters(in: .whitespaces).isEmpty
                ? "you"
                : nameDraft.trimmingCharacters(in: .whitespaces)
            return """
            Hand the Mac to \(collaborator). Their voice profile stays on this Mac.

            Hey \(collaborator)! \(owner) is teaching Jot to recognize your voice. Fun fact — the very first thing ever recorded, way back in 1877 on Edison's phonograph, was a nursery rhyme. So let's join the club. Mary had a little lamb, its fleece was white as snow. And everywhere that Mary went, the lamb was sure to go. It followed her to school one day, which was against the rule. It made the children laugh and play to see a lamb at school.
            """
        }
    }
}
