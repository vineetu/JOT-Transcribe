import AppKit
import SwiftUI

/// Inline "whisper affordance" copy control — a single SF Symbol that sits
/// flush with neighbouring metadata (timestamps, durations) in list rows.
///
/// Design intent:
/// * Reads as an icon, not a button. No border, no background, no chip.
/// * Idle state is `.secondary` foreground so it recedes behind the primary
///   content; accent color on hover gives a subtle "this is clickable" hint
///   without redrawing row geometry.
/// * On success the glyph swaps from `doc.on.doc` to `checkmark` for ~1s with
///   a gentle scale bounce so the user sees the copy land.
/// * Disabled when `text` is empty (failed / cancelled transcripts) so the
///   row stays geometrically stable rather than hiding the icon.
struct CopyTranscriptButton: View {
    /// The transcript (or any string) to copy to the general pasteboard.
    let text: String

    /// Optional accessibility label override. Defaults to "Copy transcript".
    var accessibilityLabel: String = "Copy transcript"

    /// Hover/tooltip help text. Defaults to "Copy transcript". Rewrite
    /// rows pass "Copy output" so the help string matches what they
    /// actually copy.
    var helpLabel: String = "Copy transcript"

    /// Empty-state help text. Defaults to "No transcript to copy".
    var emptyHelpLabel: String = "No transcript to copy"

    /// Point size for the SF Symbol. 12 pt matches the row's metadata text.
    var pointSize: CGFloat = 12

    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    private var isDisabled: Bool { text.isEmpty }

    var body: some View {
        // Why `Menu { … } primaryAction:` instead of a plain Button:
        // in the Library list row layout — as a sibling of the row's
        // navigation Button and the three-dots Menu — `Button` actions
        // never fire on click. The click is eaten by AppKit's
        // NSTableView row-selection layer that sits under SwiftUI's
        // `List`. The three-dots `Menu` in the same sibling position
        // DOES receive clicks because `Menu` bridges to an AppKit
        // `NSMenu` whose press tracking runs ahead of the table's row
        // hit-test. Wrapping Copy as a `Menu` with `primaryAction:`
        // rides the same AppKit path: left-click fires `primaryAction`,
        // right-click / long-press shows the menu items (a single
        // "Copy" item so those gestures stay functional, calling the
        // same `copy()`).
        Menu {
            Button(action: copy) {
                Label(helpLabel, systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: pointSize, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(foreground)
                .scaleEffect(copied ? 1.08 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: copied)
                // Reserve a stable hit-target width so the row layout
                // never shifts when the glyph swaps between
                // `doc.on.doc` and `checkmark` (the two symbols have
                // slightly different widths).
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        } primaryAction: {
            copy()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .help(isDisabled ? emptyHelpLabel : (copied ? "Copied" : helpLabel))
        .accessibilityLabel(accessibilityLabel)
    }

    private var foreground: Color {
        if isDisabled { return Color.secondary.opacity(0.35) }
        if copied { return .accentColor }
        if hovering { return .accentColor }
        return .secondary
    }

    private func copy() {
        guard !isDisabled else { return }
        // Prefer the Pasteboarding seam (so harness flows can verify
        // via `StubPasteboard`); fall back to `NSPasteboard.general`
        // when `AppServices.live` is nil so the clipboard still gets
        // the text on the cold-launch race window.
        let wrote: Bool
        if let pb = AppServices.live?.pasteboard {
            wrote = pb.write(text)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            wrote = pb.setString(text, forType: .string)
        }
        guard wrote else {
            Task { await ErrorLog.shared.warn(
                component: "CopyTranscriptButton",
                message: "copy failed — pasteboard write returned false"
            ) }
            return
        }
        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
