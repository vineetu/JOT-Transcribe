import SwiftUI

/// Disclosure surface for the base-URL override. Hidden by default to
/// keep the AI pane clean for the 95% of users on vendor-public
/// endpoints; expanded automatically when one of three conditions
/// holds:
///
///   1. `storedBaseURL != defaultBaseURL` — the user has overridden
///      it (in this session or a previous one); they should see it.
///   2. `justRanTestConnection` — Test Connection just fired this
///      session; surfacing the URL makes "what got tested" obvious.
///   3. `userClickedDisclosure` — manual expand.
///
/// The third condition latches per-render. The first two are derived
/// each render — the parent passes them in. The component is purely
/// presentational: it owns no AppStorage of its own.
struct EndpointDisclosure: View {
    @Binding var baseURL: String
    let defaultBaseURL: String
    /// Set by the parent after a Test Connection run (success or
    /// failure). The plan's state machine keeps it true for the
    /// rest of the session.
    let justRanTestConnection: Bool

    /// User-toggled latch. Local @State because it doesn't survive
    /// across pane appearances — re-opening the pane should re-hide
    /// the URL field unless one of the other conditions still holds.
    @State private var userClickedDisclosure: Bool = false

    private var hasCustomURL: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        return trimmed != defaultBaseURL
    }

    private var isExpanded: Bool {
        hasCustomURL || justRanTestConnection || userClickedDisclosure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isExpanded {
                expandedBody
            } else {
                collapsedBody
            }
        }
    }

    @ViewBuilder
    private var collapsedBody: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                userClickedDisclosure = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Use a custom endpoint (company proxy, self-hosted, etc.)")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedBody: some View {
        HStack(spacing: 4) {
            Button {
                // Only the user-latch can flip back; the other two
                // conditions are computed from props the parent owns
                // (a non-default URL or a just-ran test won't collapse
                // until the parent clears them).
                if !hasCustomURL && !justRanTestConnection {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        userClickedDisclosure = false
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(hasCustomURL || justRanTestConnection)
            .help(
                hasCustomURL || justRanTestConnection
                    ? "Pinned open: the stored endpoint isn't the default, or a test just ran."
                    : "Hide the custom endpoint field"
            )
            Text("Custom endpoint")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if hasCustomURL {
                Button("Reset to default") {
                    baseURL = ""
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        TextField("Base URL (leave empty for default)", text: $baseURL)
            .textFieldStyle(.roundedBorder)
        Text("Use this to route requests through a company gateway or a self-hosted OpenAI-compatible API. Default: \(defaultBaseURL)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
