import SwiftUI

/// A single feature specimen card used throughout HelpPane.
///
/// Top: a purpose-drawn SwiftUI visual sized to ~80pt tall.
/// Middle: the title (headline).
/// Bottom: a 1–2 sentence caption in secondary color.
///
/// If an `anchor` is provided the card applies `.id(anchor)` so the
/// existing `InfoPopoverButton` deep-link flow (scrollTo) still works.
struct FeatureCard<Visual: View>: View {
    let title: String
    let caption: String
    let anchor: String?
    let tag: String?
    @ViewBuilder let visual: () -> Visual

    init(
        _ title: String,
        caption: String,
        anchor: String? = nil,
        tag: String? = nil,
        @ViewBuilder visual: @escaping () -> Visual
    ) {
        self.title = title
        self.caption = caption
        self.anchor = anchor
        self.tag = tag
        self.visual = visual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Visual stage — monochrome pale ground, card-interior centered.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.025))
                visual()
            }
            .frame(height: 88)
            .padding(10)

            // Hairline rule between visual and text, matches the
            // "technical specimen" aesthetic.
            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(.headline, design: .default))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if let tag {
                        Text(tag)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                            )
                    }
                }
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
        .modifier(AnchorIDModifier(anchor: anchor))
    }
}

/// Apply `.id(anchor)` only if the anchor is non-nil so unanchored cards
/// don't all collide on the same nil identifier in the ScrollViewReader
/// namespace.
private struct AnchorIDModifier: ViewModifier {
    let anchor: String?
    func body(content: Content) -> some View {
        if let anchor {
            content.id(anchor)
        } else {
            content
        }
    }
}
