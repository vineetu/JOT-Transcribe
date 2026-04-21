import SwiftUI

/// A single row in the Vocabulary pane. Collapsed: just the term, with a
/// quiet "N sounds-like" badge if the term has aliases. Expanded: the
/// term field remains editable and an aliases field appears below.
///
/// Tap toggles expansion. `↩` in the term field collapses the row.
/// Hover reveals a trailing `×` delete button. Matches the Things /
/// Linear idiom described in the research doc §7.
struct VocabRow: View {
    @Binding var term: VocabTerm
    let isExpanded: Bool
    var focused: FocusState<VocabTerm.ID?>.Binding
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var aliasesDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 0) {
            HStack(spacing: 8) {
                TextField("Term", text: $term.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .focused(focused, equals: term.id)
                    .onSubmit {
                        // Collapse on Return regardless of aliases — a
                        // keyboard-perfect "tab to aliases" flow would
                        // need a two-field focus state per row; Phase C
                        // polish. For now the user clicks into the
                        // aliases field when they want to edit it.
                        if isExpanded { onToggle() }
                    }

                if let warning = warningMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(warning)
                }

                Spacer(minLength: 4)

                if !term.aliases.isEmpty && !isExpanded {
                    Text("\(term.aliases.count) sounds-like")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
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

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Tap the row (outside the text field) to toggle; tapping
                // inside the text field keeps focus there per standard
                // SwiftUI hit-testing.
                onToggle()
            }

            if isExpanded {
                TextField(
                    "Sounds like… (comma separated)",
                    text: $aliasesDraft
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onAppear { aliasesDraft = term.aliases.joined(separator: ", ") }
                .onChange(of: aliasesDraft) { _, newValue in
                    term.aliases = newValue
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) { isHovered = hovering }
        }
    }

    /// Live inline warning for obvious footguns. Never blocks save —
    /// user is trusted. Two heuristics per research §7:
    ///   • Empty-ish terms (<=2 chars after trim) are too short for the
    ///     CTC rescorer's `minTermLength: 3` and will be silently dropped.
    ///   • Exact matches on very common English words cause false
    ///     replacements. We ship a small hardcoded watchlist rather than
    ///     pull in a 10k-word frequency file for MVP.
    private var warningMessage: String? {
        let t = term.text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t.count <= 2 {
            return "Too short — terms under 3 characters are skipped to avoid false replacements."
        }
        if Self.commonEnglishWatchlist.contains(t) {
            return "Common English word — may cause false replacements in transcripts that use the word normally."
        }
        return nil
    }

    /// Curated watchlist of common English words that are very likely
    /// to collide with ordinary speech. Deliberately small — a bigger
    /// list belongs in a bundled frequency file in a future phase.
    private static let commonEnglishWatchlist: Set<String> = [
        "the", "and", "for", "that", "with", "this", "from", "have",
        "they", "will", "one", "all", "would", "their", "what", "out",
        "about", "which", "when", "make", "like", "time", "just", "him",
        "know", "take", "into", "year", "your", "good", "some", "could",
        "them", "see", "other", "than", "then", "now", "look", "only",
        "come", "over", "think", "also", "back", "after", "use", "two",
        "how", "our", "work", "first", "well", "way", "even", "new",
        "want", "any", "give", "day", "most", "very", "find", "thing",
        "tell", "say", "get", "made", "part", "get", "yes", "yeah",
    ]
}
