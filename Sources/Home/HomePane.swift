import SwiftUI

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

    /// Re-read the bound shortcut on every render so the pill caption
    /// stays in sync if the user rebinds the dictation hotkey from
    /// Settings → Shortcuts while the window is open.
    @AppStorage("jot.hotkey.toggleRecording.singleKey") private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""

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

                Text("Click or press \(shortcutDisplay) to dictate · paste at your cursor")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)

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
        }
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
