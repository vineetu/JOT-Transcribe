import AppKit
import SwiftData
import SwiftUI

/// The Recordings browser — date-grouped list + `searchable` toolbar + detail
/// navigation. Keeps selection local to a `NavigationStack` so opening a
/// recording from Home can push the detail without taking over the sidebar.
struct RecordingsListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.transcriber) private var transcriber
    @Query(sort: \Recording.createdAt, order: .reverse)
    private var recordings: [Recording]

    @State private var searchText: String = ""
    @State private var path: [Recording] = []
    @State private var pendingDelete: Recording?
    @State private var retranscribeError: String?

    /// When non-nil, we push this recording onto the stack as soon as the view
    /// appears — lets Home deep-link into detail.
    let pendingOpen: Recording?
    let onConsumedPendingOpen: () -> Void

    private var filtered: [Recording] {
        guard !searchText.isEmpty else { return recordings }
        let needle = searchText.lowercased()
        return recordings.filter {
            $0.title.lowercased().contains(needle)
                || $0.transcript.lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Recordings")
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search recordings")
                .navigationDestination(for: Recording.self) { r in
                    RecordingDetailView(recording: r)
                }
                .alert(
                    "Delete this recording?",
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    )
                ) {
                    Button("Delete", role: .destructive) {
                        if let r = pendingDelete {
                            RecordingStore.delete(r, from: context)
                        }
                        pendingDelete = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text("The audio file and transcript will be removed. This cannot be undone.")
                }
                .alert(
                    "Re-transcribe failed",
                    isPresented: Binding(
                        get: { retranscribeError != nil },
                        set: { if !$0 { retranscribeError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { retranscribeError = nil }
                } message: {
                    Text(retranscribeError ?? "")
                }
                .onAppear {
                    if let pendingOpen {
                        path.append(pendingOpen)
                        onConsumedPendingOpen()
                    }
                }
        }
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            List {
                ForEach(RecordingStore.grouped(filtered), id: \.0.id) { (group, rows) in
                    Section(group.title) {
                        ForEach(rows) { r in
                            Button {
                                path.append(r)
                            } label: {
                                RecordingRowView(
                                    recording: r,
                                    onRetranscribe: { retranscribe(r) },
                                    onReveal: { reveal(r) },
                                    onDelete: { pendingDelete = r }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No recordings yet" : "No matches")
                .font(.system(size: 13, weight: .semibold))
            Text(searchText.isEmpty
                 ? "Your dictations will appear here."
                 : "Try a different search term.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func retranscribe(_ r: Recording) {
        guard let transcriber else {
            retranscribeError = "Transcriber is not available."
            return
        }
        let url = RecordingStore.audioURL(for: r)
        Task {
            do {
                let result = try await transcriber.transcribeFile(url)
                await MainActor.run {
                    r.rawTranscript = result.rawText
                    r.transcript = result.text
                    try? context.save()
                }
            } catch {
                await MainActor.run {
                    retranscribeError = error.localizedDescription
                }
            }
        }
    }

    private func reveal(_ r: Recording) {
        let url = RecordingStore.audioURL(for: r)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
