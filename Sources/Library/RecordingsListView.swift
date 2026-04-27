import AppKit
import SwiftData
import SwiftUI

/// Reusable recordings browser — date-grouped list + `searchable` toolbar +
/// detail navigation. Home uses this as its primary surface and can inject
/// optional content above the grouped recordings.
struct RecordingsListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @Query(sort: \Recording.createdAt, order: .reverse)
    private var recordings: [Recording]

    @State private var searchText: String = ""
    @State private var path: [Recording] = []
    @State private var pendingDelete: Recording?
    @State private var retranscribeError: String?
    private let navigationTitle: String
    private let topContent: AnyView?

    init(navigationTitle: String = "Recordings") {
        self.navigationTitle = navigationTitle
        topContent = nil
    }

    init<TopContent: View>(
        navigationTitle: String = "Recordings",
        @ViewBuilder topContent: () -> TopContent
    ) {
        self.navigationTitle = navigationTitle
        self.topContent = AnyView(topContent())
    }

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
                .navigationTitle(navigationTitle)
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
        }
    }

    private var list: some View {
        List {
            if let topContent {
                auxiliaryRow {
                    topContent
                }
            }

            if filtered.isEmpty {
                auxiliaryRow {
                    emptyState
                }
            } else {
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
        }
        .listStyle(.inset)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func auxiliaryRow<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func retranscribe(_ r: Recording) {
        let transcriber = transcriberHolder.transcriber
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
