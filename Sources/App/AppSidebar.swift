import SwiftUI

/// The unified window's left source-list.
///
/// Layout order:
///   Home · Settings (expanded, 6 children) · Help · Ask Jot · About
///
/// - Expanded by default — most "Open Jot…" clicks are settings-adjacent,
///   so showing the five sub-items saves a click (design doc §D, option D1).
/// - No dividers between rows — the native source-list grouping reads
///   clean enough at this count.
/// - Sub-item icons use the *subordinate* tint (secondary foreground on
///   the SF Symbol) to match System Settings' second-level rows.
/// - The "General" sub-item uses `slider.horizontal.3` rather than
///   `gearshape` so it doesn't duplicate the parent's icon.
struct AppSidebar: View {
    @Binding var selection: AppSidebarSelection
    /// Whether Apple Intelligence is currently available on this Mac.
    /// When `false`, the "Ask Jot" row still renders (and is still
    /// selectable so the pane can show its reason-specific message),
    /// but the label paints with `.secondary` tint so the entry reads
    /// as a subordinate/disabled affordance — matches spec §2 table:
    /// "Sidebar item visible but muted."
    let askJotAvailable: Bool
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @State private var settingsExpanded: Bool = true

    var body: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house")
                .tag(AppSidebarSelection.home)

            DisclosureGroup(isExpanded: $settingsExpanded) {
                subRow(
                    title: "General",
                    systemImage: "slider.horizontal.3",
                    tag: .settings(.general)
                )
                subRow(
                    title: "Transcription",
                    systemImage: "waveform.badge.mic",
                    tag: .settings(.transcription)
                )
                // Vocabulary boost is incompatible with the JA-tokenized
                // primary model (`docs/plans/japanese-support.md` §C):
                // hide the entry while JA is primary so users don't add
                // terms that can't apply. The user's saved list and the
                // master toggle preference persist — the row reappears
                // when primary swaps back to a European model.
                if transcriberHolder.primaryModelID != .tdt_0_6b_ja {
                    subRow(
                        title: "Vocabulary",
                        systemImage: "text.book.closed",
                        tag: .settings(.vocabulary)
                    )
                }
                subRow(
                    title: "Sound",
                    systemImage: "speaker.wave.2",
                    tag: .settings(.sound)
                )
                subRow(
                    title: "AI",
                    systemImage: "sparkles",
                    tag: .settings(.ai)
                )
                subRow(
                    title: "Shortcuts",
                    systemImage: "command",
                    tag: .settings(.shortcuts)
                )
            } label: {
                // macOS 26.4 sidebar idiom: clicking the group header routes
                // to the group's default child (General) AND keeps the group
                // expanded — matches System Settings behavior. `DisclosureGroup`
                // on SwiftUI 7 (Xcode 26.4.1) has no selection semantics on its
                // label, and `List(selection:)` only tracks tags on leaf rows,
                // so we drive the behavior with a `Button(.plain)`. Button is
                // chosen over a bare `.onTapGesture` so VoiceOver announces
                // a button role, keyboard activation works (Space / Return),
                // and focus traversal is standard — per Apple's SwiftUI 7
                // guidance to prefer controls over tap gestures for
                // button-like interactions. The disclosure chevron rendered
                // as DisclosureGroup chrome on the trailing edge continues to
                // handle its own tap for users who explicitly want to
                // collapse the group.
                Button {
                    selection = .settings(.general)
                    settingsExpanded = true
                } label: {
                    HStack(spacing: 0) {
                        Label("Settings", systemImage: "gearshape")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings at General.")
            }

            Label("Help", systemImage: "questionmark.circle")
                .tag(AppSidebarSelection.help)

            askJotRow

            Label("About", systemImage: "info.circle")
                .tag(AppSidebarSelection.about)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    /// Ask Jot entry between Help and About. When Apple Intelligence
    /// is unavailable, the label paints `.secondary` (muted) but the
    /// row stays selectable — clicking still opens `AskJotView`, which
    /// shows the reason-specific disabled-state message and a
    /// "Browse the Help tab →" link.
    @ViewBuilder
    private var askJotRow: some View {
        if askJotAvailable {
            Label("Ask Jot", systemImage: "sparkles")
                .tag(AppSidebarSelection.askJot)
        } else {
            Label {
                Text("Ask Jot")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
            }
            .tag(AppSidebarSelection.askJot)
        }
    }

    /// A Settings sub-row with the subordinate-tint treatment:
    /// secondary-color icon, primary-color label.
    @ViewBuilder
    private func subRow(
        title: LocalizedStringKey,
        systemImage: String,
        tag: AppSidebarSelection
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .tag(tag)
    }
}
