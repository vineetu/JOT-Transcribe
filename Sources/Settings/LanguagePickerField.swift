import SwiftUI

/// A native-feeling, type-to-search single-select control for the transcription
/// language. The default SwiftUI `Picker` renders as a pop-up menu that becomes
/// an unscrollable wall at ~38 languages; this replaces it with a
/// pop-up-button-styled trigger that opens a `.popover` containing the app's
/// standard inline search field + a filtered list.
///
/// Pure SwiftUI, no AppKit bridging. It deliberately uses a manual search
/// `TextField` rather than `.searchable` — matching the inline-filter idiom
/// already established in Prompts / Shortcuts / Help (the team treats
/// `.searchable` as a window-level command, not a pane-scoped filter).
struct LanguagePickerField: View {
    @Binding var selection: LanguageChoice

    @State private var isOpen = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage(RecentLanguages.key) private var recentRaw = ""

    /// MRU languages pinned above the full list (only when not searching).
    private var recents: [LanguageChoice] {
        RecentLanguages.display(fromRaw: recentRaw, current: selection)
    }

    /// Token-substring match over both the English and native names, so typing
    /// "ger" finds "German — Deutsch" and typing "中" finds Mandarin. Mirrors the
    /// app's `ShortcutsSearchFilter` (whitespace-split, all-tokens-must-match).
    private var filtered: [LanguageChoice] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return LanguageChoice.presentationOrder }
        return LanguageChoice.presentationOrder.filter { lang in
            let haystack = "\(lang.englishName) \(lang.nativeName)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 6) {
                Text(selection.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            popoverBody
        }
    }

    private var popoverBody: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search languages", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { selectFirst() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            if filtered.isEmpty {
                Spacer(minLength: 0)
                Text("No languages match “\(query)”")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer(minLength: 0)
            } else if query.isEmpty && !recents.isEmpty {
                // Not searching: pin a "Recent" (MRU) section above the full
                // alphabetical list. The full list still contains every
                // language (recents are a shortcut, not a filter).
                List {
                    Section("Recent") {
                        ForEach(recents) { lang in
                            row(for: lang)
                                .contentShape(Rectangle())
                                .onTapGesture { choose(lang) }
                        }
                    }
                    Section("All Languages") {
                        ForEach(LanguageChoice.presentationOrder) { lang in
                            row(for: lang)
                                .contentShape(Rectangle())
                                .onTapGesture { choose(lang) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                List {
                    ForEach(filtered) { lang in
                        row(for: lang)
                            .contentShape(Rectangle())
                            .onTapGesture { choose(lang) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(12)
        .frame(width: 320, height: 380)
        .onAppear {
            // Focus the field once the popover has materialized.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func row(for lang: LanguageChoice) -> some View {
        HStack(spacing: 8) {
            Text(lang.displayName)
                .lineLimit(1)
            if lang.isExperimental {
                Text("Experimental")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if lang == selection {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    private func choose(_ lang: LanguageChoice) {
        selection = lang
        recentRaw = RecentLanguages.recordedRaw(fromRaw: recentRaw, picked: lang)
        isOpen = false
        query = ""
    }

    /// Return key in the search field selects the first match.
    private func selectFirst() {
        if let first = filtered.first { choose(first) }
    }
}
