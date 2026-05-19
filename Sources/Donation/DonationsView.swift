import AppKit
import SwiftUI

/// In-app donations page. Ported from `jot-mobile`'s `DonationsView`
/// (see `docs/plans/` if a Mac-specific design doc is added later).
///
/// Presented as a `.sheet` from `AboutPane` and the Home
/// `DonationCard` — replaces the old hyperlink-to-website behaviour
/// where both surfaces opened `jot.ideaflow.page/donations` in the
/// default browser. The new flow keeps the user in-app for browsing,
/// then opens the system browser only at the actual donate step
/// (every.org's URL).
///
/// Why a sheet and not a sidebar entry: the Mac sidebar is the
/// permanent shell (Home / Ask Jot / Settings / Help / About); a
/// Donations page is a focused, opt-in surface reached from a
/// button. A sheet matches the iOS spec's "push then back" feel
/// (open → focus → dismiss) without polluting the sidebar.
///
/// Light/dark mode notes: every color in this view comes from a
/// system semantic token (`.primary`, `.secondary`, `.tertiary`,
/// `.accentColor`, `Color(nsColor: .separatorColor)`) or
/// `.regularMaterial`. AppKit swaps the resolved values
/// automatically when the user toggles Appearance, so the page
/// adapts without any `@Environment(\.colorScheme)` branching.
struct DonationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Last-known summary payload from `GET /summary`. Persists
    /// across launches so the page never opens empty after the
    /// first successful fetch. Matches the iOS port's `@AppStorage`
    /// key so a future shared-server change is the only thing that
    /// can invalidate the cache.
    @AppStorage("jot.donations.lastSummary") private var cachedSummaryData: Data = Data()

    @State private var summary: DonationsSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var shuffledOrder: [String] = []
    @State private var searchText = ""

    /// Optimistic-donation marker. Bound to `DonationStore` so a
    /// donation made from this sheet collapses the Home donation
    /// card on dismiss (the card hides when `state == .donated`).
    @ObservedObject private var donationStore = DonationStore.shared

    var body: some View {
        ZStack {
            // Plain window-background tint as the canvas. Avoids
            // the iOS `WallpaperBackground` (which expects a UIKit
            // trait collection for its radial washes); a flat tinted
            // surface reads as native Mac and stays legible against
            // either Appearance.
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroTitle
                    gratitudeBlock
                    searchBar

                    if let errorMessage, summary != nil {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    charityListCard
                    totalRaisedCard
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 640, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .refreshable {
                await refresh()
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        .toolbar {
            // Cmd-R re-fetches; Done dismisses. Matches macOS sheet
            // conventions — there's no NavigationStack to "pop".
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(isLoading)
                .help(isLoading ? "Refreshing…" : "Refresh (⌘R)")
            }
        }
        .task {
            guard summary == nil else { return }
            loadCachedSummary()
            await refresh()
        }
    }

    // MARK: - Hero

    private var heroTitle: some View {
        // Editorial italic serif matches iOS spec §4. Falls back
        // gracefully on macOS — `design: .serif` resolves to
        // New York, which has true italics.
        Text("Donations.")
            .font(.system(size: 44, weight: .regular, design: .serif).italic())
            .tracking(-1.6)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }

    private var gratitudeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jot is free, and always will be.")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Text("The time and clarity it gives back — speaking instead of typing, thinking out loud, catching what would've slipped — isn't something everyone has access to.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let personalization = personalizationText {
                Text(personalization)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("If it's helped, consider passing some of that forward.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    /// "Jot has saved you about <duration> so far." — spec §6.2.
    /// Only renders past the 5-minute threshold (`5 * 60` s of
    /// cumulative dictation); below that the line is hidden
    /// entirely (don't show "0m saved" — feels accusatory).
    private var personalizationText: String? {
        let threshold: TimeInterval = 5 * 60
        guard DictationStats.totalSeconds >= threshold else { return nil }
        let savedSeconds = DictationStats.estimatedTimeSavedSeconds
        return "Jot has saved you about \(Self.formatDuration(savedSeconds)) so far."
    }

    /// Duration formatter per spec §6.2:
    ///   • `< 1h` → `"Nm"` (e.g. `"12m"`)
    ///   • `1h–19h` → `"Nh Mm"` (e.g. `"3h 5m"`; drops the `Mm`
    ///     half when minutes round to zero)
    ///   • `≥ 20h` → `"Nh"` (minutes are noise at that scale)
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 {
            return "\(minutes)m"
        }
        if hours >= 20 {
            return "\(hours)h"
        }
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField("Search charities", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Charity list

    private var charityListCard: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            Group {
                if summary == nil, isLoading {
                    loadingState
                } else if summary == nil {
                    emptyErrorState
                } else if filteredCharities.isEmpty {
                    noMatchesState
                } else {
                    charityRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var charityRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(filteredCharities.enumerated()), id: \.element.slug) { index, charity in
                charityRow(charity)

                if index != filteredCharities.count - 1 {
                    Divider()
                        .overlay(Color(nsColor: .separatorColor))
                        .padding(.leading, 18)
                }
            }
        }
    }

    private func charityRow(_ charity: DonationCharity) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(charity.name)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("\(formatCurrency(charity.totalRaisedUSD)) raised · \(donationCountText(charity.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                donationPill(amount: 2, charity: charity)
                donationPill(amount: 10, charity: charity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }

    private func donationPill(amount: Int, charity: DonationCharity) -> some View {
        Button {
            openDonation(amount: amount, charity: charity)
        } label: {
            Text("$\(amount)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.accentColor, in: Capsule(style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Donate \(amount) dollars to \(charity.name)")
        .help("Donate $\(amount) to \(charity.name) via every.org")
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading charities")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 44)
        .accessibilityElement(children: .combine)
    }

    private var emptyErrorState: some View {
        VStack(spacing: 12) {
            Text("Couldn't load — try again")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Button {
                Task { await refresh() }
            } label: {
                Text("Retry")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 28)
                    .background(Color.accentColor, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Attempts to reload donation totals")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 44)
    }

    private var noMatchesState: some View {
        Text("No matches")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 44)
    }

    // MARK: - Total raised

    private var totalRaisedCard: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.map { formatCurrency($0.totalRaisedUSD) } ?? "—")
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .tracking(-1.0)

                Text(summary.map { "raised through Jot · \(supporterCountText($0.totalDonations))" } ?? "raised through Jot · — supporters")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    // MARK: - Footnote

    private var footnote: some View {
        Text(footnoteText)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footnoteText: String {
        guard let summary else {
            return "Donations process through every.org. Last updated —."
        }
        return "Donations process through every.org. Last updated \(relativeUpdatedText(for: summary.lastUpdated))."
    }

    private var heroAccessibilityLabel: String {
        guard let summary else {
            return "Donation totals unavailable"
        }
        return "\(formatCurrency(summary.totalRaisedUSD)) raised through Jot, \(supporterCountText(summary.totalDonations))"
    }

    // MARK: - Ordering / filtering

    private var orderedCharities: [DonationCharity] {
        guard let summary else { return [] }
        let charitiesBySlug = Dictionary(uniqueKeysWithValues: summary.perCharity.map { ($0.slug, $0) })
        let ordered = shuffledOrder.compactMap { charitiesBySlug[$0] }
        let orderedSlugs = Set(ordered.map(\.slug))
        return ordered + summary.perCharity.filter { !orderedSlugs.contains($0.slug) }
    }

    private var filteredCharities: [DonationCharity] {
        guard !searchText.isEmpty else { return orderedCharities }
        return orderedCharities.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Network / cache

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await DonationsService.fetchSummary()
            applySummary(fetched)
            cacheSummary(fetched)
            errorMessage = nil
        } catch {
            if summary == nil {
                loadCachedSummary()
            }
            errorMessage = summary == nil
                ? "Couldn't load — try again"
                : "Couldn't refresh — showing last known totals"
        }
    }

    private func loadCachedSummary() {
        guard summary == nil,
              let cached = DonationsService.decodeCachedSummary(from: cachedSummaryData) else {
            return
        }
        applySummary(cached)
    }

    private func cacheSummary(_ summary: DonationsSummary) {
        guard let data = DonationsService.encodeForCache(summary) else { return }
        cachedSummaryData = data
    }

    private func applySummary(_ next: DonationsSummary) {
        summary = next
        updateShuffledOrder(for: next.perCharity)
    }

    /// Sticky shuffle (spec §3.3): first paint randomises; later
    /// refreshes preserve order, drop slugs the server no longer
    /// returns, and append any new slugs in a fresh shuffle at the
    /// end. Keeps the first impression fair without churning rows
    /// under the user's pointer on refresh.
    private func updateShuffledOrder(for charities: [DonationCharity]) {
        let incomingSlugs = charities.map(\.slug)
        guard !incomingSlugs.isEmpty else {
            shuffledOrder = []
            return
        }

        if shuffledOrder.isEmpty {
            shuffledOrder = incomingSlugs.shuffled()
            return
        }

        let incomingSet = Set(incomingSlugs)
        var nextOrder = shuffledOrder.filter { incomingSet.contains($0) }
        let knownSlugs = Set(nextOrder)
        let newSlugs = incomingSlugs.filter { !knownSlugs.contains($0) }.shuffled()
        nextOrder.append(contentsOf: newSlugs)
        shuffledOrder = nextOrder
    }

    private func openDonation(amount: Int, charity: DonationCharity) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.every.org"
        components.path = "/\(charity.slug)/donate"
        components.queryItems = [URLQueryItem(name: "amount", value: "\(amount)")]
        guard let url = components.url else { return }

        // Optimistic mark — same intent as the old DonationCard
        // mailto-style click handler had (a false-positive is a
        // better UX than re-asking an actual donor — see the card's
        // existing comment / spec §6.6). Moved here from the card's
        // button now that the card's button just opens this sheet.
        donationStore.markDonated()

        openURL(url)
    }

    // MARK: - Formatting

    private func donationCountText(_ count: Int) -> String {
        "\(count) donation\(count == 1 ? "" : "s")"
    }

    private func supporterCountText(_ count: Int) -> String {
        "\(count) supporter\(count == 1 ? "" : "s")"
    }

    private func formatCurrency(_ amount: Double) -> String {
        if amount.rounded() == amount {
            return "$\(Int(amount))"
        }
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func relativeUpdatedText(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "just now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - LiquidGlassCard (macOS shim)

/// macOS port of iOS's `LiquidGlassCard`. iOS draws a near-opaque
/// white card with custom blur + saturation + inset highlight; the
/// Mac equivalent leans on `.regularMaterial` so vibrancy follows
/// the system Appearance automatically, with a hairline
/// `separatorColor` border to keep the card visually contained
/// against any window background. Same `paddingH` / `paddingV`
/// API as the iOS version so the inline call sites are unchanged.
struct LiquidGlassCard<Content: View>: View {
    let paddingH: CGFloat
    let paddingV: CGFloat
    @ViewBuilder let content: Content

    init(
        paddingH: CGFloat = 18,
        paddingV: CGFloat = 14,
        @ViewBuilder content: () -> Content
    ) {
        self.paddingH = paddingH
        self.paddingV = paddingV
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}
