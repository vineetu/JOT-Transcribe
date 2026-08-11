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
    /// Live transcript of what is being said, mirrored into the field so the
    /// words appear where the instruction goes — no second window needed.
    @ObservedObject private var partials = StreamingPartialStore.shared
    /// The exact text this view last wrote into the field from a partial.
    /// Anything in the field that differs from it came from the KEYBOARD,
    /// which is how a real keystroke is told apart from our own writes —
    /// without this the streaming text would trip `onFirstEdit` and stop the
    /// mic on the user's behalf, one word in.
    @State private var lastAppliedPartial: String = ""
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

    /// What ⏎ / the hotkey / esc do right now, in the user's terms.
    private var footerHint: String {
        if hasTyped {
            // Typing stopped the mic; anything already transcribed is sitting
            // in the field and goes with what they type.
            return "⏎ run · esc cancel · mic off, editing"
        }
        // Listening: both keys finish and use the speech. Naming the real
        // binding here is why the pill no longer needs its own "Press ⌥. to
        // stop" line — and resolving it (rather than hardcoding ⌥.) keeps it
        // honest if the shortcut is rebound in Settings.
        let key = SingleKeyMigration.effectiveBindingLabel(for: .rewriteWithVoice)
        let finish = key.map { "⏎ or \($0) to finish" } ?? "⏎ to finish"
        return title != nil
            ? "\(finish) · esc cancel · stay silent to apply as-is"
            : "\(finish) · esc cancel"
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
                // A change that is NOT the partial we just wrote is a keystroke.
                if !hasTyped && newValue != lastAppliedPartial {
                    hasTyped = true
                    onFirstEdit()
                }
                // Only the user's own text is mirrored to the controller —
                // partials are feedback, and the final transcript (more
                // accurate than any partial) is what the voice path uses.
                if hasTyped { onTextChange(newValue) }
            }
            .onChange(of: partials.partial) { _, partial in
                // Once the user types, the field is theirs: typing supersedes
                // speaking, and the words already transcribed stay put so they
                // can keep going from where the speech left off.
                guard !hasTyped, let partial, !partial.isEmpty else { return }
                lastAppliedPartial = partial
                text = partial
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
            // The footer must match what the keys ACTUALLY do, which depends
            // on whether the mic is still live:
            //   • still listening → ⏎ and the hotkey do the SAME thing (stop
            //     and use whatever was spoken). The old copy said "leave empty
            //     to apply as-is", which is only true if you never spoke — it
            //     read as "⏎ throws my speech away".
            //   • typed → the mic is already stopped; ⏎ runs the typed text.
            Text(footerHint)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
