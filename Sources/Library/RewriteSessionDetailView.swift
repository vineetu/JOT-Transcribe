import AppKit
import SwiftData
import SwiftUI

/// Detail surface for a single `RewriteSession` row. Three-pane layout:
/// Selection (input) → Instruction → Output. Output is the primary
/// visual block (semibold, mirrors dictation transcript treatment) since
/// it's "what the user produced". No playback / no re-transcribe / no
/// reveal-in-Finder — rewrite rows have no associated audio file.
struct RewriteSessionDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: RewriteSession

    @State private var pendingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DetailMetrics.blockSpacing) {
                header
                instructionBlock
                selectionBlock
                outputBlock
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: DetailMetrics.pageMeasure, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .toolbar { toolbarContent }
        .alert(
            "Delete this rewrite?",
            isPresented: $pendingDelete
        ) {
            Button("Delete", role: .destructive) {
                RecordingStore.delete(session, from: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rewrite session will be removed. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var flavorLabel: String {
        switch session.flavor {
        case "voice": return "Rewrite with Voice"
        case "fixed": return "Rewrite"
        default: return "Rewrite"
        }
    }

    private var header: some View {
        DetailHeader(title: $session.title) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                // Per persistence plan §5: `flavor · modelUsed` answers
                // "what kind + what model produced this output." Omit the
                // model when `modelUsed == nil` (legacy / Apple-Intel-only).
                if let model = session.modelUsed, !model.isEmpty {
                    Text("\(flavorLabel) · \(model)")
                } else {
                    Text(flavorLabel)
                }
            }
        }
    }

    // MARK: - Panes (stacked reading sections: Instruction → Original → Rewritten)

    private var instructionBlock: some View {
        ReadingSection(label: "Instruction") {
            ReadingProse(text: session.instructionText, placeholder: "(no instruction)")
        }
    }

    private var selectionBlock: some View {
        ReadingSection(label: "Original") {
            ReadingProse(text: session.selectionText, placeholder: "(no selection)")
        }
    }

    private var outputBlock: some View {
        ReadingSection(label: "Rewritten") {
            ReadingProse(text: session.output, emphasized: true, placeholder: "(empty output)")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                copyOutput()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func copyOutput() {
        guard let pb = AppServices.live?.pasteboard else { return }
        _ = pb.write(session.output)
    }
}
