import SwiftUI

/// Group header rendered above each section's rows. The header itself
/// is a small uppercase label — close to System Settings' section style
/// but without the disclosure chevron (the rows are always visible).
///
/// Wrapped in its own component so the search view can swap a single
/// section header (when the active query straddles two groups) for a
/// "Search results" header without rebuilding the list.
struct ShortcutSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
