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
/// Public list surface. Owns the **pagination window** (`visibleLimit`) and
/// hands it to the inner `PagedRecordingsList`, whose `@Query` fetch limits are
/// rebuilt from it on each bump. Bumping re-inits the inner view → `@Query`
/// refetches a larger window, so live updates (new dictations appearing) are
/// preserved while the list grows on scroll.
struct RecordingsListView: View {
    private let navigationTitle: String
    private let topContent: AnyView?
    /// Rows visible right now. Starts small; grows by `pageSize` when the user
    /// scrolls to the bottom (see `PagedRecordingsList.maybeLoadMore`).
    @State private var visibleLimit = Self.initialPageSize

    static let initialPageSize = 30
    static let pageSize = 30

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

    var body: some View {
        PagedRecordingsList(
            navigationTitle: navigationTitle,
            topContent: topContent,
            visibleLimit: visibleLimit,
            onLoadMore: { visibleLimit += Self.pageSize }
        )
    }
}

/// Reusable recordings browser — date-merged list + inline search + detail
/// navigation. The `@Query` fetch limits are set from `visibleLimit` at init;
/// the parent bumps that to page in more rows.
private struct PagedRecordingsList: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    /// Cross-pane navigation for the AI-search button (→ Ask Jot) and for
    /// consuming a citation-chip tap that wants to open a specific recording.
    @Environment(\.helpNavigator) private var navigator
    @Environment(\.setSidebarSelection) private var setSidebarSelection

    /// Mirrors the sidebar gate: the AI/Ask Jot affordance only appears when
    /// Advanced is on. With Advanced off, Ask Jot is hidden from the sidebar,
    /// so the search sparkle (which routes there) must be hidden too.
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false
    /// Per-kind queries fetch the top `visibleLimit` rows of each kind sorted
    /// by `createdAt` descending. The merge-and-cap below sorts the (≤2N) row
    /// window globally and trims to N. Top-N per kind is sufficient to compute
    /// the global top-N because each per-kind fetch is itself date-sorted
    /// descending — any row in the global top-N must be in its own kind's top-N.
    @Query private var recordings: [Recording]
    @Query private var rewrites: [RewriteSession]

    private let visibleLimit: Int
    private let onLoadMore: () -> Void

    @State private var searchText: String = ""
    /// Active tag filter (exact match, recordings only). Independent of
    /// `searchText`; when set, the result set routes through the UNLIMITED fetch
    /// (design M4) so older tagged recordings aren't hidden behind the paging
    /// window. `nil` = no tag filter.
    @State private var selectedTag: String?
    /// AI-search Stage B: semantic-search controller. Lazily created on first
    /// appear from the environment's `ModelContainer` (a `@State` can't read the
    /// environment at init time). Publishes `semanticMatches`; nil until appear.
    @State private var semanticController: SemanticSearchController?
    @State private var path = NavigationPath()
    @State private var pendingDelete: Recording?
    @State private var pendingDeleteRewrite: RewriteSession?
    @State private var retranscribeError: String?
    private let navigationTitle: String
    private let topContent: AnyView?

    init(
        navigationTitle: String,
        topContent: AnyView?,
        visibleLimit: Int,
        onLoadMore: @escaping () -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.topContent = topContent
        self.visibleLimit = visibleLimit
        self.onLoadMore = onLoadMore

        var rd = FetchDescriptor<Recording>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        rd.fetchLimit = visibleLimit
        _recordings = Query(rd)

        var wd = FetchDescriptor<RewriteSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        wd.fetchLimit = visibleLimit
        _rewrites = Query(wd)
    }

    /// Result set the list renders. Empty search → the current
    /// `visibleLimit`-windowed `@Query` results merged (the window grows as the
    /// user scrolls; see `maybeLoadMore`). Non-empty search → unlimited
    /// `context.fetch`es so older items still match. The fetches re-issue
    /// on every keystroke; bounded by the total counts (a few hundred at
    /// most), and search activates rarely enough that the cost is
    /// acceptable. Falls back to the limited sets if the unlimited fetch
    /// throws.
    private var filteredItems: [LibraryItem] {
        let tag = selectedTag
        // A search OR a tag filter routes through the unlimited fetch + bypasses
        // the paging cap, so older matches/tagged rows still surface (design M4).
        let filtersActive = !searchText.isEmpty || tag != nil

        let recordingsPool: [Recording]
        let rewritesPool: [RewriteSession]
        if filtersActive {
            recordingsPool = unlimitedRecordings() ?? recordings
            rewritesPool = unlimitedRewrites() ?? rewrites
        } else {
            recordingsPool = recordings
            rewritesPool = rewrites
        }

        let needle = searchText.lowercased()

        // AI-search Stage B (review M3): read `semanticMatches` UNCONDITIONALLY
        // on the rendered path — NOT behind the `needle.isEmpty` early-return —
        // so SwiftUI registers the dependency on this `@Observable` set and the
        // async semantic results (which land a beat after the keystroke) trigger
        // a recompute. The substring half stays instant; semantic augments it.
        let semanticMatches = semanticController?.semanticMatches ?? []

        let recordingItems: [LibraryItem] = recordingsPool.compactMap { r in
            // Tag filter (exact, recordings only) — a row must carry the tag.
            if let tag, !r.tags.contains(tag) { return nil }
            if needle.isEmpty { return .recording(r) }
            // Substring ∪ semantic: a row surfaces if its title/transcript/tags
            // contain the needle OR its id is in the semantic match set. Tags are
            // substring-matched only (not semantically indexed — design M4).
            if r.title.lowercased().contains(needle)
                || r.transcript.lowercased().contains(needle)
                || r.tags.contains(where: { $0.contains(needle) })
                || semanticMatches.contains(r.id) {
                return .recording(r)
            }
            return nil
        }

        // A tag filter is recording-specific; rewrites carry no tags, so they're
        // excluded entirely whenever a tag is selected.
        let rewriteItems: [LibraryItem]
        if tag != nil {
            rewriteItems = []
        } else {
            rewriteItems = rewritesPool.compactMap { s in
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
        }

        let merged = (recordingItems + rewriteItems)
            .sorted { $0.createdAt > $1.createdAt }
        // Truncate AFTER the global sort so a fresh recording can't be hidden
        // behind a stale rewrite (or vice versa). Active filters bypass the cap
        // so older matches still surface.
        if filtersActive {
            return merged
        }
        return Array(merged.prefix(visibleLimit))
    }

    /// In-use tags for the filter bar, derived from the currently-loaded
    /// (windowed) recordings — cheap, and recent recordings cover almost all
    /// tags. The selected tag is always included even if it's not in the window.
    /// (The FILTER itself still routes through the unlimited fetch, so selecting
    /// a tag finds every matching recording regardless of this list.)
    private var inUseTags: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for r in recordings {
            for t in r.tags where !seen.contains(t) {
                seen.insert(t)
                ordered.append(t)
            }
        }
        var result = ordered.sorted()
        if let sel = selectedTag, !result.contains(sel) {
            result.insert(sel, at: 0)
        }
        return result
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
                // AI-search Stage B: create the semantic controller from the
                // environment container on first appear, and feed it the search
                // text (debounced inside `search(query:)`). The substring filter
                // in `filteredItems` stays synchronous; the controller's
                // `semanticMatches` augments it asynchronously.
                .onAppear {
                    if semanticController == nil {
                        semanticController = SemanticSearchController(container: context.container)
                    }
                    // Robustness: if the view appears with a pre-populated search
                    // (return-navigation / future deep-link), seed the semantic
                    // query now — `onChange` only fires on subsequent edits.
                    if !searchText.isEmpty {
                        semanticController?.search(query: searchText)
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    semanticController?.search(query: newValue)
                }
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
                // Ask Jot citation-chip tap → open that recording's detail.
                .onChange(of: navigator.pendingOpenRecording) { _, newValue in
                    openPendingRecordingIfNeeded(newValue)
                }
                .onAppear { openPendingRecordingIfNeeded(navigator.pendingOpenRecording) }
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

            // Tag filter chips — only when some recording carries a tag. Tapping
            // toggles an exact tag filter (which routes through the unlimited
            // fetch via `filteredItems`).
            if !inUseTags.isEmpty {
                auxiliaryRow {
                    tagFilterBar
                }
            }

            let items = filteredItems
            if items.isEmpty {
                auxiliaryRow {
                    emptyState
                }
            } else {
                // v1.14: flat list — no Today / Yesterday / Earlier
                // dividers. Date is rendered per-row in
                // `rowTrailingControls` next to the duration.
                ForEach(items) { item in
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
                    .onAppear {
                        // Infinite scroll: when the last rendered row appears
                        // and we filled the current window, page in more.
                        if item.id == items.last?.id {
                            maybeLoadMore(renderedCount: items.count)
                        }
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
            // AI search → open Ask Jot and (if there's a query) run it there.
            // Gated to Advanced: when Advanced is off, Ask Jot is hidden from
            // the sidebar, so this entry point is hidden too.
            if advancedEnabled {
                Button {
                    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !q.isEmpty { navigator.pendingAsk = q }
                    setSidebarSelection(.askJot)
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Ask AI about your recordings")
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

    /// Horizontally-scrolling bar of in-use tags. Tapping a chip toggles the
    /// exact-match tag filter; the active chip is highlighted.
    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(inUseTags, id: \.self) { tag in
                    Button {
                        selectedTag = (selectedTag == tag) ? nil : tag
                    } label: {
                        TagChip(tag: tag, selected: selectedTag == tag)
                            .opacity(selectedTag == nil || selectedTag == tag ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selectedTag == tag ? "Remove filter: tag \(tag)" : "Filter by tag \(tag)")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
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
        let filtering = !searchText.isEmpty || selectedTag != nil
        return VStack(spacing: 8) {
            Image(systemName: filtering ? "magnifyingglass" : "waveform")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(filtering ? "No matches" : "No library items yet")
                .font(.system(size: 13, weight: .semibold))
            Text(filtering
                 ? (selectedTag != nil && searchText.isEmpty
                    ? "No recordings with this tag."
                    : "Try a different search term.")
                 : "Your dictations and rewrites will appear here.")
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

    /// Infinite-scroll trigger. Pages in the next window only when not
    /// searching (search bypasses the limit with an unlimited fetch) and the
    /// current window was filled — once the rendered count plateaus below the
    /// ever-growing limit, the disk is exhausted and this stops bumping.
    private func maybeLoadMore(renderedCount: Int) {
        // Search and tag filters both bypass the paging window (unlimited fetch),
        // so paging must not bump while either is active.
        guard searchText.isEmpty, selectedTag == nil else { return }
        guard renderedCount >= visibleLimit else { return }
        onLoadMore()
    }

    /// Consume a pending "open this recording" request from an Ask Jot citation
    /// tap: fetch by id and push its detail. Clears the navigator field so the
    /// same target re-fires cleanly next time.
    private func openPendingRecordingIfNeeded(_ id: UUID?) {
        guard let id else { return }
        navigator.pendingOpenRecording = nil
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let row = try? context.fetch(descriptor).first {
            path.append(row)
        }
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
                    // Fresh machine output — clear any hand-edited marker.
                    r.editedAt = nil
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
