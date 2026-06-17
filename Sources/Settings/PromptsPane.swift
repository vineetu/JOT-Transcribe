import Foundation
import KeyboardShortcuts
import SwiftData
import SwiftUI

struct PromptsPane: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.helpNavigator) private var navigator
    @EnvironmentObject private var llmConfiguration: LLMConfiguration
    @EnvironmentObject private var promptStore: PromptStore
    @State private var editorDraft: PromptEditorDraft?
    @State private var pendingDelete: PromptDeletion?
    @State private var searchText = ""
    /// Expansion state for the relocated Cleanup prompt editor. Auto-opens
    /// when a Settings → AI popover deep-links to `cleanup-prompt`.
    @State private var cleanupPromptExpanded: Bool = false
    /// Drives the read-only inspection sheet for a tapped built-in prompt.
    @State private var inspectingBuiltIn: BuiltInPromptInspection?
    /// "How to use prompts" card collapsed state. Default open on a fresh
    /// install (first-visit users need the orientation), persists across
    /// launches once the user collapses it.
    @AppStorage("jot.promptsPane.howToCardCollapsed") private var howToCollapsed: Bool = false

    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting

    init(
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting
    ) {
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
    }

    var body: some View {
        Form {
            headerSection
            howToUseSection
            cleanupSection
            searchSection
            if !pinnedPromptsFiltered().isEmpty {
                pinnedSection
            }
            builtInSections
            myPromptsSection
            if !promptStore.userPrompts.isEmpty { statusFooter }
        }
        .formStyle(.grouped)
        .onAppear {
            _ = modelContext
            promptStore.reloadUserPrompts()
            consumePendingCleanupAnchor()
        }
        .onChange(of: navigator.pendingSettingsFieldAnchor) { _, _ in
            consumePendingCleanupAnchor()
        }
        .sheet(item: $editorDraft) { draft in
            PromptEditorSheet(
                draft: draft,
                llmClient: LLMClient(
                    session: urlSession,
                    appleClient: appleIntelligence,
                    llmConfiguration: llmConfiguration
                ),
                onCancel: { editorDraft = nil },
                onSave: { values in
                    save(values, for: draft)
                    editorDraft = nil
                }
            )
        }
        .sheet(item: $inspectingBuiltIn) { inspection in
            BuiltInPromptDetailSheet(
                prompt: inspection.prompt,
                onDismiss: { inspectingBuiltIn = nil }
            )
        }
        .alert(
            "Delete prompt?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { deletion in
            Button("Delete", role: .destructive) {
                promptStore.deleteUserPrompt(deletion.prompt)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { deletion in
            Text("This removes \"\(deletion.title)\" from your prompt library.")
        }
    }

    /// Live readout of the user's current Rewrite hotkey, used by the
    /// "How to use" card. Returns a tuple of (verb, hotkey-or-status) so
    /// the card can render "Press and **hold** **⌥/**" for chords,
    /// "Press your **Caps Lock**" for single-key, or "Set a Rewrite
    /// hotkey first" for the not-configured case.
    private struct RewriteHotkeyReadout {
        let verb: String       // "Press and hold" / "Press"
        let glyph: String?     // "⌥/" / "Caps Lock" — nil when unset
        let isUnset: Bool
    }

    private var rewriteHotkey: RewriteHotkeyReadout {
        let binding = SingleKeyMigration.effectiveBinding(for: .rewrite)
        switch binding.triggerType {
        case .chord:
            if let desc = binding.chordDescription, !desc.isEmpty {
                return RewriteHotkeyReadout(verb: "Press and hold", glyph: desc, isUnset: false)
            } else {
                return RewriteHotkeyReadout(verb: "Press and hold", glyph: nil, isUnset: true)
            }
        case .singleKey:
            if binding.singleKey == .none {
                return RewriteHotkeyReadout(verb: "Press", glyph: nil, isUnset: true)
            } else {
                return RewriteHotkeyReadout(verb: "Press", glyph: binding.singleKey.displayName, isUnset: false)
            }
        }
    }

    @ViewBuilder
    private var howToUseSection: some View {
        Section {
            VStack(alignment: .leading, spacing: howToCollapsed ? 0 : 10) {
                // Header — fully clickable row that toggles collapse.
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        howToCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 13))
                            .foregroundStyle(.tint)
                        Text("How to use prompts")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: howToCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !howToCollapsed {
                    howToBody
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var howToBody: some View {
        let hotkey = rewriteHotkey
        VStack(alignment: .leading, spacing: 8) {
            howToStep(number: "1", text: "Select the text you want to rewrite in any app.")
            howToStep(
                number: "2",
                text: nil,
                richContent: {
                    HStack(spacing: 6) {
                        Text(hotkey.verb)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if let glyph = hotkey.glyph {
                            Text(glyph)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.15))
                                )
                            Text("to open the prompt picker.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("your Rewrite hotkey — ")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text("set one in Settings → Shortcuts")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.tint)
                            Text("to open the prompt picker.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            )
            howToStep(number: "3", text: "Pick a prompt — Jot replaces the selection with the rewritten text.")

            Text("Tip: pin frequently-used prompts so they appear at the top of the picker.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func howToStep<Content: View>(
        number: String,
        text: String?,
        @ViewBuilder richContent: () -> Content = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(Color.secondary.opacity(0.12))
                )
            if let text {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                richContent()
            }
            Spacer(minLength: 0)
        }
    }

    /// Relocated home for the editable Cleanup (Transform) prompt. The
    /// automatic post-dictation cleanup itself stays wired in Settings → AI
    /// (the `transformEnabled` toggle + the `transform()` pipeline, which
    /// still reads `LLMConfiguration.transformPrompt`). Only the prompt-text
    /// editing moved here so all prompt management lives in one panel. The
    /// binding is the same `@AppStorage "jot.llm.transformPrompt"` key, so a
    /// user's previously-customized cleanup text is read here unchanged — no
    /// migration required.
    private var cleanupSection: some View {
        Section("Cleanup") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cleanup prompt")
                        .font(.system(size: 13, weight: .medium))
                    Text("Built-in prompt that runs automatically on every dictation when Auto-correct is on (toggle in Settings → AI). Edits here apply to that cleanup pass.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, 2)

            CustomizePromptDisclosure(
                label: "Customize prompt",
                text: $llmConfiguration.transformPrompt,
                defaultValue: TransformPrompt.default,
                info: .init(
                    title: "Cleanup prompt",
                    body: "System prompt for Clean up transcript with AI. Tells the LLM how to polish the raw transcript — filler removal, grammar, list detection — while preserving your voice. The cleanup pass itself is toggled in Settings → AI.",
                    helpAnchor: "cleanup-prompt"
                ),
                isExpanded: $cleanupPromptExpanded
            )
            .id("cleanup-prompt")
        }
    }

    private func consumePendingCleanupAnchor() {
        guard navigator.pendingSettingsFieldAnchor == "cleanup-prompt" else { return }
        withAnimation {
            cleanupPromptExpanded = true
        }
        navigator.clearPendingSettingsFieldAnchor()
    }

    private var searchSection: some View {
        Section {
            // Why default style (not `.plain`) + `roundedBorder` ground:
            // a `.plain` TextField inside a Form Section row reads as
            // static label text — users tap and nothing visibly happens.
            // The default rounded-border style gives the field an obvious
            // hit area and matches every other macOS Settings search box.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Search prompts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
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
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var pinnedSection: some View {
        Section("Pinned") {
            ForEach(pinnedPromptsFiltered()) { prompt in
                BrowserRow(prompt: prompt) {
                    open(prompt)
                }
            }
        }
    }

    private var myPromptsSection: some View {
        Section("My prompts") {
            if promptStore.userPrompts.isEmpty {
                emptyStateView
            } else {
                ForEach(userPromptsFiltered(), id: \.id) { prompt in
                    UserPromptRow(
                        prompt: prompt,
                        isPinned: promptStore.isPinned(prompt.promptID),
                        isDefault: promptStore.isDefault(prompt.promptID),
                        onTogglePin: { promptStore.togglePin(prompt.promptID) },
                        onToggleDefault: { promptStore.toggleDefault(prompt.promptID) },
                        onEdit: { editorDraft = PromptEditorDraft(prompt: prompt) },
                        onDelete: { pendingDelete = PromptDeletion(prompt: prompt) }
                    )
                }
            }
            addPromptButton
        }
    }

    @ViewBuilder
    private var builtInSections: some View {
        ForEach(bundledCategoriesInOrder, id: \.self) { category in
            let prompts = bundledPromptsFiltered(in: category)
            if !prompts.isEmpty {
                Section(category) {
                    ForEach(prompts) { prompt in
                        BrowserRow(prompt: prompt) {
                            inspectingBuiltIn = BuiltInPromptInspection(prompt: prompt)
                        }
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom prompts")
                        .font(.system(size: 13, weight: .medium))
                    Text("Add reusable prompts for rewrite workflows. Bundled prompts stay read-only and continue to appear in the prompt picker.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                InfoPopoverButton(
                    title: "Custom prompts",
                    body: "Custom prompts are saved locally on this Mac and appear in the prompt picker when you search. Use them for repeat rewrite instructions, formatting rules, or domain-specific transformations."
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
            Text("No custom prompts yet.")
                .font(.system(size: 14, weight: .medium))
            Text("Add prompts you want to reuse from the picker.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var addPromptButton: some View {
        Button {
            editorDraft = PromptEditorDraft()
        } label: {
            Label("Add Prompt", systemImage: "plus")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var statusFooter: some View {
        Section {
            HStack {
                Text("\(promptStore.userPrompts.count) prompt\(promptStore.userPrompts.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private func save(_ values: PromptFormValues, for draft: PromptEditorDraft) {
        if let prompt = draft.prompt {
            promptStore.updateUserPrompt(
                prompt,
                title: values.title,
                body: values.body,
                sampleInput: values.sampleInput,
                sampleOutput: values.sampleOutput
            )
        } else {
            _ = promptStore.addUserPrompt(
                title: values.title,
                body: values.body,
                sampleInput: values.sampleInput,
                sampleOutput: values.sampleOutput
            )
        }
    }

    private var bundledCategoriesInOrder: [String] {
        var seen = Set<String>()
        var categories: [String] = []
        for category in promptStore.bundledPrompts.map(\.category) where seen.insert(category).inserted {
            categories.append(category)
        }
        return categories
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func pinnedPromptsFiltered() -> [Prompt] {
        promptStore.pinnedPrompts().filter { matchesSearch($0, includeCategory: true) }
    }

    private func userPromptsFiltered() -> [UserPrompt] {
        promptStore.userPrompts.filter(matchesSearch(_:))
    }

    private func bundledPromptsFiltered(in category: String) -> [Prompt] {
        promptStore.bundledPrompts.filter { prompt in
            prompt.category == category && matchesSearch(prompt, includeCategory: true)
        }
    }

    private func matchesSearch(_ prompt: UserPrompt) -> Bool {
        let query = normalizedSearchText
        guard !query.isEmpty else { return true }
        return [prompt.title, prompt.body].contains { $0.lowercased().contains(query) }
    }

    private func matchesSearch(_ prompt: Prompt, includeCategory: Bool) -> Bool {
        let query = normalizedSearchText
        guard !query.isEmpty else { return true }
        let fields = includeCategory
            ? [prompt.title, prompt.body, prompt.category]
            : [prompt.title, prompt.body]
        return fields.contains { $0.lowercased().contains(query) }
    }

    private func open(_ prompt: Prompt) {
        if let userPrompt = userPrompt(for: prompt.id) {
            editorDraft = PromptEditorDraft(prompt: userPrompt)
        } else {
            inspectingBuiltIn = BuiltInPromptInspection(prompt: prompt)
        }
    }

    private func userPrompt(for promptID: String) -> UserPrompt? {
        promptStore.userPrompts.first { $0.promptID == promptID }
    }
}

private struct BuiltInPromptInspection: Identifiable {
    let prompt: Prompt
    var id: String { prompt.id }
}

/// Small accent pill marking the prompt fired by a TAP on the Rewrite
/// hotkey. Mirrors the system "badge" look used elsewhere in Settings.
private struct DefaultPromptBadge: View {
    var body: some View {
        Text("Default")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.15))
            )
    }
}

private struct UserPromptRow: View {
    let prompt: UserPrompt
    let isPinned: Bool
    let isDefault: Bool
    let onTogglePin: () -> Void
    let onToggleDefault: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if isDefault {
                        DefaultPromptBadge()
                    }
                }
                Text(previewText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button {
                    onToggleDefault()
                } label: {
                    Image(systemName: isDefault ? "bolt.fill" : "bolt")
                        .font(.system(size: 12))
                        .foregroundStyle(isDefault ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isDefault ? "Clear default (tap reverts to the shared prompt)" : "Set as default — tap the Rewrite hotkey to fire this prompt")

                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin prompt" : "Pin prompt")

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit prompt")

                if isHovered {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete prompt")
                    .transition(.opacity)
                }
            }
        }
        .padding(.vertical, 3)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }

    private var previewText: String {
        let trimmed = prompt.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No prompt body." : trimmed
    }
}

private struct BrowserRow: View {
    @EnvironmentObject private var promptStore: PromptStore
    let prompt: Prompt
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(prompt.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if promptStore.isDefault(prompt.id) {
                                DefaultPromptBadge()
                            }
                        }
                        Text(previewText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                promptStore.toggleDefault(prompt.id)
            } label: {
                Image(systemName: promptStore.isDefault(prompt.id) ? "bolt.fill" : "bolt")
                    .font(.system(size: 12))
                    .foregroundStyle(promptStore.isDefault(prompt.id) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(promptStore.isDefault(prompt.id) ? "Clear default (tap reverts to the shared prompt)" : "Set as default — tap the Rewrite hotkey to fire this prompt")

            Button {
                promptStore.togglePin(prompt.id)
            } label: {
                Image(systemName: promptStore.isPinned(prompt.id) ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(promptStore.isPinned(prompt.id) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(promptStore.isPinned(prompt.id) ? "Unpin prompt" : "Pin prompt")
        }
        .padding(.vertical, 3)
    }

    private var previewText: String {
        let trimmed = prompt.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No prompt body." : trimmed
    }
}

private struct BuiltInPromptDetailSheet: View {
    @EnvironmentObject private var promptStore: PromptStore
    let prompt: Prompt
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(prompt.title)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tierBadge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section("Body") {
                    Text(prompt.body)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }

                if let sampleInput = nonEmpty(prompt.sampleInput) {
                    Section("Sample input") {
                        Text(sampleInput)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if let sampleOutput = nonEmpty(prompt.sampleOutput) {
                    Section("Sample output") {
                        Text(sampleOutput)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                    }
                }

                if let hint = nonEmpty(prompt.voiceAugmentHint) {
                    Section {
                        Text("💡 Voice hint: \(hint)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem {
                    Button {
                        promptStore.toggleDefault(prompt.id)
                    } label: {
                        Label(defaultTitle, systemImage: promptStore.isDefault(prompt.id) ? "bolt.fill" : "bolt")
                    }
                    .help(promptStore.isDefault(prompt.id) ? "Clear default" : "Set as the prompt fired by a tap on the Rewrite hotkey")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        promptStore.togglePin(prompt.id)
                    } label: {
                        Label(pinTitle, systemImage: promptStore.isPinned(prompt.id) ? "star.fill" : "star")
                    }
                }
            }
        }
        .frame(width: 520, height: 580)
    }

    private var tierBadge: String {
        "Tier \(prompt.tier.rawValue) · \(prompt.category)"
    }

    private var pinTitle: String {
        promptStore.isPinned(prompt.id) ? "Unpin" : "Pin"
    }

    private var defaultTitle: String {
        promptStore.isDefault(prompt.id) ? "Clear default" : "Set as default"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct PromptEditorSheet: View {
    let draft: PromptEditorDraft
    let llmClient: LLMClient
    let onCancel: () -> Void
    let onSave: (PromptFormValues) -> Void

    @State private var title: String
    @State private var promptBody: String
    @State private var sampleInput: String
    @State private var sampleOutput: String
    @State private var generationPhase: GenerationPhase = .idle

    private enum GenerationPhase: Equatable {
        case idle
        case generatingInput
        case generatingOutput
        case failed(String)
    }

    init(
        draft: PromptEditorDraft,
        llmClient: LLMClient,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PromptFormValues) -> Void
    ) {
        self.draft = draft
        self.llmClient = llmClient
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: draft.title)
        _promptBody = State(initialValue: draft.body)
        _sampleInput = State(initialValue: draft.sampleInput)
        _sampleOutput = State(initialValue: draft.sampleOutput)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Body")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $promptBody)
                            .font(.system(size: 13))
                            .frame(minHeight: 132)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .padding(.vertical, 2)
                }
                Section("Samples") {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            Task { @MainActor in
                                await generateSample()
                            }
                        } label: {
                            generationButtonLabel
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Generate sample input + output using your configured AI provider.")
                        .disabled(isGenerateSampleDisabled)

                        if case .failed(let message) = generationPhase {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sample input")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $sampleInput)
                            .font(.system(size: 13))
                            .frame(minHeight: 70)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sample output")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $sampleOutput)
                            .font(.system(size: 13))
                            .frame(minHeight: 70)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                            )
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isEditing ? "Edit Prompt" : "Add Prompt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(formValues) }
                        .disabled(!canSave)
                }
            }
        }
        .frame(width: 520, height: 560)
    }

    private var canSave: Bool {
        !trimmed(title).isEmpty && !trimmed(promptBody).isEmpty
    }

    private var isGenerateSampleDisabled: Bool {
        trimmed(promptBody).isEmpty || isGeneratingSample
    }

    private var isGeneratingSample: Bool {
        switch generationPhase {
        case .generatingInput, .generatingOutput:
            return true
        case .idle, .failed:
            return false
        }
    }

    @ViewBuilder
    private var generationButtonLabel: some View {
        switch generationPhase {
        case .idle:
            Text("✨ Generate sample")
        case .generatingInput:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating input…")
            }
        case .generatingOutput:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating output…")
            }
        case .failed:
            Text("Try again")
        }
    }

    private var formValues: PromptFormValues {
        PromptFormValues(
            title: trimmed(title),
            body: trimmed(promptBody),
            sampleInput: optionalTrimmed(sampleInput),
            sampleOutput: optionalTrimmed(sampleOutput)
        )
    }

    @MainActor
    private func generateSample() async {
        let body = trimmed(promptBody)
        guard !body.isEmpty, !isGeneratingSample else { return }

        generationPhase = .generatingInput
        sampleInput = ""
        sampleOutput = ""

        do {
            let generatedInput = trimmed(try await llmClient.complete(
                systemPrompt: sampleInputSystemPrompt,
                userPrompt: body
            ))
            guard !generatedInput.isEmpty else { throw LLMError.emptyResponse }
            sampleInput = generatedInput

            generationPhase = .generatingOutput

            let generatedOutput = trimmed(try await llmClient.complete(
                systemPrompt: body,
                userPrompt: generatedInput
            ))
            guard !generatedOutput.isEmpty else { throw LLMError.emptyResponse }
            sampleOutput = generatedOutput

            generationPhase = .idle
        } catch {
            generationPhase = .failed(error.localizedDescription)
        }
    }

    private var sampleInputSystemPrompt: String {
        "You will be shown a system prompt that operates on user text. Write ONE plausible, realistic user input that this system prompt is designed to handle. Keep it 1-2 sentences, specific and natural. Return ONLY the user input — no preamble, no quotes, no explanation."
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalTrimmed(_ value: String) -> String? {
        let cleaned = trimmed(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private struct PromptEditorDraft: Identifiable {
    let id: UUID
    let prompt: UserPrompt?
    let title: String
    let body: String
    let sampleInput: String
    let sampleOutput: String

    init(prompt: UserPrompt? = nil) {
        self.id = prompt?.id ?? UUID()
        self.prompt = prompt
        self.title = prompt?.title ?? ""
        self.body = prompt?.body ?? ""
        self.sampleInput = prompt?.sampleInput ?? ""
        self.sampleOutput = prompt?.sampleOutput ?? ""
    }

    var isEditing: Bool { prompt != nil }
}

private struct PromptFormValues {
    let title: String
    let body: String
    let sampleInput: String?
    let sampleOutput: String?
}

private struct PromptDeletion {
    let prompt: UserPrompt
    let title: String

    init(prompt: UserPrompt) {
        self.prompt = prompt
        self.title = prompt.title
    }
}
