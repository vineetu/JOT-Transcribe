import SwiftUI

/// A titled subsection inside a `HelpSection`.
///
/// Pins `.id(anchor)` on its outer container so `InfoPopoverButton`'s
/// deep-link contract (`jot.help.scrollToAnchor`) resolves to this exact
/// node (per plan §7). Phase 1 keeps arbitrary `content` — in later phases
/// the content is `DiagramCard { Diagram; Caption }`.
struct HelpSubsection<Content: View>: View {
    let title: String
    let anchor: String
    @ViewBuilder let content: () -> Content

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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            content()
        }
        .id(anchor)
    }
}
