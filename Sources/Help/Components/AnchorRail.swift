import SwiftUI

/// Pane-level TOC card (plan §4.1 / §5 `AnchorRail`). Three rows — one per
/// top-level section — each row scrolls to its section root when tapped.
///
/// Implements P2 (signaling the pane's organization). Takes an `onSelect`
/// closure so the parent view keeps ownership of the `ScrollViewReader`
/// proxy instead of having to thread it through the environment.
struct AnchorRail: View {
    struct Item: Identifiable {
        let id = UUID()
        let number: String
        let title: String
        let dek: String
        let anchor: String
    }

    let items: [Item]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    onSelect(item.anchor)
                } label: {
                    row(for: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to section \(item.number): \(item.title)")

                if index < items.count - 1 {
                    Divider()
                        .overlay(Color.primary.opacity(0.08))
                        .padding(.leading, 48)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func row(for item: Item) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(item.number)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .frame(width: 20, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(item.dek)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
