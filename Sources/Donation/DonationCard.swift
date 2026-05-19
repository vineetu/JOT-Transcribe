import SwiftUI

/// Dismissible "Support Jot" card rendered inline on `HomePane` below the
/// "Recent" row when `shouldShowDonationCard(...)` returns true.
///
/// Copy is verbatim from `docs/research/donation-reminder.md` §3 — two
/// sentences, no embellishment, no guilt framing, no "100% goes to
/// causes" or "personally vetted" language. The only claim the author
/// has asked us to make about where the money goes is *"the every.org
/// fund that supports education"*. Don't pad it.
///
/// Three donate links (Donate $1 / Donate $2 / Other amount) open
/// every.org in the user's default browser and optimistically flip the
/// state to `.donated(Date())` — there's no receipt or webhook, and
/// that's deliberate (see spec §6.6). Two dismiss controls:
///
///   • "Maybe later" → soft-dismiss (90-day cooldown before re-fire).
///   • "Don't ask again" → hard-dismiss (terminal state).
///
/// Card chrome matches the existing Home "Recent recordings" row:
/// `RoundedRectangle(cornerRadius: 8)` with a hairline stroke. No
/// vibrancy material — this card should read as "part of Home", not as
/// a notification or banner.
struct DonationCard: View {
    @ObservedObject private var donationStore = DonationStore.shared

    /// Sheet binding for the in-app Donations page. v1.9.7+ the
    /// card's button opens an in-app browser of charities instead
    /// of routing the user to `jot.ideaflow.page/donations` in the
    /// system browser. The optimistic "marked donated" flip also
    /// moves out of this view — it now fires at the moment the
    /// user taps a $N pill inside `DonationsView`, which is closer
    /// to the actual donate moment.
    @State private var isShowingDonations = false

    // MARK: - Copy (spec §3, verbatim)

    private let headline = "Jot is free, and stays free."
    private let pitch = "If it's earned a spot in your workflow, consider donating to one of the charities I support."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(pitch)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    isShowingDonations = true
                } label: {
                    Text("Donate to charity")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Spacer(minLength: 8)

                Button("Maybe later") {
                    donationStore.markDismissedSoft()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

                Button("Don't ask again") {
                    donationStore.markDismissedForever()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .sheet(isPresented: $isShowingDonations) {
            DonationsView()
        }
    }
}
