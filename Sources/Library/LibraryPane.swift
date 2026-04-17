import SwiftUI

/// Sidebar-selected Library view inside the unified app window. Thin wrapper
/// around the existing `RecordingsListView` — keeps the NavigationStack
/// nesting as-is for now (tracked as a follow-up; see docs/plans/app-ui-unification.md §I1).
struct LibraryPane: View {
    var body: some View {
        RecordingsListView(
            pendingOpen: nil,
            onConsumedPendingOpen: {}
        )
    }
}
