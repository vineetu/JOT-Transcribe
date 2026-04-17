import SwiftUI

/// A top-level Help section (Basics / Advanced / Troubleshooting).
///
/// Owns the eyebrow numeral, the section title, an optional one-line dek,
/// and pins `.id(anchor)` on its outer container so deep-links targeting
/// the section root resolve (per `docs/plans/help-redesign.md` §7).
struct HelpSection<Content: View>: View {
    let number: String
    let title: String
    let dek: String?
    let anchor: String
    @ViewBuilder let content: () -> Content

    init(
        number: String,
        title: String,
        dek: String? = nil,
        anchor: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.number = number
        self.title = title
        self.dek = dek
        self.anchor = anchor
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(number)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(.primary)
                .padding(.top, 6)

            if let dek {
                Text(dek)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            VStack(alignment: .leading, spacing: 28) {
                content()
            }
            .padding(.top, 24)
        }
        .id(anchor)
    }
}
