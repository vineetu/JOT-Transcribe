import SwiftUI

// MARK: - SubRowList

/// Vertical stack of sub-rows beneath a hero card.
///
/// Renders the rows inside a rounded container that visually matches the
/// hero card above — same fill, same border weight, same corner radius —
/// so hero + sub-row list read as two stacked sibling blocks. No
/// dividers between rows; grouping comes from the container and row
/// separation comes from per-row vertical padding. Matches Apple's
/// macOS System Settings grouped-list convention.
///
/// Deep-link bridge: when `navigator.pendingExpansion` matches an expandable
/// row's id, the row auto-expands on appear — satisfying the two-phase
/// deep-link contract ("expand before scroll") from `HelpPane`.
struct SubRowList: View {
    let rows: [SubRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                SubRowView(row: row)
                    // `id` is the slug — matches `Feature.expandableRowId`
                    // used by `HelpNavigator.pendingExpansion` so the
                    // scroll-to-slug in `HelpPane` lands here directly.
                    .id(row.id)
            }
        }
        .background(
            RoundedRectangle(
                cornerRadius: HelpSharedStyle.heroCornerRadius,
                style: .continuous
            )
            .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: HelpSharedStyle.heroCornerRadius,
                style: .continuous
            )
            .stroke(
                Color.primary.opacity(HelpSharedStyle.cardBorderOpacity),
                lineWidth: HelpSharedStyle.cardBorderWidth
            )
        )
        // Clip expanded-row tint so it doesn't spill past the rounded
        // corner on the first / last row.
        .clipShape(
            RoundedRectangle(
                cornerRadius: HelpSharedStyle.heroCornerRadius,
                style: .continuous
            )
        )
        // Preserve breathing room between consecutive hero groups.
        .padding(.bottom, 24)
    }
}

// MARK: - SubRowView

/// A single row, expandable or plain.
///
/// - Expandable rows (`row.isExpandable == true`) show a chevron that
///   rotates 90° on expand, are tappable, and reveal a `SubRowDetail`
///   below with a combined fade + slide-from-top transition.
/// - Plain rows have **no chevron**, **no tap handler**, and **no**
///   expanded-state background tint. They render visibly but do not
///   appear interactive (spec §10 smoke #5).
/// - When `navigator.pendingExpansion` matches this row's slug, the row
///   auto-expands on appear. Search matches also force expansion so the
///   matched context is visible to the user.
/// - When `navigator.highlightedFeatureId` matches this row's slug, the
///   row paints the deep-link highlight pulse.
struct SubRowView: View {
    let row: SubRow
    @State private var isExpanded = false
    /// Natural height of the detail view, measured once via a
    /// GeometryReader in `.background` before the height-clipping
    /// outer frame is applied. Used as the target for the frame-height
    /// animation on expand.
    @State private var naturalDetailHeight: CGFloat = 0
    @Environment(\.helpNavigator) private var navigator

    var body: some View {
        // Detail animation contract (height clip, top-anchored):
        //   - Expand: the frame height animates from 0 to the detail's
        //     measured natural height. Content stays anchored at the
        //     top of its frame, so the detail appears to grow DOWNWARD
        //     from the row's bottom edge. Rows below slide down in
        //     sync as the outer VStack height increases.
        //   - Collapse: the frame height animates back to 0. Content
        //     stays top-anchored, so the bottom of the detail is
        //     clipped away first — visually indistinguishable from the
        //     old `.move(edge: .top)` removal, which is what the user
        //     already signed off on.
        //   - No opacity fade, no translation — purely layout.
        //
        // The detail is always in the view tree (not gated on
        // isExpanded) so the `.background` GeometryReader can measure
        // its natural height. When collapsed, the outer `.frame(height: 0)`
        // plus `.clipped()` makes it zero-sized and invisible.
        VStack(spacing: 0) {
            headerRow
            detailContainer
        }
        .clipped()
        .onAppear { applyPendingExpansionIfNeeded() }
        .onChange(of: navigator.pendingExpansion) { _, _ in
            applyPendingExpansionIfNeeded()
        }
    }

    @ViewBuilder
    private var detailContainer: some View {
        if row.isExpandable, let detail = row.detail {
            SubRowDetail(detail: detail)
                // Force vertical self-sizing so the GeometryReader
                // below measures the natural height, not whatever the
                // parent proposes.
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SubRowDetailHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
                .frame(
                    height: isExpanded ? naturalDetailHeight : 0,
                    alignment: .top
                )
                .clipped()
                .allowsHitTesting(isExpanded)
                .onPreferenceChange(SubRowDetailHeightKey.self) { height in
                    if height > 0 {
                        naturalDetailHeight = height
                    }
                }
        }
    }

