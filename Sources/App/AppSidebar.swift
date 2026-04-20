import SwiftUI

/// The unified window's left source-list.
///
/// Layout order (design doc §1 + sidebar treatment in Frontend Directives):
///   Home · Library · Settings (expanded, 5 children) · Help
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
    @State private var settingsExpanded: Bool = true

    var body: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house")
                .tag(AppSidebarSelection.home)

            Label("Library", systemImage: "waveform")
                .tag(AppSidebarSelection.library)

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

            Label("About", systemImage: "info.circle")
                .tag(AppSidebarSelection.about)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    /// A Settings sub-row with the subordinate-tint treatment:
    /// secondary-color icon, primary-color label.
    @ViewBuilder
    private func subRow(
        title: String,
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
