import SwiftData
import SwiftUI

/// One row in the Recordings list. Title is editable in place via double-click
/// — a native Mac pattern (Finder / Mail use the same interaction).
struct RecordingRowView: View {
    @Bindable var recording: Recording

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    let onRetranscribe: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                preview
            }
            Spacer(minLength: 8)
            Text(recording.formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Menu {
                Button("Re-transcribe", action: onRetranscribe)
                Button("Reveal in Finder", action: onReveal)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Re-transcribe", action: onRetranscribe)
            Button("Reveal in Finder", action: onReveal)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var titleRow: some View {
        if isEditingTitle {
            TextField("Title", text: $draftTitle, onCommit: commitTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
                .focused($titleFocused)
                .onExitCommand { cancelTitle() }
                .onAppear { titleFocused = true }
        } else {
            Text(recording.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .onTapGesture(count: 2) { beginEditTitle() }
        }
    }

    private var preview: some View {
        Text(recording.transcript.isEmpty ? "(empty transcript)" : recording.transcript)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func beginEditTitle() {
        draftTitle = recording.title
        isEditingTitle = true
    }

    private func commitTitle() {
        RecordingStore.rename(recording, to: draftTitle)
        isEditingTitle = false
    }

    private func cancelTitle() {
        isEditingTitle = false
    }
}