    fileprivate func toggleExpansion() {
        withAnimation(HelpSharedStyle.expandAnimation) {
            isExpanded.toggle()
        }
    }

    /// Auto-expand when the navigator's `pendingExpansion` slug matches
    /// this row. Also expands if it's already our slug on first appear
    /// (covers the case where deep-link arrived before we mounted).
    private func applyPendingExpansionIfNeeded() {
        guard row.isExpandable else { return }
        guard navigator.pendingExpansion == row.id else { return }
        guard !isExpanded else { return }
        withAnimation(HelpSharedStyle.expandAnimation) {
            isExpanded = true
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(row.name))
                .font(.body)
                .foregroundStyle(row.isExpandable ? .primary : .secondary)
            Spacer()
            if let chipKeys = row.shortcutChip {
                ShortcutChip(chipKeys)
            }
            if row.isExpandable {
                // No `.animation(value:)` here — the tap handler wraps
                // `isExpanded.toggle()` in `withAnimation`, which drives
                // the chevron rotation as part of the same transaction
                // that animates the row height and detail insertion.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // Tap is installed ONLY on expandable rows; plain rows must not
        // appear clickable (spec §10 smoke #5).
        .modifier(
            TapIfExpandableModifier(
                isExpandable: row.isExpandable,
                onTap: toggleExpansion
            )
        )
        // Opaque mask — matches the SubRowList container's fill so the
        // detail can slide behind the row without peeking through. The
        // expansion tint sits on top of the mask when isExpanded.
        .background(
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if isExpanded && row.isExpandable {
                    Color.primary.opacity(0.04)
                }
            }
        )
        .helpHighlightPulse(
            isHighlighted: navigator.highlightedFeatureId == row.id,
            cornerRadius: 6
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(row.name)))
        .accessibilityAddTraits(row.isExpandable ? .isButton : [])
        .accessibilityValue(row.isExpandable ? (isExpanded ? String(localized: "expanded") : String(localized: "collapsed")) : "")
    }
}

/// Attaches a tap gesture only when `isExpandable` — plain rows get no
/// gesture at all. Implemented as a `ViewModifier` so the two branches
/// produce different underlying view trees (SwiftUI can't conditionally
/// apply `.onTapGesture` in a way that also removes the hit area).
private struct TapIfExpandableModifier: ViewModifier {
    let isExpandable: Bool
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if isExpandable {
            content.onTapGesture { onTap() }
        } else {
            content
        }
    }
}

/// Preference key carrying the natural (unclipped) height of a sub-row
/// detail view up to its parent, so the parent can use that value as
/// the animation target for `.frame(height:)`.
private struct SubRowDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - SubRowDetail

/// Rendered under an expanded sub-row. Five optional slots (prose is
/// required, rest are `nil`-skippable) per redesign §3:
///   1. prose
///   2. inline tip (chip + text in a bordered pill)
///   3. warning ("Watch out: " bolded prefix, no colored box)
///   4. "Open in Settings →" link
///   5. customContent (e.g. the multilingual 25-code grid)
struct SubRowDetail: View {
    let detail: SubRowDetailContent
    @Environment(\.setSidebarSelection) private var setSidebarSelection
    @Environment(\.helpNavigator) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(detail.prose))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .budgetCheck(max: BasicsBudget.subRowProse, actual: detail.prose.count)

            if let tip = detail.inlineTip {
                InlineTipView(tip: tip)
            }

            if let warning = detail.warning {
                (Text("Watch out: ").fontWeight(.medium)
                    + Text(LocalizedStringKey(warning)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let settingsLink = detail.settingsLink {
                Button {
                    navigator.pendingSettingsFieldAnchor = settingsLink.anchor
                    setSidebarSelection(.settings(settingsLink.pane))
                } label: {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(settingsLink.label))
                        Image(systemName: "arrow.right")
                    }
                    .font(.footnote)
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens Jot Settings"))
            }

            if let custom = detail.customContent {
                custom
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .background(Color.primary.opacity(0.04))
    }
}

// MARK: - InlineTipView

/// The grey chip + description row used inside an expanded sub-row detail.
/// Small bordered pill, monospaced chip on the left, description text on
/// the right (redesign §3). Reuses `ShortcutChip` for the chip so styling
/// stays in sync with other chip renders across the Help tab.
struct InlineTipView: View {
    let tip: InlineTip

    var body: some View {
        HStack(spacing: 10) {
            ShortcutChip(tip.chip)
            Text(LocalizedStringKey(tip.description))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    Color.primary.opacity(HelpSharedStyle.cardBorderOpacity),
                    lineWidth: HelpSharedStyle.cardBorderWidth
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
