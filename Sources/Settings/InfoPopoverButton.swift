import SwiftUI

/// The trailing `info.circle` affordance used on every configurable row
/// in the unified window. Tapping the button opens a ~320 pt popover
/// with a short "definition + When on: concrete effect" explanation
/// (design doc §3 / Frontend Directives §2).
///
/// When a `helpAnchor` is provided, the popover renders a "Learn more →"
/// footer that closes the popover, navigates the sidebar to `.help`,
/// and posts `jot.help.scrollToAnchor` with the anchor ID so
/// `HelpPane` can scroll the deep-link target into view.
///
/// The `.help(…)` hover tooltip on the underlying controls is retained
/// elsewhere as a redundant affordance (design doc §7). This popover
/// is the primary, discoverable surface.
struct InfoPopoverButton: View {
    /// Popover headline — typically the field name, rendered as `.headline`.
    let title: String
    /// Body copy: 2–4 sentences, "definition + When on: concrete effect."
    let message: String
    /// Optional anchor ID into `HelpPane`. When present, renders the
    /// "Learn more →" footer; when nil, the popover has no footer.
    let helpAnchor: String?

    @Environment(\.setSidebarSelection) private var setSidebarSelection
    @State private var isShown: Bool = false

    init(title: String, body: String, helpAnchor: String? = nil) {
        self.title = title
        self.message = body
        self.helpAnchor = helpAnchor
    }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More info about \(title)")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            popoverContent
                .frame(width: 320)
                .padding(14)
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let helpAnchor {
                Button {
                    isShown = false
                    setSidebarSelection(.help)
                    // Post after the sidebar selection has been mutated so
                    // HelpPane is mounted (or re-foregrounded) by the time
                    // it observes the notification.
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: InfoPopoverButton.scrollToAnchorNotification,
                            object: nil,
                            userInfo: ["anchor": helpAnchor]
                        )
                    }
                } label: {
                    Text("Learn more →")
                        .font(.footnote)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    /// Notification name posted when a popover's "Learn more →" footer is
    /// tapped. `HelpPane` subscribes and uses `ScrollViewReader` to scroll
    /// the target anchor into view.
    ///
    /// `userInfo["anchor"]` carries the anchor ID as a `String` (the same
    /// string the target subsection passes to `.id(…)` inside `HelpPane`).
    static let scrollToAnchorNotification = Notification.Name("jot.help.scrollToAnchor")
}
