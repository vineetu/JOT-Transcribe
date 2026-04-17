import SwiftUI

/// Disclosure row used **only** in Troubleshooting (plan §4.4a).
///
/// Applies `.id(anchor)` on its outer container so deep-links resolve.
/// Implements the §7 two-phase deep-link expand contract: subscribes to
/// the private `jot.help.expandForAnchor` notification (NOT the public
/// `jot.help.scrollToAnchor`). When the delivered anchor matches, the
/// row sets `isExpanded = true` **without animation** so SwiftUI's
/// relayout commits synchronously before `HelpPane` asks
/// `ScrollViewReader` for a Y. `HelpPane` is responsible for re-posting
/// this private notification ahead of its deferred `scrollTo` call.
struct ExpandableRow<Content: View>: View {
    let title: String
    let anchor: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded: Bool = false

    init(
        _ title: String,
        anchor: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.anchor = anchor
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.top, 12)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .id(anchor)
        .onReceive(NotificationCenter.default.publisher(
            for: HelpPane.expandForAnchorNotification
        )) { note in
            guard let delivered = note.userInfo?["anchor"] as? String,
                  delivered == anchor
            else { return }
            // Synchronous, no animation: SwiftUI commits the expanded
            // layout in the same runloop pass so HelpPane's deferred
            // scrollTo resolves against the post-expand Y (§7).
            isExpanded = true
        }
    }
}
