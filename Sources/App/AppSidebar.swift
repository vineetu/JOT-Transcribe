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
                Label("Settings", systemImage: "gearshape")
            }

            Label("Help", systemImage: "questionmark.circle")
                .tag(AppSidebarSelection.help)
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
