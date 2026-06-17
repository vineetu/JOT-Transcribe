import SwiftUI

/// SwiftUI root for the Prompt Picker palette. Hosted in an
/// `NSHostingView` inside `PromptPickerPanel`. Renders:
///   - search field (auto-focused)
///   - operand context strip (Phase 1: a fixed "Refining your selected
///     text" hint — see `prompt-picker-ux.md` §10 for operand-resolution
///     scope cuts)
///   - sectioned list (Recent / Pinned / Essentials) when no query
///   - flat ranked list when query is non-empty
///   - footer keyboard hints
///   - optional preview drawer on the right (⌥⏎ to toggle)
struct PromptPickerView: View {
    @ObservedObject var model: PromptPickerViewModel
    @FocusState private var searchFocused: Bool

    private static let panelWidth: CGFloat = 620
    private static let panelHeight: CGFloat = 440
    private static let previewDrawerWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: 0) {
            mainColumn
                .frame(width: model.isPreviewOpen ? Self.panelWidth - Self.previewDrawerWidth : Self.panelWidth)
            if model.isPreviewOpen, let prompt = model.focusedPrompt {
                Divider()
                PromptPreviewDrawer(prompt: prompt)
                    .frame(width: Self.previewDrawerWidth)
            }
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, x: 0, y: -10)
        .task {
            // Defer focus assignment until after the panel finishes
            // becoming key. Without this delay, @FocusState fires while
            // the non-activating panel's first-responder chain is still
            // settling and the TextField never becomes editable — the
            // user sees the field but has to click it to start typing.
            // 60ms is empirically enough on macOS 14+; it's also small
            // enough that the user doesn't perceive it.
            try? await Task.sleep(nanoseconds: 60_000_000)
            searchFocused = true
        }
    }

    @ViewBuilder
    private var mainColumn: some View {
        VStack(spacing: 0) {
            searchHeader
            operandStrip
            Divider().padding(.vertical, 2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.searchRows.isEmpty {
                            sectionedBody
                        } else {
                            searchBody
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: model.focusedIndex) { _, _ in
                    if let prompt = model.focusedPrompt {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(prompt.id, anchor: .center)
                        }
                    }
                }
            }
            Divider()
            footer
        }
    }

    // MARK: - Header / strip

    @ViewBuilder
    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Navigation / apply / close / pin / preview are all handled
            // by the NSEvent monitor in PromptPickerController. SwiftUI's
            // `.onKeyPress` on a TextField doesn't see arrow keys
            // (they're consumed by the field's cursor handling), so we
            // route everything through the AppKit-level monitor. The
            // TextField still gets typing keys naturally — the monitor
            // returns those events unchanged.
            TextField("Search prompts…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .regular))
                .focused($searchFocused)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var operandStrip: some View {
        HStack {
            Text("Refining your selected text — pick a prompt to apply.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Body

    @ViewBuilder
    private var sectionedBody: some View {
        // Track running index across sections so each row's `isFocused`
        // can compare against `model.focusedIndex` without per-section
        // recomputation. SwiftUI's ForEach can't capture mutable index
        // cleanly, so we precompute the flat order.
        let flatOrder = model.sections.flatMap { $0.rows.map(\.prompt.id) }
        let focusedID: String? = {
            guard !flatOrder.isEmpty else { return nil }
            let idx = max(0, min(flatOrder.count - 1, model.focusedIndex))
            return flatOrder[idx]
        }()

        ForEach(model.sections) { section in
            sectionHeader(section.title)
            ForEach(section.rows) { row in
                rowView(row: row, isFocused: row.prompt.id == focusedID)
                    .id(row.prompt.id)
                    .onTapGesture { model.applyFocused() }
                    .onHover { hovering in
                        if hovering { model.setFocus(rowID: row.prompt.id) }
                    }
            }
        }
        if model.sections.isEmpty {
            Text("No prompts available. Check Resources/prompt-library.json.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(18)
        }
    }

    @ViewBuilder
    private var searchBody: some View {
        let focusedID: String? = {
            guard !model.searchRows.isEmpty else { return nil }
            let idx = max(0, min(model.searchRows.count - 1, model.focusedIndex))
            return model.searchRows[idx].prompt.id
        }()
        ForEach(model.searchRows) { row in
            rowView(row: row, isFocused: row.prompt.id == focusedID)
                .id(row.prompt.id)
                .onTapGesture { model.applyFocused() }
                .onHover { hovering in
                    if hovering { model.setFocus(rowID: row.prompt.id) }
                }
        }
        if model.searchRows.isEmpty {
            HStack {
                Text("No prompts match \u{201C}\(model.query)\u{201D}.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .default))
            .foregroundStyle(.tertiary)
            .tracking(1.5)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rowView(row: PromptRanker.Row, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isFocused ? "chevron.right" : "")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            highlightedTitle(row: row)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.isDefault(row.prompt.id) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .help("Default — fired by a tap on the Rewrite hotkey")
            }
            if model.isPinned(row.prompt.id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if isFocused {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(
            isFocused
                ? AnyView(Color.accentColor.opacity(0.18))
                : AnyView(Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Highlight the title characters returned by the fuzzy matcher.
    /// Non-matching characters dim to `.secondary`, matching characters
    /// stay `.primary`. When no query is active the whole title is
    /// `.primary`.
    @ViewBuilder
    private func highlightedTitle(row: PromptRanker.Row) -> some View {
        if row.titleHighlightIndexes.isEmpty {
            Text(row.prompt.title)
                .font(.system(size: 13))
        } else {
            let titleChars = Array(row.prompt.title)
            let matchSet = Set(row.titleHighlightIndexes)
            let attributed: AttributedString = {
                var out = AttributedString("")
                for (i, ch) in titleChars.enumerated() {
                    var run = AttributedString(String(ch))
                    if matchSet.contains(i) {
                        run.foregroundColor = .primary
                    } else {
                        run.foregroundColor = .secondary
                    }
                    out.append(run)
                }
                return out
            }()
            Text(attributed)
                .font(.system(size: 13))
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 14) {
            footerHint("⏎", "Apply")
            footerHint("⌘P", "Pin")
            footerHint("⌘D", "Default")
            footerHint("⌥⏎", "Preview")
            footerHint("⎋", "Close")
            Spacer(minLength: 0)
            if !model.searchRows.isEmpty {
                Text("\(model.searchRows.count) match\(model.searchRows.count == 1 ? "" : "es")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func footerHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Preview drawer

/// Right-side drawer showing sample input/output for the focused
/// prompt. Toggled via ⌥⏎. Phase 1 renders sample I/O only; future
/// versions may add provider compatibility / tag pills.
struct PromptPreviewDrawer: View {
    let prompt: Prompt

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.title)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.bottom, 2)

                if let input = prompt.sampleInput {
                    sampleBlock(label: "EXAMPLE INPUT", body: input, color: .secondary)
                }
                if let output = prompt.sampleOutput {
                    sampleBlock(label: "EXAMPLE OUTPUT", body: output, color: .accentColor)
                }
                if !prompt.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(prompt.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9, weight: .medium, design: .default))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                )
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sampleBlock(label: String, body: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .tracking(0.5)
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.leading, 4)
        }
    }
}

// MARK: - Vibrancy

/// Bridges `NSVisualEffectView` into SwiftUI so the picker palette can
/// pick up the system's vibrancy material (`.hudWindow`). Mirrors the
/// pattern used by the Setup Wizard's vibrancy strip.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
