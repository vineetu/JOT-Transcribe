import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Landing view for the unified Jot window — "Recents."
///
/// v1.14: stripped of the Basics banner and the leftover "Press X to
/// dictate" glance line. The single primary affordance is the blue
/// Record pill above the list. The list itself is flat (no date
/// section dividers), and search lives just above the rows rather
/// than in the toolbar so it reads as a list-filter, not a window-
/// level command.
///
/// Stop semantics (see [[feedback_no_speculative_risks]] for the
/// recording-safety contract):
///   • Clicking the pill again to stop = **no paste**, lands in
///     Recents only.
///   • Pressing the bound dictation shortcut to stop = stop and
///     paste at the user's cursor.
struct HomePane: View {
    /// Donation reminder card state. Observed so dismissal collapses the
    /// card immediately — the card's `markDismissedSoft` /
    /// `markDismissedForever` mutations flip `@Published state`, which
    /// re-evaluates `shouldShowDonationCard(...)` in the body.
    @ObservedObject private var donationStore = DonationStore.shared

    /// Observed so the pill reflects in-progress recording state.
    /// Injected at construction time by `JotAppWindow.detail`.
    @ObservedObject var recorder: RecorderController

    /// Audio-file transcription (docs/audio-file-transcription/design.md):
    /// owns the drop/pick ingest job + its inline progress/error status.
    /// Constructed once in `JotComposition.build` and threaded down via
    /// `.environmentObject` alongside `transcriberHolder` et al.
    @EnvironmentObject private var fileIngest: FileTranscriptionIngest

    /// Re-read the bound shortcut on every render so the pill caption
    /// stays in sync if the user rebinds the dictation hotkey from
    /// Settings → Shortcuts while the window is open.
    @AppStorage("jot.hotkey.toggleRecording.singleKey") private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""

    /// Drag-over state for the whole-zone `.dropDestination` (design §3.2).
    @State private var isDropTargeted = false

