import KeyboardShortcuts
import SwiftUI

/// The focal chip on the redesigned Setup Wizard "your dictation shortcut"
/// page. Displays the currently-effective binding for `.toggleRecording`
/// (single-key or chord — the chip itself doesn't care which) and renders
/// per-phase visual treatments matching the rest of the wizard step:
///
///   • `.idle`        — neutral background, soft 1.8 s scale pulse to draw
///                       the eye toward "press it now."
///   • `.editing`     — collapses to an inline `KeyboardShortcuts.Recorder`
///                       so the user can rebind from inside the chip.
///   • `.recording`   — red tint matches the production overlay pill.
///   • `.transcribing`— accent tint matches the production overlay pill.
///   • `.disabled`    — muted gray (Input Monitoring missing, etc.).
///   • `.passed`/`.failed` — neutral (the verdict text lives outside).
///
/// Inputs are intentionally minimal:
///   • `label`     — what to render (e.g. "Caps Lock" or "⌥ Space").
///   • `phase`     — drives the colour treatment.
///   • `editing`   — when true, the chip body switches to the recorder.
///   • `recorderName` — `KeyboardShortcuts.Name` to bind the chord recorder to.
///   • `onRecorderChange` — fired whenever the chord recorder commits.
///
/// All storage writes (single-key vs chord bookkeeping) happen in the parent
/// — the chip is presentation only. This keeps the recorder-vs-quick-pick
/// flow logic in one place (`TestStep`) and the chip easy to preview.
struct WizardShortcutChip: View {
    enum Phase: Equatable {
        case idle
        case editing
        case recording
        case transcribing
        case passed
        case failed
        case disabled
    }

    let label: String
    let phase: Phase
    let recorderName: KeyboardShortcuts.Name
    let onRecorderChange: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Group {
            if phase == .editing {
                editingBody
            } else {
                staticBody
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .scaleEffect(pulseScale)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: phase) { _, _ in startPulseIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Body variants

    @ViewBuilder
    private var staticBody: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var editingBody: some View {
        VStack(spacing: 10) {
            Text("Press a key combo")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            // KeyboardShortcuts.Recorder handles modifier-required chords;
            // single-key (modifier-less) bindings come in via the quick-pick
            // chips below the chip and write to `SingleKey` storage directly.
            // The custom NSEvent recorder that would let *both* modes share
            // one affordance is the v1.14 deferred polish item.
            KeyboardShortcuts.Recorder(for: recorderName) { _ in
                onRecorderChange()
            }
            Text("Or click outside to cancel.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Pulse

    private func startPulseIfNeeded() {
        guard phase == .idle, !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.2)) { pulseScale = 1.0 }
            return
        }
        // 1.8 s ease-in-out loop, scale 1.00 → 1.04 → 1.00. Respects
        // accessibilityReduceMotion via the early-return above.
        pulseScale = 1.0
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulseScale = 1.04
        }
    }

    // MARK: - Colours

    private var foreground: Color {
        switch phase {
        case .recording:    return .red
        case .transcribing: return .accentColor
        case .disabled:     return .secondary
        case .idle, .editing, .passed, .failed: return .primary
        }
    }

    private var background: Color {
        switch phase {
        case .recording:    return Color.red.opacity(0.10)
        case .transcribing: return Color.accentColor.opacity(0.08)
        case .disabled:     return Color.secondary.opacity(0.08)
        case .idle, .editing, .passed, .failed:
            return Color(nsColor: .controlBackgroundColor).opacity(0.45)
        }
    }

    private var border: Color {
        switch phase {
        case .recording:    return Color.red.opacity(0.45)
        case .transcribing: return Color.accentColor.opacity(0.45)
        case .disabled:     return Color.primary.opacity(0.06)
        case .idle, .editing, .passed, .failed:
            return Color.primary.opacity(0.10)
        }
    }

    private var accessibilityLabel: Text {
        switch phase {
        case .idle:         return Text("Current shortcut: \(label). Press it to test.")
        case .editing:      return Text("Press a key combination to change the shortcut.")
        case .recording:    return Text("Recording. Press \(label) again to stop.")
        case .transcribing: return Text("Transcribing your test recording.")
        case .passed:       return Text("Test passed. Shortcut \(label) is working.")
        case .failed:       return Text("Test failed.")
        case .disabled:     return Text("Shortcut \(label) is bound but cannot fire yet.")
        }
    }
}
