import Combine
import Foundation
import SwiftData
import os.log

/// The single source of truth for prompts surfaced in the picker.
///
/// Responsibilities:
/// - Load the bundled `prompt-library.json` once at init.
/// - Merge user-authored `UserPrompt` rows from SwiftData into picker views.
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

    /// Bundled, read-only catalog decoded from `Resources/prompt-library.json`
    /// at init. Exposed so `PromptsSettingsContent` can render a "Built-in prompts"
    /// browse section alongside the editable user list.
    let bundledPrompts: [Prompt]
    var allPrompts: [Prompt] {
        bundledPrompts + userPrompts.map(Self.project)
    }
    @Published private(set) var userPrompts: [UserPrompt] = []
    /// Index of usage rows by prompt id. Reads come from this map so the
    /// UI can render without an additional SwiftData fetch per row.
    @Published private(set) var usage: [String: PromptUsage] = [:]

    private let log = Logger(subsystem: "com.jot.Jot", category: "PromptStore")
    private let modelContext: ModelContext?
    private let defaults: UserDefaults
    private static let userPromptProviderCompatibility = ["apple", "anthropic", "openai", "gemini", "ollama"]

    /// `@AppStorage`-equivalent key for the user-selected default Rewrite
    /// prompt. Holds a prompt id — a bundled JSON id (e.g. `"improve-writing"`)
    /// or a user prompt's UUID string. Empty / missing means "no default
    /// selected": the TAP path falls back to the bundled "Rewrite" prompt
    /// (`bundledRewritePromptID`) so the fixed `.rewrite` hotkey resolves a
    /// concrete, library-visible prompt rather than a string literal.
    static let defaultPromptIDKey = "jot.prompts.defaultPromptID"

    /// Bundled-library id of the read-only "Rewrite" prompt. Its body is
    /// the fixed-Rewrite system prompt (kept in sync with
    /// `RewritePrompt.default`). The fixed `.rewrite` hotkey resolves its
    /// instruction from this prompt when no user default is selected, so
    /// "Rewrite" shows up in the picker like any other bundled prompt and
    /// is the rewrite default.
    static let bundledRewritePromptID = "rewrite"

    /// The bundled "Rewrite" prompt, looked up by id. Used by the
    /// `RewriteController` default-resolver fallback so a TAP with no
    /// user-selected default still fires a concrete, library-visible
    /// prompt. Falls back to a synthesized `Prompt` (carrying
    /// `RewritePrompt.default`) on the off-chance the JSON entry is
    /// missing, so the fixed-rewrite path never dead-ends.
    func bundledRewritePrompt() -> Prompt {
        if let prompt = bundledPrompts.first(where: { $0.id == Self.bundledRewritePromptID }) {
            return prompt
        }
        return Prompt(
            id: Self.bundledRewritePromptID,
            title: "Rewrite",
            tier: .essentials,
            category: "Essentials",
            tags: ["rewrite"],
            body: RewritePrompt.default,
            sampleInput: nil,
            sampleOutput: nil,
            voiceAugmentHint: nil,
            providerCompatibility: Self.userPromptProviderCompatibility
        )
    }

    init(modelContext: ModelContext? = nil, bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
        self.bundledPrompts = Self.loadBundled(from: bundle, log: log)
        self.userPrompts = Self.loadUserPrompts(from: modelContext, log: log)
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

    private static func loadUserPrompts(from context: ModelContext?, log: Logger) -> [UserPrompt] {
        guard let context else { return [] }
        do {
            let descriptor = FetchDescriptor<UserPrompt>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            return try context.fetch(descriptor)
        } catch {
            log.error("UserPrompt fetch failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private static func project(_ userPrompt: UserPrompt) -> Prompt {
        Prompt(
            id: userPrompt.promptID,
            title: userPrompt.title,
            tier: .longTail,
            category: "My Prompts",
            tags: [],
            body: userPrompt.body,
            sampleInput: userPrompt.sampleInput,
            sampleOutput: userPrompt.sampleOutput,
            voiceAugmentHint: nil,
            providerCompatibility: userPromptProviderCompatibility
        )
    }

    func reloadUserPrompts() {
        userPrompts = Self.loadUserPrompts(from: modelContext, log: log)
    }

    // MARK: - Mutations

    func addUserPrompt(
        title: String,
        body: String,
        sampleInput: String? = nil,
        sampleOutput: String? = nil
    ) -> UserPrompt {
        let prompt = UserPrompt(
            title: title,
            body: body,
            sampleInput: sampleInput,
            sampleOutput: sampleOutput
        )
        guard let modelContext else {
            userPrompts.insert(prompt, at: 0)
            return prompt
        }
        modelContext.insert(prompt)
        do {
            try modelContext.save()
        } catch {
            log.error("UserPrompt insert failed: \(String(describing: error), privacy: .public)")
        }
        reloadUserPrompts()
        return prompt
    }

    func updateUserPrompt(
        _ prompt: UserPrompt,
        title: String,
        body: String,
        sampleInput: String? = nil,
        sampleOutput: String? = nil
    ) {
        prompt.title = title
        prompt.body = body
        prompt.sampleInput = sampleInput
        prompt.sampleOutput = sampleOutput
        prompt.updatedAt = .now
        do {
            try modelContext?.save()
        } catch {
            log.error("UserPrompt update failed: \(String(describing: error), privacy: .public)")
        }
        reloadUserPrompts()
    }

    func deleteUserPrompt(_ prompt: UserPrompt) {
        let promptID = prompt.promptID
        // Drop a dangling default pointer so the TAP path falls back to
        // the shared Rewrite prompt instead of silently resolving to nil
        // forever. `defaultPrompt()` already tolerates a stale id, but
        // clearing keeps the stored value honest.
        if isDefault(promptID) {
            clearDefault()
        }
        guard let modelContext else {
            userPrompts.removeAll { $0.id == prompt.id }
            usage[promptID] = nil
            return
        }
        do {
            let usageDescriptor = FetchDescriptor<PromptUsage>(
                predicate: #Predicate { $0.promptID == promptID }
            )
            for row in try modelContext.fetch(usageDescriptor) {
                modelContext.delete(row)
            }
            modelContext.delete(prompt)
            try modelContext.save()
            usage[promptID] = nil
        } catch {
            log.error("UserPrompt delete failed: \(String(describing: error), privacy: .public)")
        }
        reloadUserPrompts()
    }

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

    // MARK: - Default (tap) prompt

    /// The id of the user-selected default Rewrite prompt, or `nil` when
    /// none is set. Stored in `UserDefaults` so it survives relaunches and
    /// is readable from the rewrite-controller resolver without a SwiftData
    /// fetch. Returns `nil` for an empty stored string.
    var defaultPromptID: String? {
        let raw = defaults.string(forKey: Self.defaultPromptIDKey) ?? ""
        return raw.isEmpty ? nil : raw
    }

    /// True when `promptID` is the currently-selected default prompt.
    func isDefault(_ promptID: String) -> Bool {
        defaultPromptID == promptID
    }

    /// Promote `promptID` to the default Rewrite prompt fired by a TAP on
    /// the Rewrite hotkey. Persists to `UserDefaults`.
    func setDefault(_ promptID: String) {
        defaults.set(promptID, forKey: Self.defaultPromptIDKey)
        objectWillChange.send()
    }

    /// Clear the default selection — the TAP path reverts to the bundled
    /// "Rewrite" prompt (`bundledRewritePrompt()`, body == `RewritePrompt.default`).
    func clearDefault() {
        defaults.removeObject(forKey: Self.defaultPromptIDKey)
        objectWillChange.send()
    }

    /// Toggle `promptID` as the default: sets it when it isn't already the
    /// default, clears the selection when it is. Drives the "Set as default"
    /// affordances in the Prompts panel and picker.
    func toggleDefault(_ promptID: String) {
        if isDefault(promptID) {
            clearDefault()
        } else {
            setDefault(promptID)
        }
    }

    /// Resolve the selected default prompt to a concrete `Prompt`, or `nil`
    /// when unset OR the stored id no longer resolves (e.g. the user deleted
    /// the custom prompt that was the default). A `nil` return is the signal
    /// for callers to fall back to today's behavior.
    func defaultPrompt() -> Prompt? {
        guard let id = defaultPromptID else { return nil }
        return prompt(id: id)
    }

    func useCount(_ promptID: String) -> Int {
        usage[promptID]?.useCount ?? 0
    }

    func lastUsedAt(_ promptID: String) -> Date? {
        usage[promptID]?.lastUsedAt
    }
}