    var body: some View {
        RecordingsListView(navigationTitle: "Recents") {
            VStack(spacing: 7) {
                RecordPill(
                    isRecording: isRecording,
                    shortcutLabel: shortcutDisplay,
                    onTap: {
                        // v1.14 recording-safety contract:
                        //   • Idle → start a recording (toggle).
                        //   • Recording → stop without pasting; the
                        //     transcript still lands in Recents.
                        // Pressing the bound dictation shortcut while
                        // recording stops AND pastes — that path goes
                        // through the hotkey router, not this button.
                        Task {
                            if isRecording {
                                await recorder.stopWithoutPaste()
                            } else {
                                await recorder.toggle()
                            }
                        }
                    }
                )
                .padding(.top, 8)
                // Design §3.3: while a file job runs, the Dictate pill is
                // disabled as a secondary cue. This is NOT the mic-vs-file
                // collision fix (that's `FileTranscriptionIngest.shared?
                // .cancelInFlight()` in `RecorderController.runFlow()` —
                // the global hotkey bypasses this `.disabled` entirely, so
                // it can never be the only guard against data loss).
                .disabled(fileIngest.isImporting)
                .opacity(fileIngest.isImporting ? 0.5 : 1)
                .help(disabledPillHelp)

                dictateZoneCaption
                    .animation(.easeInOut(duration: 0.14), value: isDropTargeted)
                    .animation(.easeInOut(duration: 0.14), value: fileIngest.status)

                if shouldShowDonationCard(
                    state: donationStore.state,
                    count: donationStore.recordingCount,
                    firstLaunchDate: donationStore.firstLaunchDate,
                    reminderEnabled: donationStore.reminderEnabled,
                    now: Date()
                ) {
                    DonationCard()
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isDropTargeted ? 0.6 : 0),
                        style: StrokeStyle(lineWidth: 1.5, dash: isDropTargeted ? [5, 4] : [])
                    )
            )
            .animation(.easeInOut(duration: 0.14), value: isDropTargeted)
            // Design §3.1 Opt-1 (recommended): the whole dictate zone is the
            // drop target, not just a small sub-affordance — net-new, no
            // existing drag-drop anywhere else in Jot to match against.
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                // Enqueue every dropped file — the ingest queues them FIFO and
                // transcribes one at a time (review C; design §3.5). Previously
                // only `urls.first` was taken, silently discarding the rest.
                for url in urls { fileIngest.enqueue(url) }
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
        }
    }

    /// The line(s) under the pill: drag-over cue, resting drop/browse
    /// affordance, or the file job's in-progress/terminal status —
    /// whichever is current. Never shown alongside the dictate caption
    /// (design keeps this a single quiet line, not a paragraph).
    /// Tooltip for the disabled Dictate pill while a file job runs — reflects
    /// the actual phase (transcribing vs. detecting speakers). Kept out of the
    /// view body so the type-checker isn't asked to evaluate an inline closure.
    private var disabledPillHelp: String {
        if case .diarizing = fileIngest.status { return "Detecting speakers…" }
        if case .pausedForDictation = fileIngest.status { return "Paused — resumes after your dictation" }
        return fileIngest.isImporting ? "Finishing a file transcription…" : ""
    }

    @ViewBuilder
    private var dictateZoneCaption: some View {
        if isDropTargeted {
            Text("Release to transcribe")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
        } else {
            switch fileIngest.status {
            case .idle:
                VStack(spacing: 3) {
                    Text("Click or press \(shortcutDisplay) to dictate · paste at your cursor")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    AudioFileBrowseLine(onPick: presentAudioFileOpenPanel)
                }
            case .importing(let filename, let progress):
                // Determinate where honest (docs/transcription-progress/design.md):
                // a real `progress` fraction (Parakeet, audio > ~15s) gets a
                // linear bar + percentage; everything else (Nemotron, or any
                // file short enough that FluidAudio never emits a stream)
                // falls back to the indeterminate spinner + an elapsed-time
                // counter — honest about "still working," never a faked ETA.
                if let progress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress)
                            .frame(maxWidth: 120)
                        Text("Transcribing \(filename)… \(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing \(filename)…\(Self.elapsedSuffix(fileIngest.importElapsed))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            case .success(let filename):
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("Transcribed \(filename)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .failure(let message):
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            case .savedPending(let filename):
                HStack(spacing: 5) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("Saved \(filename) — needs transcription")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .diarizing(let filename):
                // Auto-diarize (docs/auto-diarize-imports/design.md): the
                // post-success "Detect speakers" pass, running automatically.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Detecting speakers in \(filename)…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            case .pausedForDictation:
                // Resilient import resume (docs/resilient-import-resume/
                // design.md §4): a live dictation preempted the file job —
                // it auto-resumes when the recorder returns to idle. Quiet,
                // not an error.
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Paused — resumes after dictation")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// `" M:SS"` (leading space, so it reads as "Transcribing foo.mp3… 1:23")
    /// once `importElapsed` has ticked; empty until then (job just started,
    /// ticker hasn't fired its first tick yet). Mirrors `Recording.formattedDuration`'s
    /// `%d:%02d` idiom.
    private static func elapsedSuffix(_ elapsed: TimeInterval?) -> String {
        guard let elapsed else { return "" }
        let total = Int(elapsed.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return " " + String(format: "%d:%02d", minutes, seconds)
    }

    /// Design §3.1 + §7: "browse" fallback for non-drag users — scoped to
    /// audio AND video UTTypes, matching the drop-path accept gate in
    /// `FileTranscriptionIngest.validate(_:)` (video audio is extracted on
    /// import; readability/DRM is decided by the async probe in `run()`).
    private func presentAudioFileOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.title = "Transcribe an Audio or Video File"
        panel.message = "Pick an audio or video file to transcribe into Recents."
        panel.prompt = "Transcribe"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileIngest.enqueue(url)
    }

    private var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    private var shortcutDisplay: String {
        _ = toggleSingleKey
        _ = toggleTriggerTypeRaw
        return SingleKeyMigration.effectiveBinding(for: .toggleRecording).displayLabel
    }
}

/// Restrained "Dictate" pill. Idle = ghosted outline with mic glyph.
/// Recording = red tint, pulsing red dot, "Recording — click to stop."
///
/// The caption beneath the pill (rendered by `HomePane`, not this view)
/// carries the bound-shortcut hint, so this affordance can read as a
/// minimal single-word button rather than a paragraph in a capsule.
private struct RecordPill: View {
    let isRecording: Bool
    let shortcutLabel: String
    let onTap: () -> Void

    @State private var isHovering = false
    @State private var pulse = false

    private let rec = Color(red: 0.878, green: 0.282, blue: 0.239) // #E0483D

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                if isRecording {
                    Circle()
                        .fill(rec)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(rec.opacity(0.4), lineWidth: 4)
                                .scaleEffect(pulse ? 2.2 : 1)
                                .opacity(pulse ? 0 : 1)
                        )
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.7)
                }

                Text(isRecording ? "Recording — click to stop" : "Dictate")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 15)
            .frame(height: 34)
            .foregroundStyle(isRecording ? rec : Color.secondary)
            .background(
                Capsule()
                    .fill(isRecording
                          ? rec.opacity(0.08)
                          : (isHovering
                             ? Color.primary.opacity(0.10)
                             : Color.primary.opacity(0.06)))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isRecording ? rec.opacity(0.28) : Color.primary.opacity(0.16),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start dictating")
        .accessibilityHint(isRecording
            ? "Stops the recording. The transcript is saved to Recents without pasting."
            : "Starts dictating. Click again to stop without pasting, or press \(shortcutLabel) to stop and paste at your cursor.")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isRecording)
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .onChange(of: isRecording) { _, recording in
            if recording {
                pulse = false
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }
}

/// Design §3.1: quiet secondary affordance under the resting dictate
/// caption — "↧ Drop an audio file, or browse", where only "browse" is
/// tappable (`.link`-styled). Deliberately minimal-weight so it never
/// competes with the primary Dictate pill.
private struct AudioFileBrowseLine: View {
    let onPick: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text("↧ Drop an audio or video file, or")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("browse", action: onPick)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
    }
}
