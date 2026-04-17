import SwiftUI

/// Single-line dismissible "New to Jot?" strip that sits at the top of
/// `HomePane` (design doc §4 / Frontend Directives §1).
///
/// Treatment:
///   • ~36 pt tall, `regularMaterial` background (reads as system chrome,
///     not an ad).
///   • Leading `sparkles` SF Symbol + "New to Jot? See the Basics →"
///     where the text acts as a link into the Help tab.
///   • Trailing `xmark` button dismisses; dismissal persisted via
///     `@AppStorage("jot.home.bannerDismissed")`.
///   • Hairline top/bottom borders match the existing `StatusZone`
///     treatment elsewhere in the window.
///
/// Tapping anywhere in the body navigates to the Help tab and scrolls to
/// `help.basics`. The X dismisses without navigating.
struct BasicsBanner: View {
    @AppStorage("jot.home.bannerDismissed") private var dismissed: Bool = false
    @Environment(\.setSidebarSelection) private var setSidebarSelection

    var body: some View {
        if !dismissed {
            HStack(spacing: 8) {
                Button(action: openBasics) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("New to Jot? See the Basics →")
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss basics banner")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.regularMaterial)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5),
                alignment: .top
            )
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5),
                alignment: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        }
    }

    private func openBasics() {
        setSidebarSelection(.help)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: InfoPopoverButton.scrollToAnchorNotification,
                object: nil,
                userInfo: ["anchor": "help.basics"]
            )
        }
    }
}
