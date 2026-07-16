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
    /// Searches the FULL entry set (including hardware-gated languages) so a user
    /// typing "Arabic" on an ineligible Mac gets the greyed row + explanation
    /// instead of an empty result.
    private var filtered: [LanguageChoice.MenuEntry] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return LanguageChoice.presentationEntries() }
        return LanguageChoice.presentationEntries().filter { entry in
            let lang = entry.language
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
                    // Recents are drawn from the SELECTABLE set only, so every
                    // row here is always tappable.
                    Section("Recent") {
                        ForEach(recents) { lang in
                            row(for: LanguageChoice.MenuEntry(language: lang, isHardwareGated: false))
                        }
                    }
                    Section("All Languages") {
                        ForEach(LanguageChoice.presentationEntries()) { entry in
                            row(for: entry)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                List {
                    ForEach(filtered) { entry in
                        row(for: entry)
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

    /// One picker row. Gated languages render greyed with an explanatory
    /// subtitle and are non-tappable (`.disabled`) — visible but impossible to
    /// select. The tap gesture is attached here so a gated row simply can't fire
    /// it; `choose` also guards defensively.
    private func row(for entry: LanguageChoice.MenuEntry) -> some View {
        let lang = entry.language
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lang.displayName)
                    .lineLimit(1)
                if entry.isHardwareGated {
                    Text(LanguageChoice.hardwareGateNote())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Gated rows already carry the memory note; the "Experimental" badge
            // would just be noise, so suppress it there.
            if lang.isExperimental && !entry.isHardwareGated {
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
        .contentShape(Rectangle())
        .onTapGesture { choose(entry) }
        .disabled(entry.isHardwareGated)
    }

    private func choose(_ entry: LanguageChoice.MenuEntry) {
        // A gated language must never reach the binding (and thus never reach
        // requestLanguageSwitch). Presentation-only surface; selection is a no-op.
        guard !entry.isHardwareGated else { return }
        selection = entry.language
        recentRaw = RecentLanguages.recordedRaw(fromRaw: recentRaw, picked: entry.language)
        isOpen = false
        query = ""
    }

    /// Return key in the search field selects the first SELECTABLE match, so
    /// pressing Return on a gated-only result set does nothing rather than
    /// picking an unusable language.
    private func selectFirst() {
        if let first = filtered.first(where: { !$0.isHardwareGated }) { choose(first) }
    }
}
