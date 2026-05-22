import SwiftUI

/// "When this fires" pill rendered to the right of each row's subtitle.
///
/// Three semantics map to three colored dots:
///   • Green  — Always active
///   • Purple — Needs text selection
///   • Gray   — During recording (the Esc cancel row)
///
/// Pill chrome stays muted (a tinted capsule on a translucent background)
/// so the badge surfaces the *meaning* without competing with the binding
/// chip on the right of the row, which is the primary affordance.
struct ShortcutBadge: View {
    let firing: ShortcutsRow.FiringContext

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(firing.dotColor)
                .frame(width: 6, height: 6)
            Text(firing.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(firing.label))
    }
}
