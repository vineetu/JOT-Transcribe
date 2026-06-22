import SwiftUI

/// Reports the measured content-column width up to the detail view, which hands
/// it to the transcript as an explicit layout width.
struct ContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shared building blocks for the redesigned Library detail surfaces
/// (docs/recordings-detail-redesign/design.md). The direction: treat
/// transcript / rewrite content as a **reading surface** — New York serif at a
/// comfortable measure, single page scroll, no boxed code-style panes.

/// Comfortable reading column for detail content. Wider than nothing, narrower
/// than the 760pt page so long lines stay readable.
enum DetailMetrics {
    static let readingMeasure: CGFloat = 680
    static let pageMeasure: CGFloat = 760
    static let blockSpacing: CGFloat = 22
    static let serifSize: CGFloat = 15.5
}

/// Plain selectable serif prose — the canonical transcript / rewrite body
/// rendering. Flows to full width of its container; the page owns scrolling.
struct ReadingProse: View {
    let text: String
    var emphasized: Bool = false
    var placeholder: String = ""

    var body: some View {
        let shown = text.isEmpty ? placeholder : text
        Text(shown)
            .font(.system(size: DetailMetrics.serifSize, weight: emphasized ? .medium : .regular, design: .serif))
            .lineSpacing(6)
            .foregroundStyle(text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A labeled reading block: quiet uppercase-ish section label above serif body.
/// Used for the rewrite stacked panes (Instruction / Original / Rewritten) and
/// any labeled content in the recording detail.
struct ReadingSection<Content: View>: View {
    let label: String
    var emphasized: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The editable title + metadata header shared by both detail views.
struct DetailHeader<Meta: View>: View {
    @Binding var title: String
    @ViewBuilder var meta: Meta

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(2)
            meta
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
