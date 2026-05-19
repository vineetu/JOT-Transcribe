import Combine
import Foundation

/// Drives the SwiftUI palette. Holds the live query string, the
/// currently-focused row, and exposes the ranker output as published
/// arrays the view can bind to.
@MainActor
final class PromptPickerViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { reload() }
    }
    @Published private(set) var sections: [PromptRanker.Section] = []
    @Published private(set) var searchRows: [PromptRanker.Row] = []
    /// Index into the flat list (sections flattened, or searchRows
    /// directly when query is non-empty). Wrapped to the valid range
    /// by `moveFocus(by:)`.
    @Published var focusedIndex: Int = 0
    /// True when ⌥⏎ is held — pops a preview drawer alongside the focused
    /// row showing the sample input/output and provider compatibility.
    @Published var isPreviewOpen: Bool = false

    private let store: PromptStore
    private let activeProvider: String?
    private let onApply: (Prompt) -> Void
    private let onClose: () -> Void
    private let onTogglePin: (String) -> Void

    init(
        store: PromptStore,
        activeProvider: String?,
        onApply: @escaping (Prompt) -> Void,
        onClose: @escaping () -> Void,
        onTogglePin: @escaping (String) -> Void
    ) {
        self.store = store
        self.activeProvider = activeProvider
        self.onApply = onApply
        self.onClose = onClose
        self.onTogglePin = onTogglePin
        reload()
    }

    /// Re-rank and re-flatten. Called on every query keystroke, on
    /// every pin/unpin, and once at construction.
    func reload() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sections = PromptRanker.defaultSections(
                store: store,
                operand: nil,
                activeProvider: activeProvider
            )
            searchRows = []
        } else {
            sections = []
            searchRows = PromptRanker.search(
                query: trimmed,
                store: store,
                operand: nil,
                activeProvider: activeProvider
            )
        }
        // Reset focus to the top whenever the list shape changes so
        // arrow nav doesn't dangle off the end of the previous list.
        focusedIndex = 0
    }

    /// Flat ordered list of rows visible in the picker — sections
    /// concatenated when no query, ranked list when querying. The view
    /// uses this for arrow-key navigation and `focusedIndex` lookup.
    var visibleRows: [PromptRanker.Row] {
        if !searchRows.isEmpty { return searchRows }
        return sections.flatMap { $0.rows }
    }

    /// Currently-highlighted prompt, or nil if the visible list is
    /// empty (no matches for the query).
    var focusedPrompt: Prompt? {
        let rows = visibleRows
        guard !rows.isEmpty else { return nil }
        let idx = max(0, min(rows.count - 1, focusedIndex))
        return rows[idx].prompt
    }

    func isPinned(_ promptID: String) -> Bool {
        store.isPinned(promptID)
    }

    // MARK: - Actions

    func moveFocus(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let next = focusedIndex + delta
        focusedIndex = max(0, min(rows.count - 1, next))
    }

    func setFocus(rowID: String) {
        let rows = visibleRows
        if let idx = rows.firstIndex(where: { $0.prompt.id == rowID }) {
            focusedIndex = idx
        }
    }

    func applyFocused() {
        guard let prompt = focusedPrompt else { return }
        onApply(prompt)
    }

    func close() {
        onClose()
    }

    func togglePinFocused() {
        guard let prompt = focusedPrompt else { return }
        onTogglePin(prompt.id)
    }

    func togglePreview() {
        isPreviewOpen.toggle()
    }
}
