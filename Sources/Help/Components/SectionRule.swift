import SwiftUI

/// Inset hairline divider placed between sections. 40%-opacity rule,
/// 56 pt of breathing room above and below (per plan §3.5).
struct SectionRule: View {
    var body: some View {
        Divider()
            .overlay(Color.primary.opacity(0.4))
            .padding(.vertical, 28)
    }
}
