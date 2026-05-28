import SwiftUI

/// The unified window's left source-list.
///
/// Layout order (Advanced ON):
///   Recents · Settings (expanded, sub-rows including Vocabulary) · Help · Ask Jot · About
///
/// Layout order (Advanced OFF — v1.13 slim mode):
///   Recents · Settings (no Vocabulary sub-row) · Help · About
///
/// - Settings group expand/collapse state is persisted via
///   `@AppStorage("jot.sidebar.settingsExpanded")`. Default expanded for
///   new and existing users; once collapsed it stays collapsed across
///   relaunches.
/// - Per Decision #8, clicking the "Settings" header navigates to General
///   but does NOT force-expand the group — matches macOS System Settings.
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
    /// v1.13: persisted across launches. Default expanded for both new
    /// and existing users. Decision #8: clicking the header navigates
    /// to General without changing this state — only the chevron toggles.
    @AppStorage("jot.sidebar.settingsExpanded") private var settingsExpanded: Bool = true
    /// v1.13: master toggle for the "Advanced" surface. Off hides the
    /// Vocabulary sub-row and the top-level Ask Jot row.
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false

    var body: some View {
        List(selection: $selection) {
            Label("Recents", systemImage: "house")
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
                if Features.speakerLabels {
                    subRow(
                        title: "Speaker labels",
                        systemImage: "person.wave.2",
                        tag: .settings(.speakerLabels)
                    )
                }
                // Vocabulary boost is incompatible with the JA-tokenized
                // primary model (`docs/plans/japanese-support.md` §C):
                // hide the entry while JA is primary so users don't add
                // terms that can't apply. The user's saved list and the
                // master toggle preference persist — the row reappears
                // when primary swaps back to a European model.
                // v1.13: additionally gated behind Advanced.
                if advancedEnabled && transcriberHolder.primaryModelID != .tdt_0_6b_ja {
                    subRow(
                        title: "Vocabulary",
                        systemImage: "text.book.closed",
                        tag: .settings(.vocabulary)
                    )
                }
                subRow(
                    title: "Prompts",
                    systemImage: "text.bubble",
                    tag: .settings(.prompts)
                )
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
                // to the group's default child (General). `DisclosureGroup`
                // on SwiftUI 7 (Xcode 26.4.1) has no selection semantics on its
                // label, and `List(selection:)` only tracks tags on leaf rows,
                // so we drive the behavior with a `Button(.plain)`. Button is
                // chosen over a bare `.onTapGesture` so VoiceOver announces
                // a button role, keyboard activation works (Space / Return),
                // and focus traversal is standard — per Apple's SwiftUI 7
                // guidance to prefer controls over tap gestures for
                // button-like interactions. The disclosure chevron rendered
                // as DisclosureGroup chrome on the trailing edge handles
                // its own tap for users who want to collapse/expand the
                // group; the header click is navigate-only per Decision #8
                // so an incidental click doesn't re-expand a deliberately
                // collapsed group.
                Button {
                    selection = .settings(.general)
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

            if advancedEnabled {
                askJotRow
            }

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
