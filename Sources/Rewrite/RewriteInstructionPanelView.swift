import SwiftUI

/// SwiftUI content for the typed instruction panel. A single-line field (mic
/// stays hot so speaking still works), a live "Listening…" affordance, and
/// 0–3 canned chips that submit instantly.
///
/// Both what the field ASKS for (`placeholder`) and the chips are supplied per
/// run, because the panel serves two shapes: a free-form instruction on the
/// plain hotkey path, and a single missing detail for a picked prompt that
/// already carries its own system prompt (which arrives with no chips).
///
/// Semantics (wired by `RewriteController` via the closures):
///   • ⏎ with text  → `onSubmit(text)` runs the rewrite with that instruction.
///   • ⏎ empty       → `onSubmit("")`  → the caller decides (clean-up / voice /
///     "that detail was required").
///   • chip tap      → `onSubmit(chip.instruction)` immediately.
///   • first keystroke → `onFirstEdit()` (pause the mic + cancel the timer).
///   • Esc           → `onCancel()` (order out, no paste).
struct RewriteInstructionPanelView: View {
    /// Picked prompt's name, shown as a tinted pill in the header. `nil` on the
    /// plain path, which keeps the generic "Rewrite selection" title. Its
    /// presence is also what marks the pane as an augment run — it drives the
    /// "leave empty to apply as-is" footer note.
    let title: String?
    let chips: [RewriteInstructionChip]
    /// A prompt-specific question rendered above the field ("Say the target
    /// language"). `nil` on the plain path, where the field alone suffices.
    let questionLine: String?
    /// Placeholder for the empty field — a bare example on the augment path.
    let placeholder: String
    let onFirstEdit: @MainActor () -> Void
    let onTextChange: @MainActor (String) -> Void
    let onSubmit: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    @State private var text: String = ""
    @State private var hasTyped: Bool = false
    @State private var animateWave: Bool = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let questionLine, !questionLine.isEmpty {
                Text(questionLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field
            chipRow
        }
        .padding(16)
        .frame(width: 400, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // `.onExitCommand` is the primary Esc route for the focused field; the
        // panel's `cancelOperation` override is the backstop for when focus is
        // off the field (e.g. just after a chip click).
        .onExitCommand { onCancel() }
        .onAppear {
            // Focus on the next runloop tick so the panel is fully key first.
            DispatchQueue.main.async { fieldFocused = true }
            animateWave = true
        }
    }

    // MARK: - Header (title + live mic state)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
            if let title, !title.isEmpty {
                // Picked-prompt pane wears the prompt's name as a tinted pill so
                // the user sees which prompt they're feeding a detail into.
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 9)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            } else {
                Text("Rewrite selection")
                    .font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 8)
            micAffordance
        }
    }

    @ViewBuilder
    private var micAffordance: some View {
        if hasTyped {
            // Typing pauses the mic (the caller stops it on `onFirstEdit`), so
            // the live-listening affordance is replaced by a static hint.
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .medium))
                Text("Typing")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                waveform
                Text("Listening…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A small three-bar equalizer that gently pulses while the mic is hot.
    /// Purely decorative (amplitude is not wired) but signals "speaking works".
    private var waveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: animateWave ? 12 : 4)
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animateWave
                    )
            }
        }
        .frame(height: 12)
    }

    // MARK: - Text field

    private var field: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focused($fieldFocused)
            .onSubmit { onSubmit(text) }
            .onChange(of: text) { _, newValue in
                if !hasTyped && !newValue.isEmpty {
                    hasTyped = true
                    onFirstEdit()
                }
                // Mirror the field's live text to the controller so a resolve
                // via a path other than ⏎ (second hotkey / idle timeout) can
                // still salvage what was typed.
                onTextChange(newValue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    // MARK: - Chips

    /// Chips plus the key hint. With no chips the row collapses to the key hint
    /// alone — the leading `ForEach` contributes nothing and `HStack` spacing
    /// only applies between rendered children, so there's no phantom gutter.
    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                Button {
                    onSubmit(chip.instruction)
                } label: {
                    Text(chip.label)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(
                    Capsule().fill(Color.primary.opacity(0.08))
                )
                .contentShape(Capsule())
            }
            Spacer(minLength: 8)
            // On a picked-prompt pane the detail is optional — no detail applies
            // the prompt as-is — so the footer says so; the plain pane keeps the
            // terse key hint.
            Text(title != nil
                 ? "⏎ run · esc cancel · leave empty to apply as-is"
                 : "⏎ to run · esc to cancel")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
