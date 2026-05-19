import Combine
import Foundation
import SwiftData
import os.log

/// The single source of truth for prompts surfaced in the picker.
///
/// Responsibilities:
/// - Load the bundled `prompt-library.json` once at init.
/// - Read/write per-prompt `PromptUsage` rows (last-used, count, pinned)
///   from SwiftData. ModelContext is optional — when `nil` (test seam),
///   usage tracking is silently skipped and the picker still works
///   against the bundled list.
/// - Expose ranked sections (Recent / Pinned / Essentials / All) for the
///   picker's default view, and a flat list for search.
///
/// This store deliberately doesn't own search ranking — that lives in
/// `PromptRanker` so the picker can re-rank on every keystroke without
/// touching SwiftData.
@MainActor
final class PromptStore: ObservableObject {
    /// Window for the "Recent" section in the default picker view.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60
    /// Maximum rows shown in the Recent section before falling back to search.
    static let maxRecent = 3

    @Published private(set) var allPrompts: [Prompt] = []
    /// Index of usage rows by prompt id. Reads come from this map so the
    /// UI can render without an additional SwiftData fetch per row.
    @Published private(set) var usage: [String: PromptUsage] = [:]

    private let log = Logger(subsystem: "com.jot.Jot", category: "PromptStore")
    private let modelContext: ModelContext?

    init(modelContext: ModelContext? = nil, bundle: Bundle = .main) {
        self.modelContext = modelContext
        self.allPrompts = Self.loadBundled(from: bundle, log: log)
        self.usage = Self.loadUsage(from: modelContext, log: log)
    }

    // MARK: - Loading

    private static func loadBundled(from bundle: Bundle, log: Logger) -> [Prompt] {
        guard let url = bundle.url(forResource: "prompt-library", withExtension: "json") else {
            log.error("prompt-library.json not found in bundle — picker will be empty")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PromptLibraryFile.self, from: data)
            log.info("Loaded \(decoded.prompts.count, privacy: .public) bundled prompts (file version \(decoded.version))")
            return decoded.prompts
        } catch {
            log.error("Failed to decode prompt-library.json: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func loadUsage(from context: ModelContext?, log: Logger) -> [String: PromptUsage] {
        guard let context else { return [:] }
        do {
            let rows = try context.fetch(FetchDescriptor<PromptUsage>())
            var map: [String: PromptUsage] = [:]
            for row in rows { map[row.promptID] = row }
            return map
        } catch {
            log.error("PromptUsage fetch failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    // MARK: - Mutations

    /// Record that `promptID` was applied. Increments `useCount`, sets
    /// `lastUsedAt = .now`. Creates the row if none exists. Silently
    /// no-ops when no ModelContext is wired (test seam).
    func recordUse(of promptID: String) {
        guard let modelContext else { return }
        let row = usage[promptID] ?? PromptUsage(promptID: promptID)
        row.lastUsedAt = .now
        row.useCount += 1
        if usage[promptID] == nil {
            modelContext.insert(row)
        }
        usage[promptID] = row
        try? modelContext.save()
    }

    /// Toggle the pinned flag for `promptID`. Persists to SwiftData
    /// when the context is wired; in-memory only otherwise.
    func togglePin(_ promptID: String) {
        guard let modelContext else {
            // Test-seam fast path: mutate the in-memory map only.
            let existing = usage[promptID] ?? PromptUsage(promptID: promptID)
            existing.pinned.toggle()
            usage[promptID] = existing
            return
        }
        let row = usage[promptID] ?? PromptUsage(promptID: promptID)
        row.pinned.toggle()
        if usage[promptID] == nil {
            modelContext.insert(row)
        }
        usage[promptID] = row
        try? modelContext.save()
    }

    // MARK: - Lookups

    func prompt(id: String) -> Prompt? {
        allPrompts.first { $0.id == id }
    }

    /// Up to `maxRecent` prompts used within `recentWindow`, most recent first.
    func recentPrompts() -> [Prompt] {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        let recentIDs = usage.values
            .filter { ($0.lastUsedAt ?? .distantPast) >= cutoff }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(Self.maxRecent)
            .map(\.promptID)
        return recentIDs.compactMap { id in allPrompts.first { $0.id == id } }
    }

    /// All currently-pinned prompts, in the order they were pinned (most
    /// recently pinned last). Sort is stable on `lastUsedAt` as a
    /// proxy — pin events bump `lastUsedAt` to `now`.
    func pinnedPrompts() -> [Prompt] {
        let pinnedIDs = usage.values
            .filter { $0.pinned }
            .sorted { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }
            .map(\.promptID)
        return pinnedIDs.compactMap { id in allPrompts.first { $0.id == id } }
    }

    /// The Tier 1 (Essentials) set, in the JSON's declared order.
    func essentialPrompts() -> [Prompt] {
        allPrompts.filter { $0.tier == .essentials }
    }

    func isPinned(_ promptID: String) -> Bool {
        usage[promptID]?.pinned ?? false
    }

    func useCount(_ promptID: String) -> Int {
        usage[promptID]?.useCount ?? 0
    }

    func lastUsedAt(_ promptID: String) -> Date? {
        usage[promptID]?.lastUsedAt
    }
}
