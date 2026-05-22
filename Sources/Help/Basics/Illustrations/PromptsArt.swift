import SwiftUI

// MARK: - Prompts art

/// Phase 0.0–0.2: a selection of body text fades in on the left.
/// Phase 0.2–0.4: a hotkey chip ("⌥/") appears with a "hold" caption; chip dims
///                slightly after 0.4 to suggest "the user already pressed it."
/// Phase 0.4–0.7: a picker panel slides up from below, listing 5 prompts.
///                The "Rewrite" row is highlighted as the default selection.
/// Phase 0.7–0.85: the selection indicator moves down to "Make formal" —
///                 that row becomes highlighted (default row dims back to
///                 neutral).
/// Phase 0.85–1.0: panel collapses; the selected text transforms into the
///                 rewritten version with a brief "applying…" beat.
///
/// Visual rules borrowed from the sibling illustrations:
///   - Opacity floor of 0.2 on anything that should stay legible.
///   - Accent color for the active row + the pinned/default marker.
///   - Font sizes match `BeforeText`/`AfterText` (~11pt) so the picker rows
///     read as compact list rows, not body copy.
struct PromptsArt: View {
    let phase: Double

    /// (title, isPinned). Pinned row also becomes the initial default
    /// selection. Names lifted from `Resources/prompt-library.json` where
    /// they exist; "Rewrite" is the conceptual default prompt described in
    /// the Prompts hero subtitle.
    private let prompts: [(title: String, pinned: Bool)] = [
        ("Rewrite",         true),
        ("Summarize",       false),
        ("Make formal",     false),
        ("Improve writing", false),
        ("Translate",       false),
    ]

    private static let defaultRowIndex = 0
    private static let secondRowIndex  = 2  // Make formal

    var body: some View {
        // Selection snippet — fades in early, persists; gently dims once the
        // rewrite "applies" at the very end.
        let selectionOpacity = max(
            0.2,
            heroKeyframe(phase: phase, start: 0.0, end: 0.2, from: 0.0, to: 1.0)
            * heroKeyframe(phase: phase, start: 0.9, end: 1.0, from: 1.0, to: 0.35)
        )

        // Hotkey chip — fades in during [0.2, 0.4], dims (but stays visible)
        // after the panel appears so the eye moves to the panel.
        let chipOpacity = max(
            0.0,
            heroKeyframe(phase: phase, start: 0.2, end: 0.4, from: 0.0, to: 1.0)
            * heroKeyframe(phase: phase, start: 0.4, end: 0.5, from: 1.0, to: 0.45)
        )

        // Picker panel — slides up from below + fades in [0.4, 0.7];
        // collapses (fades + slides back down) during [0.85, 1.0].
        let panelOpacity = max(
            0.0,
            heroKeyframe(phase: phase, start: 0.4, end: 0.7, from: 0.0, to: 1.0)
            * heroKeyframe(phase: phase, start: 0.85, end: 1.0, from: 1.0, to: 0.0)
        )
        let panelOffsetY = heroKeyframe(phase: phase, start: 0.4, end: 0.7, from: 18.0, to: 0.0)
            + heroKeyframe(phase: phase, start: 0.85, end: 1.0, from: 0.0, to: 10.0)

        // Selection indicator: starts on the default row (Rewrite); moves to
        // "Make formal" during [0.7, 0.85].
        let highlightedRow: Int = {
            if phase < 0.7 { return Self.defaultRowIndex }
            return Self.secondRowIndex
        }()

        // "Applied" rewritten text — fades in at the very end as the panel
        // collapses, so the eye follows the gesture: pick → apply.
        let appliedOpacity = max(
            0.0,
            heroKeyframe(phase: phase, start: 0.88, end: 1.0, from: 0.0, to: 1.0)
        )

        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {

                // Row 1: selection snippet on the left, hotkey chip on the right.
                HStack(alignment: .center, spacing: 12) {
                    ZStack(alignment: .leading) {
                        SelectedSnippetView()
                            .opacity(selectionOpacity * (1.0 - appliedOpacity))
                        AppliedSnippetView()
                            .opacity(appliedOpacity)
                    }
                    Spacer(minLength: 8)
                    HotkeyChip(label: "⌥/")
                        .opacity(chipOpacity)
                }

                // Row 2: picker panel.
                PickerPanelView(prompts: prompts, highlightedIndex: highlightedRow)
                    .opacity(panelOpacity)
                    .offset(y: panelOffsetY)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Subviews

/// The pre-rewrite text the user has selected. A highlighted span on the
/// right signals "this is what's selected."
private struct SelectedSnippetView: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Send the")
                .foregroundStyle(.primary)
            Text("meeting notes")
                .foregroundStyle(.primary)
                .padding(.horizontal, 3)
                .background(Color.accentColor.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

/// Post-rewrite state — the selection has been transformed by "Make formal".
private struct AppliedSnippetView: View {
    var body: some View {
        Text("Please send the meeting notes.")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16))
            )
    }
}

/// Compact keycap chip showing the trigger shortcut ("⌥/"). Matches the
/// keycap treatment used elsewhere in Help (rounded rect + thin border).
private struct HotkeyChip: View {
    let label: String

    var body: some View {
        VStack(alignment: .center, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                )
            Text("hold")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The prompt picker mock — a rounded rectangle panel with a list of
/// prompt rows. The highlighted row uses the accent color; the pinned
/// row carries a small star/pin glyph leading.
private struct PickerPanelView: View {
    let prompts: [(title: String, pinned: Bool)]
    let highlightedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                PromptRow(
                    title: prompt.title,
                    pinned: prompt.pinned,
                    highlighted: index == highlightedIndex
                )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

private struct PromptRow: View {
    let title: String
    let pinned: Bool
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pinned ? "pin.fill" : "text.alignleft")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                .frame(width: 10, alignment: .leading)
            Text(title)
                .font(.system(size: 11, weight: highlighted ? .semibold : .medium))
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(highlighted ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }
}
