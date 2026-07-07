import SwiftData
import SwiftUI

/// One row in the Recordings list. Accepts a `LibraryItem` so dictation
/// `Recording` rows and `RewriteSession` rows interleave in the same
/// chronological list. Branches internally to a per-kind subview so
/// each case keeps a concrete `@Bindable` for in-place title editing.
struct RecordingRowView: View {
    let item: LibraryItem

    let onRetranscribe: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        switch item {
        case .recording(let r):
            DictationRowView(
                recording: r,
                onRetranscribe: onRetranscribe,
                onReveal: onReveal,
                onDelete: onDelete
            )
        case .rewrite(let s):
            RewriteRowView(
                session: s,
                onDelete: onDelete
            )
        }
    }
}

/// Dictation-row variant: leading `waveform` icon, title + transcript
/// preview, trailing duration. Copy + ellipsis menu are rendered by the
/// parent `RecordingsListView` as siblings OUTSIDE the row's navigation
/// Button so their clicks reach them directly instead of being eaten by
/// the `.plain` Button wrapping this view as its label.
private struct DictationRowView: View {
    @Bindable var recording: Recording

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    let onRetranscribe: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            LibraryRowIcon(systemName: "waveform")
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                preview
            }
            Spacer(minLength: 8)
            // Duration moved into `RecordingsListView.rowTrailingControls`
            // so it sits on the same baseline as the Copy + ⋯ icons.
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
                // Defer the focus mutation off the row's appear/layout
                // pass so AppKit's NSTableView delegate finishes its work
                // first. Setting `@FocusState` synchronously inside
                // `.onAppear` reenters the table delegate.
                .onAppear {
                    DispatchQueue.main.async { titleFocused = true }
                }
        } else {
            Text(recording.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .onTapGesture(count: 2) { beginEditTitle() }
        }
    }

    @ViewBuilder
    private var preview: some View {
        // "Never lose audio" safety net (docs/resilient-transcription/design.md):
        // a pending row's audio is safe on disk but has no transcript yet —
        // say so plainly instead of showing "(empty transcript)", which
        // would read as a real transcription that came back blank.
        if recording.pendingSince != nil {
            PendingTranscriptionChip()
        } else {
            // `.textSelection(.enabled)` was previously applied here. Removed
            // because it makes every row install AppKit text-selection /
            // first-responder machinery during the table row layout pass —
            // a known source of "Application performed a reentrant operation
            // in its NSTableView delegate" warnings on macOS Lists. The full
            // transcript is selectable in `RecordingDetailView`; truncated
            // single-line previews aren't a useful selection target anyway.
            Text(recording.transcript.isEmpty ? "(empty transcript)" : recording.transcript)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
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

/// Rewrite-row variant: leading `wand.and.stars` icon, title + output
/// preview, optional `provider · timestamp` meta line. Copy + ellipsis
/// menu are rendered by the parent `RecordingsListView` as siblings
/// OUTSIDE the row's navigation Button so their clicks reach them
/// directly instead of being eaten by the `.plain` Button wrapping
/// this view as its label.
private struct RewriteRowView: View {
    @Bindable var session: RewriteSession

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LibraryRowIcon(systemName: "wand.and.stars")
            VStack(alignment: .leading, spacing: 4) {
                titleRow
                preview
                metaLine
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 8)
        .contextMenu {
            Button("Copy Output", action: copyOutput)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func copyOutput() {
        guard !session.output.isEmpty else { return }
        guard let pb = AppServices.live?.pasteboard else { return }
        _ = pb.write(session.output)
    }

    @ViewBuilder
    private var titleRow: some View {
        if isEditingTitle {
            TextField("Title", text: $draftTitle, onCommit: commitTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .semibold))
                .focused($titleFocused)
                .onExitCommand { cancelTitle() }
                .onAppear {
                    DispatchQueue.main.async { titleFocused = true }
                }
        } else {
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .onTapGesture(count: 2) { beginEditTitle() }
        }
    }

    private var preview: some View {
        Text(session.output.isEmpty ? "(empty output)" : session.output)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Optional third row: `<provider> · <relative timestamp>` at 11pt
    /// secondary. Provider portion comes from `modelUsedRowLabel` (head
    /// of the stored full label). Hidden entirely when `modelUsed` is
    /// `nil` — only timestamp on its own line would feel orphaned.
    @ViewBuilder
    private var metaLine: some View {
        if let label = session.modelUsedRowLabel {
            Text("\(label) · \(RelativeTimestamp.string(for: session.createdAt))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func beginEditTitle() {
        draftTitle = session.title
        isEditingTitle = true
    }

    private func commitTitle() {
        RecordingStore.rename(session, to: draftTitle)
        isEditingTitle = false
    }

    private func cancelTitle() {
        isEditingTitle = false
    }
}

/// "Never lose audio" safety net (docs/resilient-transcription/design.md):
/// subtle inline affordance for a `Recording` row whose audio is saved but
/// not yet transcribed (`pendingSince != nil`). Deliberately understated —
/// same secondary/orange treatment as `FileTranscriptionIngest`'s
/// `.savedPending` caption in `HomePane` — so it reads as "needs a quick
/// action", not an error.
struct PendingTranscriptionChip: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10.5))
            Text("Needs transcription")
                .font(.system(size: 12))
        }
        .foregroundStyle(.orange)
    }
}

/// Leading-gutter row icon — fixed-width lane so dictation and rewrite
/// rows align identically. 13pt SF Symbol, secondary foreground, ~20pt
/// lane per plan §5.
private struct LibraryRowIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 20, alignment: .center)
            .padding(.top, 1)
    }
}
