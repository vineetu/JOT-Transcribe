import AppKit
import SwiftData
import SwiftUI

/// Home's quick-access card: title, two-line transcript preview, Copy + Open
/// buttons. Queries the most recent `Recording` directly so it stays in sync
/// with writes from `RecordingPersister` without any extra plumbing.
struct LastTranscriptionCard: View {
    @Query(
        sort: \Recording.createdAt,
        order: .reverse
    ) private var recordings: [Recording]

    let onOpen: (Recording) -> Void

    private var latest: Recording? { recordings.first }

    var body: some View {
        GroupBox {
            if let latest {
                populated(latest)
            } else {
                empty
            }
        }
        .groupBoxStyle(.automatic)
        .frame(maxWidth: 520)
    }

    private var empty: some View {
        HStack {
            Text("No dictations yet — press the button to start.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func populated(_ r: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(RelativeTimestamp.string(for: r.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(r.transcript.isEmpty ? "(empty transcript)" : r.transcript)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Copy") { copy(r.transcript) }
                    .buttonStyle(.borderless)
                Button("Open in Recordings") { onOpen(r) }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(.system(size: 12))
        }
        .padding(.vertical, 4)
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
