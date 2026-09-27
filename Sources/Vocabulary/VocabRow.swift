import JotVocabCore
import SwiftUI

/// A single row in the Vocabulary pane: one visible, tappable text field
/// for the term, with a hover-to-reveal delete button.
///
/// The v1.5 "sounds-like" alias field was removed because the plain-text
/// term field was visually indistinguishable from a static label — users
/// clicked "Add Term" and couldn't tell where to type. The `VocabTerm`
/// model still carries an `aliases` array so the file format is stable.
///
/// v1.16: the alias editor returns, but only when the global **Advanced**
/// flag is on. Baseline (Advanced off) renders exactly the original single
/// term field. Advanced on adds an inline, compact "sounds-like" editor —
/// the same "When Jot hears … → spell it as <term>" framing as the
/// right-click `VocabMappingEditor` — so users can view/add/remove the
/// ways Jot mis-hears a word. All writes flow through the `term` binding,
/// which the pane wires to `VocabularyStore.update(id:text:aliases:)`.
struct VocabRow: View {
    @Binding var term: VocabTerm
    var focused: FocusState<VocabTerm.ID?>.Binding
    let onDelete: () -> Void

    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false
    /// The active transcription language — picks the everyday-word list the
    /// hygiene warning checks against.
    @AppStorage(TranscriberHolder.languageKey) private var languageRaw: String = ""

    @State private var isHovered = false
    @State private var newAlias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Term", text: $term.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                    .focused(focused, equals: term.id)

                if let warning = warningMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(warning)
                }

                if isHovered {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete term")
                    .transition(.opacity)
                }
            }

            if let hygiene = hygieneWarning {
                Text(hygiene)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if advancedEnabled {
                aliasEditor
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }

    // MARK: - Advanced "sounds-like" alias editor

    /// Compact alias surface shown only when Advanced is on. Lists the
    /// term's existing aliases as removable chips, plus a small field to
    /// add a new one. Mirrors the `VocabMappingEditor` "When Jot hears…"
    /// language so the two entry points read consistently.
    @ViewBuilder
    private var aliasEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("When Jot hears (sounds-like)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if !term.aliases.isEmpty {
                AliasFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(term.aliases.enumerated()), id: \.offset) { index, alias in
                        aliasChip(alias, at: index)
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add a sounds-like spelling", text: $newAlias)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { commitNewAlias() }
                Button {
                    commitNewAlias()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(canAddAlias ? JotTheme.current.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canAddAlias)
                .help("Add sounds-like spelling")
            }
        }
        .padding(.leading, 2)
    }

    private func aliasChip(_ alias: String, at index: Int) -> some View {
        HStack(spacing: 4) {
            Text(alias)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            Button {
                removeAlias(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove “\(alias)”")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.secondary.opacity(0.12))
        )
    }

    /// Sanitized candidate from the add field — same simple-format scrub
    /// (strips `:`/`,`/`#`, collapses whitespace) the store uses for terms,
    /// so an alias can't break the on-disk `Term: a, b` format.
    private var cleanedNewAlias: String {
        VocabularyStore.sanitizeTerm(newAlias)
    }

    /// Allow the add when the cleaned alias is non-empty and not already
    /// present (case-insensitive) on this term.
    private var canAddAlias: Bool {
        let candidate = cleanedNewAlias
        guard VocabularyStore.isAcceptableAlias(candidate) else { return false }
        return !term.aliases.contains { $0.lowercased() == candidate.lowercased() }
    }

    private func commitNewAlias() {
        guard canAddAlias else { return }
        term.aliases.append(cleanedNewAlias)
        newAlias = ""
    }

    private func removeAlias(at index: Int) {
        guard term.aliases.indices.contains(index) else { return }
        term.aliases.remove(at: index)
    }

    /// Live inline warning for obvious footguns. Never blocks save —
    /// user is trusted. Terms of 2 characters or fewer are too short for the
    /// CTC rescorer's `minTermLength: 3` and are silently dropped.
    private var warningMessage: String? {
        let t = term.text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t.count <= 2 {
            return "Too short — terms under 3 characters are skipped to avoid false replacements."
        }
        return nil
    }

    /// Vocabulary hygiene (shared `VocabularyHygiene`, design A4): the term's
    /// first word is an everyday word, or it opens with an everyday function
    /// word ("And…" in "Andalamma"). Checked against the active language's
    /// list (English when none is stored). Shown inline under the field.
    private var hygieneWarning: String? {
        let language = LanguageChoice(rawValue: languageRaw) ?? .english
        let resource = language.commonWordsResource
        return VocabularyHygiene.warning(
            for: term.text,
            commonWords: MacCommonWordsProvider.shared.words(forResource: resource),
            language: language.correctorLanguage
        )?.message
    }
}

/// Minimal wrapping flow layout for the alias chips so several short
/// aliases pack onto a line and wrap when they run out of width. Kept
/// local to this file — it's only used here and is simpler than pulling
/// in a general-purpose layout dependency.
private struct AliasFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.yOffset + $0.height } ?? 0
        let width = rows.map { $0.width }.max() ?? 0
        rows.removeAll()
        return CGSize(
            width: proposal.width ?? width,
            height: height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.xOffset, y: bounds.minY + row.yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
            }
        }
    }

    private struct RowItem {
        let index: Int
        let xOffset: CGFloat
    }

    private struct Row {
        var items: [RowItem] = []
        var yOffset: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                current.yOffset = y
                current.width = x - spacing
                rows.append(current)
                y += current.height + lineSpacing
                current = Row()
                x = 0
            }
            current.items.append(RowItem(index: index, xOffset: x))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }

        if !current.items.isEmpty {
            current.yOffset = y
            current.width = max(0, x - spacing)
            rows.append(current)
        }
        return rows
    }
}
