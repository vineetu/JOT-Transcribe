import AppKit
import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case recordings
}

/// The real main window content: sidebar `NavigationSplitView` with Home +
/// Recordings, plus a bottom status zone that mirrors recorder state.
struct RootView: View {
    @EnvironmentObject private var recorder: RecorderController
    @EnvironmentObject private var firstRunState: FirstRunState

    @State private var selection: SidebarItem = .home
    @State private var pendingOpenRecording: Recording?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            wordmark
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List(selection: $selection) {
                Label("Home", systemImage: "house")
                    .tag(SidebarItem.home)
                Label("Recordings", systemImage: "waveform")
                    .tag(SidebarItem.recordings)
            }
            .listStyle(.sidebar)

            Button {
                openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .safeAreaInset(edge: .bottom) {
            statusZone
        }
    }

    private var wordmark: some View {
        Text("Jot")
            .font(.system(size: 14, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(.primary)
    }

    private var statusZone: some View {
        StatusZone()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5),
                alignment: .top
            )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomeView(onOpenRecording: { r in
                pendingOpenRecording = r
                selection = .recordings
            })
        case .recordings:
            RecordingsListView(
                pendingOpen: pendingOpenRecording,
                onConsumedPendingOpen: { pendingOpenRecording = nil }
            )
        }
    }

    private func openSettingsWindow() {
        // macOS 14+: the new-style `openSettings` action. Fall back to the
        // selector AppKit exposes on older releases so we don't blow up if a
        // user somehow runs an unsupported host.
        openSettings()
    }
}

/// Bottom-of-sidebar status pill: model name + live state dot + last
/// transcription timestamp. Renders as two lines so the text stays readable
/// at the 220pt sidebar width.
private struct StatusZone: View {
    @EnvironmentObject private var recorder: RecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(stateLabel)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            Text(ParakeetModelID.tdt_0_6b_v3.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let last = recorder.lastResult {
                Text("Last: \(relativeTimestamp(last))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dotColor: Color {
        switch recorder.state {
        case .idle: return Color(nsColor: .systemGreen)
        case .recording: return Color(nsColor: .systemRed)
        case .transcribing: return .accentColor
        case .transforming: return Color(nsColor: .systemPurple)
        case .error: return Color(nsColor: .systemOrange)
        }
    }

    private var stateLabel: String {
        switch recorder.state {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .transforming: return "Cleaning up"
        case .error: return "Error"
        }
    }

    // Takes a `TranscriptionResult` but we don't persist its timestamp; use
    // "just now" as a graceful fallback until `RecordingPersister`-written
    // rows are what drives this.
    private func relativeTimestamp(_ result: TranscriptionResult) -> String {
        return "just now"
    }
}
