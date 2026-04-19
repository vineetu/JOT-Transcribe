import KeyboardShortcuts
import SwiftData
import SwiftUI

/// Landing view for the unified Jot window (design doc §4 / §8).
///
/// Top-to-bottom:
///   1. `BasicsBanner` — dismissible "New to Jot?" strip. Hidden once
///      dismissed via `@AppStorage`.
///   2. Primary glance — the live dictation hotkey rendered from
///      `KeyboardShortcuts.getShortcut(for: .toggleRecording)`, so
///      rebinding the shortcut in Settings is reflected here without
///      manual sync.
///   3. Recent — up to 5 most-recent `Recording` rows. Clicking a row
///      navigates the sidebar to Library and posts a notification so
///      Library scrolls to that recording.
///
/// Home is intentionally short — users don't spend time here; it's a
/// waypoint, not a destination.
struct HomePane: View {
    @Query(sort: \Recording.createdAt, order: .reverse)
    private var recent: [Recording]

    @Environment(\.setSidebarSelection) private var setSidebarSelection

    /// Force the glance HStack to re-read the live shortcut whenever the
    /// user rebinds it — `KeyboardShortcuts` itself posts no change
    /// notification we can bind to, so we observe the change via a
    /// shortcut-rebinding listener installed at `onAppear`.

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BasicsBanner()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                glance
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                if !recentRows.isEmpty {
                    recentSection
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 0)
            }
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Glance

    private var glance: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)

            Text("Press ")
                .font(.system(size: 15))
                .foregroundStyle(.primary)
            + Text(shortcutDisplay)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            + Text(" to dictate")
                .font(.system(size: 15))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
    }

    private var shortcutDisplay: String {
        if let s = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            return s.description
        }
        return "(not set)"
    }

    // MARK: - Recent

    private var recentRows: [Recording] {
        Array(recent.prefix(5))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(spacing: 0) {
                ForEach(recentRows) { r in
                    Button {
                        open(r)
                    } label: {
                        recentRow(r)
                    }
                    .buttonStyle(.plain)

                    if r.id != recentRows.last?.id {
                        Divider()
                            .padding(.leading, 10)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func recentRow(_ r: Recording) -> some View {
        HStack(spacing: 10) {
            Text(r.title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(r.formattedDuration)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            CopyTranscriptButton(text: r.transcript, pointSize: 11)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func open(_ r: Recording) {
        setSidebarSelection(.library)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: HomePane.openRecordingNotification,
                object: nil,
                userInfo: ["id": r.id]
            )
        }
    }

    /// Notification posted when a Home row is clicked. Library
    /// subscribes and scrolls to the recording with the matching `id`.
    ///
    /// `userInfo["id"]` is a `UUID` (the `Recording.id`).
    static let openRecordingNotification = Notification.Name("jot.home.openRecording")
}
