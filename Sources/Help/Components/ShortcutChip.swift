import SwiftUI

/// Keyboard shortcut visual — an `HStack` of tiny capsules, one per key
/// (e.g. `["⌥", "Space"]` → two chips laid out left-to-right).
struct ShortcutChip: View {
    let keys: [String]

    init(_ keys: [String]) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keyCapsule(key)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shortcut: " + keys.joined(separator: " "))
    }

    private func keyCapsule(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
    }
}
