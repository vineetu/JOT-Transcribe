import SwiftUI

/// Landing view for the unified Jot window.
///
/// Home now owns the full recordings browser: banner + shortcut glance at the
/// top, followed by the searchable date-grouped list and recording detail
/// navigation previously hosted under a separate sidebar item.
struct HomePane: View {
    /// Donation reminder card state. Observed so dismissal collapses the
    /// card immediately — the card's `markDismissedSoft` /
    /// `markDismissedForever` mutations flip `@Published state`, which
    /// re-evaluates `shouldShowDonationCard(...)` in the body.
    @ObservedObject private var donationStore = DonationStore.shared
    @AppStorage("jot.hotkey.toggleRecording.singleKey") private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""

    var body: some View {
        RecordingsListView(navigationTitle: "Recents") {
            VStack(alignment: .leading, spacing: 20) {
                BasicsBanner()

                glance
                    .padding(.top, 8)

                if shouldShowDonationCard(
                    state: donationStore.state,
                    count: donationStore.recordingCount,
                    firstLaunchDate: donationStore.firstLaunchDate,
                    reminderEnabled: donationStore.reminderEnabled,
                    now: Date()
                ) {
                    DonationCard()
                        .transition(.opacity)
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Glance

    private var glance: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Text("Press ")
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            + Text(shortcutDisplay)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            + Text(" to dictate")
                .font(.system(size: 15))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
    }

    private var shortcutDisplay: String {
        _ = toggleSingleKey
        _ = toggleTriggerTypeRaw
        return SingleKeyMigration.effectiveBinding(for: .toggleRecording).displayLabel
    }
}
