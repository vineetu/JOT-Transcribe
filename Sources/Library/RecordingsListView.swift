import AppKit
import SwiftData
import SwiftUI

/// Reusable recordings browser — date-grouped list + `searchable` toolbar +
/// detail navigation. Home uses this as its primary surface and can inject
/// optional content above the grouped recordings.
///
/// The list interleaves dictation `Recording` rows and `RewriteSession`
/// rows in chronological order (descending by `createdAt`). Each row's
/// kind is differentiated by a leading SF Symbol; both kinds push their
/// concrete model onto the navigation path and resolve to a per-kind
/// detail view via `.navigationDestination`.
struct RecordingsListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    /// Per-kind queries fetch the top `mergedRowCap` rows of each kind
    /// sorted by `createdAt` descending. The merge-and-cap below sorts
    /// the (≤2N) row window globally and trims to N. Top-N per kind is
    /// sufficient to compute the global top-N because each per-kind
    /// fetch is itself date-sorted descending — any row that would be
    /// in the global top-N must be in its own kind's top-N.
    @Query(Self.recordingsDescriptor)
    private var recordings: [Recording]
    @Query(Self.rewritesDescriptor)
    private var rewrites: [RewriteSession]

    private static let mergedRowCap = 50

    private static var recordingsDescriptor: FetchDescriptor<Recording> {
        var d = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        d.fetchLimit = mergedRowCap
        return d
    }

    private static var rewritesDescriptor: FetchDescriptor<RewriteSession> {
        var d = FetchDescriptor<RewriteSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        d.fetchLimit = mergedRowCap
        return d
    }

    @State private var searchText: String = ""
    @State private var path = NavigationPath()
    @State private var pendingDelete: Recording?
    @State private var pendingDeleteRewrite: RewriteSession?
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

    /// Result set the list renders. Empty search → the limited 50-row
    /// `@Query` results merged. Non-empty search → unlimited
    /// `context.fetch`es so older items still match. The fetches re-issue
    /// on every keystroke; bounded by the total counts (a few hundred at
    /// most), and search activates rarely enough that the cost is
    /// acceptable. Falls back to the limited sets if the unlimited fetch
    /// throws.
    private var filteredItems: [LibraryItem] {
        let recordingsPool: [Recording]
        let rewritesPool: [RewriteSession]
        if searchText.isEmpty {
            recordingsPool = recordings
            rewritesPool = rewrites
        } else {
            recordingsPool = unlimitedRecordings() ?? recordings
            rewritesPool = unlimitedRewrites() ?? rewrites
        }

        let needle = searchText.lowercased()

        let recordingItems: [LibraryItem] = recordingsPool.compactMap { r in
            if needle.isEmpty { return .recording(r) }
            if r.title.lowercased().contains(needle) || r.transcript.lowercased().contains(needle) {
                return .recording(r)
            }
            return nil
        }

        let rewriteItems: [LibraryItem] = rewritesPool.compactMap { s in
            if needle.isEmpty { return .rewrite(s) }
            if s.title.lowercased().contains(needle)
                || s.selectionText.lowercased().contains(needle)
                || s.instructionText.lowercased().contains(needle)
                || s.output.lowercased().contains(needle)
                || (s.modelUsed?.lowercased().contains(needle) ?? false) {
                return .rewrite(s)
            }
            return nil
        }

        let merged = (recordingItems + rewriteItems)
            .sorted { $0.createdAt > $1.createdAt }
        // Truncate AFTER the global sort so a fresh recording can't be
        // hidden behind a stale rewrite (or vice versa). Search results
        // bypass the cap so older matches still surface.
        if searchText.isEmpty {
            return Array(merged.prefix(Self.mergedRowCap))
        }
        return merged
    }

    private func unlimitedRecordings() -> [Recording]? {
        let descriptor = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try? context.fetch(descriptor)
    }

    private func unlimitedRewrites() -> [RewriteSession]? {
        let descriptor = FetchDescriptor<RewriteSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try? context.fetch(descriptor)
    }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(navigationTitle)
                // v1.14: searchable moved out of the toolbar into a
                // list-row filter just above the rows (see `inlineSearch`
                // in `list`). The toolbar position read as a global app
                // command; placing it inline against the list makes it
                // unambiguous that it filters the list below.
                .onReceive(NotificationCenter.default.publisher(for: .jotRecentsOpenRecording)) { note in
                    // v1.14: the overlay pill's "Saved to Recents" tap
                    // posts this. Look up the Recording by its audio
                    // filename (set by `RecordingPersister.persist`) and
                    // push it onto the navigation path so the user lands
                    // on the transcript detail.
                    guard let audioFile = note.userInfo?["audioFileName"] as? String else { return }
                    var descriptor = FetchDescriptor<Recording>(
                        predicate: #Predicate { $0.audioFileName == audioFile }
                    )
                    descriptor.fetchLimit = 1
                    if let row = try? context.fetch(descriptor).first {
                        path.append(row)
                    }
                }
                .navigationDestination(for: Recording.self) { r in
                    RecordingDetailView(recording: r)
                }
                .navigationDestination(for: RewriteSession.self) { s in
                    RewriteSessionDetailView(session: s)
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
                    "Delete this rewrite?",
                    isPresented: Binding(
                        get: { pendingDeleteRewrite != nil },
                        set: { if !$0 { pendingDeleteRewrite = nil } }
                    )
                ) {
                    Button("Delete", role: .destructive) {
                        if let s = pendingDeleteRewrite {
                            RecordingStore.delete(s, from: context)
                        }
                        pendingDeleteRewrite = nil
                    }
                    Button("Cancel", role: .cancel) { pendingDeleteRewrite = nil }
                } message: {
                    Text("The rewrite session will be removed. This cannot be undone.")
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

            // v1.14: inline search just above the rows. Renders as a
            // list row with no separator so it visually anchors the
            // list below it. The toolbar `.searchable` was removed
            // because it read as a window-level command rather than a
            // list filter.
            auxiliaryRow {
                inlineSearch
            }

            if filteredItems.isEmpty {
                auxiliaryRow {
                    emptyState
                }
            } else {
                // v1.14: flat list — no Today / Yesterday / Earlier
                // dividers. Date is rendered per-row in
                // `rowTrailingControls` next to the duration.
                ForEach(filteredItems) { item in
                    // Why an outer HStack with the Button + Copy +
                    // Menu as siblings (instead of `Button { } label: {
                    // entireRow }`): SwiftUI's `.plain` button style
                    // on macOS sends every click in its bounds to
                    // the Button's action. If Copy is a *child* of
                    // the Button's label, the click is eaten before
                    // CopyTranscriptButton ever sees it. Pulling
                    // Copy and the ellipsis Menu out so they sit
                    // next to the Button (not inside it) means each
                    // gets its own native click. The Menu used to
                    // happen to work as a child because it
                    // registers an AppKit-level NSMenu handler that
                    // beats the SwiftUI Button gesture system, but
                    // there's no equivalent escape hatch for a
                    // plain action button — the only reliable fix
                    // is to stop nesting them.
                    HStack(spacing: 0) {
                        Button {
                            switch item {
                            case .recording(let r): path.append(r)
                            case .rewrite(let s): path.append(s)
                            }
                        } label: {
                            RecordingRowView(
                                item: item,
                                onRetranscribe: {
                                    if case .recording(let r) = item { retranscribe(r) }
                                },
                                onReveal: {
                                    if case .recording(let r) = item { reveal(r) }
                                },
                                onDelete: {
                                    switch item {
                                    case .recording(let r): pendingDelete = r
                                    case .rewrite(let s): pendingDeleteRewrite = s
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        rowTrailingControls(for: item)
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Inline search field rendered as a list row, sitting just above
    /// the recording rows so it reads as a list filter rather than a
    /// global app command. Resting fill matches the Dictate pill's
    /// `Color.primary.opacity(0.06)` tone so the two "light affordance"
    /// elements above the list read as a coherent set.
    private var inlineSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search recordings", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Per-item trailing widgets (Copy + ellipsis Menu) rendered as a
    /// SIBLING of the row's navigation Button — see the long comment at
    /// the row construction site for why this can't sit inside the
    /// Button's label. The visual placement matches the previous nested
    /// layout because both the Button label and these controls share the
    /// outer `HStack(spacing: 0)`.
    @ViewBuilder
    private func rowTrailingControls(for item: LibraryItem) -> some View {
        // Inner HStack so the trailing widgets carry their own internal
        // spacing without depending on the outer `spacing: 0` HStack that
        // the navigation Button + this group share. For dictation rows we
        // also include the duration here so it lines up with Copy + ⋯
        // instead of floating up on the title baseline.
        HStack(spacing: 6) {
            switch item {
            case .recording(let r):
                Text(r.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Text(Self.shortDate(r.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                CopyTranscriptButton(text: r.transcript)

                Menu {
                    Button("Re-transcribe") { retranscribe(r) }
                    Button("Reveal in Finder") { reveal(r) }
                    Divider()
                    Button("Delete", role: .destructive) { pendingDelete = r }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

            case .rewrite(let s):
                Text(Self.shortDate(s.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                CopyTranscriptButton(
                    text: s.output,
                    accessibilityLabel: "Copy output",
                    helpLabel: "Copy output",
                    emptyHelpLabel: "No output to copy"
                )

                Menu {
                    Button("Copy Output") { copyRewriteOutput(s) }
                    Divider()
                    Button("Delete", role: .destructive) { pendingDeleteRewrite = s }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    /// Compact absolute date used in the per-row metadata. Same year
    /// drops the year for brevity ("May 28"); cross-year shows the year
    /// ("May 28 '25") so an old recording reads correctly.
    private static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        }
        return formatter.string(from: date)
    }

    private func copyRewriteOutput(_ s: RewriteSession) {
        guard !s.output.isEmpty else { return }
        guard let pb = AppServices.live?.pasteboard else { return }
        _ = pb.write(s.output)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "waveform" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No library items yet" : "No matches")
                .font(.system(size: 13, weight: .semibold))
            Text(searchText.isEmpty
                 ? "Your dictations and rewrites will appear here."
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
                // List-row re-transcribe only rewrites transcript text; it never
                // commits provenance, so it must not touch the shared slot.
                let result = try await transcriber.transcribeFile(url, recordsProvenance: false)
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
