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

    /// Point size for the SF Symbol. 12 pt matches the row's metadata text.
    var pointSize: CGFloat = 12

    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    private var isDisabled: Bool { text.isEmpty }

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: pointSize, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(foreground)
                .scaleEffect(copied ? 1.08 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: copied)
                // Reserve a stable hit-target width so the row layout never
                // shifts when the glyph swaps between `doc.on.doc` and
                // `checkmark` (the two symbols have slightly different widths).
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .help(isDisabled ? "No transcript to copy" : (copied ? "Copied" : "Copy transcript"))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var foreground: Color {
        if isDisabled { return Color.secondary.opacity(0.35) }
        if copied { return .accentColor }
        if hovering { return .accentColor }
        return .secondary
    }

    private func copy() {
        guard !isDisabled else { return }
        // Phase 4 patch round 4: route through the Pasteboarding seam
        // instead of `NSPasteboard.general` so harness flows can verify
        // the copy via `StubPasteboard`. AppServices.live is always
        // resolved by the time a SwiftUI body renders.
        guard let pb = AppServices.live?.pasteboard else { return }
        _ = pb.write(text)

        copied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
