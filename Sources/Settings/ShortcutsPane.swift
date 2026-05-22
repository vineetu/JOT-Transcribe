import KeyboardShortcuts
import SwiftUI

/// Settings → Shortcuts pane (Option A · Raycast-inspired).
///
/// This is a thin coordinator over the row / chip / section / search
/// pieces under `Sources/Settings/Shortcuts/`. Storage shape is unchanged
/// from the legacy pane — same `@AppStorage` single-key keys, same
/// `KeyboardShortcuts.Name` chord storage, same `SingleKeyMigration` for
/// trigger-type tracking. The redesign is pure presentation.
///
/// What's new versus the v1.11 pane:
///   • One row per action (was three: trigger-type picker + recorder +
///     subtitle).
///   • Sectioned grouping (Recording / Rewrite / Capture & Cancel).
///   • "When this fires" badges next to each subtitle.
///   • Hover-revealed Reset on each row (replaces the global Reset button).
///   • Search field at the top — filters by title, subtitle, keywords.
///   • Mode switch (single-key vs chord) collapsed into a small per-row
///     menu so the 95% case (chord) doesn't show a picker chip.
///   • Cancel row stays read-only but joins the same list so its badge
///     ("During recording") sets expectations.
struct ShortcutsPane: View {
    @Environment(\.helpNavigator) private var navigator
    /// Bumped on every chord-recorder change so cached
    /// `KeyboardShortcuts.getShortcut(...)` reads (used by the conflict
    /// banner + the chord chip's NSView) refresh on the same tick.
    @State private var refreshToken: Int = 0
    @State private var searchText: String = ""

    // One @AppStorage per `SingleKey.Action` — SwiftUI needs literal
    // compile-time keys, so we can't drive these off the enum directly.
    // Values match `SingleKey.Action.<case>.storageKey`.
    @AppStorage("jot.hotkey.toggleRecording.singleKey") private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.pushToTalk.singleKey") private var pushToTalkSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.pasteLastTranscription.singleKey") private var pasteLastSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.rewriteWithVoice.singleKey") private var rewriteWithVoiceSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.rewrite.singleKey") private var rewriteSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""
    @AppStorage("jot.hotkey.pushToTalk.triggerType") private var pushToTalkTriggerTypeRaw: String = ""
    @AppStorage("jot.hotkey.pasteLastTranscription.triggerType") private var pasteLastTriggerTypeRaw: String = ""
    @AppStorage("jot.hotkey.rewriteWithVoice.triggerType") private var rewriteWithVoiceTriggerTypeRaw: String = ""
    @AppStorage("jot.hotkey.rewrite.triggerType") private var rewriteTriggerTypeRaw: String = ""

    // MARK: - Body

    var body: some View {
        let _ = refreshToken
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    searchField

                    if let conflict = conflictMessage() {
                        conflictBanner(text: conflict)
                    }

                    let visibleRows = ShortcutsSearchFilter.filter(ShortcutsRow.all, query: searchText)
                    let isSearchActive = !ShortcutsSearchFilter.tokenize(searchText).isEmpty

                    if visibleRows.isEmpty {
                        emptyState
                    } else if isSearchActive {
                        searchResults(rows: visibleRows)
                    } else {
                        groupedRows(rows: visibleRows)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { consumePendingSettingsFieldAnchor(with: proxy) }
            .onChange(of: navigator.pendingSettingsFieldAnchor) { _, _ in
                consumePendingSettingsFieldAnchor(with: proxy)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts")
                    .font(.system(size: 20, weight: .semibold))
                Text("Global hotkeys for recording, rewriting, and cancellation. Per-action trigger type is hidden behind a small menu on each row; chords are the default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            InfoPopoverButton(
                title: "Global shortcuts",
                body: "Single-key bindings (Caps Lock, Fn, side modifiers) listen via NSEvent and require Accessibility permission. Chord bindings go through Carbon's hot-key API and must include at least one modifier (⌘ ⌥ ⌃ ⇧). Each row's overflow menu (the small sliders icon) lets you switch between the two.",
                helpAnchor: "modifier-required"
            )
            .id("ShortcutsPane.globalShortcuts")
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Search shortcuts", text: $searchText)
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
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func groupedRows(rows: [ShortcutsRow]) -> some View {
        ForEach(ShortcutsRow.Group.allCases, id: \.self) { group in
            let groupRows = rows.filter { $0.group == group }
            if !groupRows.isEmpty {
                ShortcutSectionHeader(title: group.displayName)
                VStack(spacing: 0) {
                    ForEach(Array(groupRows.enumerated()), id: \.element.id) { index, row in
                        rowView(for: row)
                        if index < groupRows.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResults(rows: [ShortcutsRow]) -> some View {
        ShortcutSectionHeader(title: "Results")
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowView(for: row)
                if index < rows.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No shortcuts match \"\(searchText)\"")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    @ViewBuilder
    private func conflictBanner(text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.08))
            )
            .padding(.bottom, 8)
    }

    // MARK: - Row factory

    @ViewBuilder
    private func rowView(for row: ShortcutsRow) -> some View {
        switch row.kind {
        case .bindable(let action):
            ShortcutRowView(
                row: row,
                singleKey: singleKeyBinding(for: action),
                triggerType: triggerTypeValue(for: action),
                singleKeyConflicts: singleKeyConflicts(excluding: action),
                refreshToken: refreshToken,
                rowID: paneAnchor(for: row),
                onBindingChange: { refreshToken &+= 1 },
                onResetRow: { resetRow(for: $0) }
            )
            .id("ShortcutsPane.\(action.rawValue)")
        case .cancel:
            ShortcutRowView(
                row: row,
                singleKey: .constant(.none),
                triggerType: .chord,
                singleKeyConflicts: [:],
                refreshToken: refreshToken,
                rowID: paneAnchor(for: row),
                onBindingChange: {},
                onResetRow: { _ in }
            )
            .id("ShortcutsPane.cancelRecording")
        }
    }

    /// Maps a row to the legacy `pendingSettingsFieldAnchor` slug so the
    /// "Learn more →" deep-link from a settings popover continues to
    /// scroll the right row into view.
    private func paneAnchor(for row: ShortcutsRow) -> String? {
        switch row.kind {
        case .bindable(let action):
            switch action {
            case .toggleRecording:        return "toggle-recording"
            case .pushToTalk:             return "push-to-talk"
            case .pasteLastTranscription: return nil
            case .rewriteWithVoice:       return "articulate-custom"
            case .rewrite:                return "articulate-fixed"
            }
        case .cancel:
            return "cancel-recording"
        }
    }

    // MARK: - Bindings

    private func singleKeyBinding(for action: SingleKey.Action) -> Binding<SingleKey> {
        switch action {
        case .toggleRecording:        return $toggleSingleKey
        case .pushToTalk:             return $pushToTalkSingleKey
        case .pasteLastTranscription: return $pasteLastSingleKey
        case .rewriteWithVoice:       return $rewriteWithVoiceSingleKey
        case .rewrite:                return $rewriteSingleKey
        }
    }

    private func triggerTypeValue(for action: SingleKey.Action) -> SingleKey.TriggerType {
        // Force a dependency on the raw `@AppStorage` so SwiftUI re-renders
        // when the menu mutates it via `SingleKeyMigration.setTriggerType`.
        _ = triggerTypeRawValue(for: action)
        return SingleKeyMigration.effectiveTriggerType(for: action)
    }

    private func triggerTypeRawValue(for action: SingleKey.Action) -> String {
        switch action {
        case .toggleRecording:        return toggleTriggerTypeRaw
        case .pushToTalk:             return pushToTalkTriggerTypeRaw
        case .pasteLastTranscription: return pasteLastTriggerTypeRaw
        case .rewriteWithVoice:       return rewriteWithVoiceTriggerTypeRaw
        case .rewrite:                return rewriteTriggerTypeRaw
        }
    }

    // MARK: - Conflict computation

    private func singleKeyConflicts(
        excluding excludedAction: SingleKey.Action
    ) -> [SingleKey: SingleKey.Action] {
        var result: [SingleKey: SingleKey.Action] = [:]
        for action in SingleKey.Action.allCases where action != excludedAction {
            guard singleKeyIsActive(for: action) else { continue }
            let key = singleKeyValue(for: action)
            if key != .none {
                result[key] = action
            }
        }
        return result
    }

    private func singleKeyIsActive(for action: SingleKey.Action) -> Bool {
        switch SingleKeyMigration.storedTriggerType(for: action) {
        case .singleKey:
            return singleKeyValue(for: action) != .none
        case .chord:
            return false
        case nil:
            return singleKeyValue(for: action) != .none
        }
    }

    private func singleKeyValue(for action: SingleKey.Action) -> SingleKey {
        switch action {
        case .toggleRecording:        return toggleSingleKey
        case .pushToTalk:             return pushToTalkSingleKey
        case .pasteLastTranscription: return pasteLastSingleKey
        case .rewriteWithVoice:       return rewriteWithVoiceSingleKey
        case .rewrite:                return rewriteSingleKey
        }
    }

    /// Chord conflicts — same shortcut bound to multiple actions.
    private func conflictMessage() -> String? {
        var seen: [KeyboardShortcuts.Shortcut: [String]] = [:]
        for action in SingleKey.Action.allCases {
            guard chordIsActive(for: action) else { continue }
            if let shortcut = KeyboardShortcuts.getShortcut(for: action.keyboardShortcutsName) {
                seen[shortcut, default: []].append(action.displayName)
            }
        }
        let duplicates = seen.filter { $0.value.count > 1 }
        guard let first = duplicates.first else { return nil }
        return "Conflict: \(first.value.joined(separator: " and ")) share the same chord."
    }

    private func chordIsActive(for action: SingleKey.Action) -> Bool {
        switch SingleKeyMigration.storedTriggerType(for: action) {
        case .singleKey:
            return false
        case .chord:
            return KeyboardShortcuts.getShortcut(for: action.keyboardShortcutsName) != nil
        case nil:
            return KeyboardShortcuts.getShortcut(for: action.keyboardShortcutsName) != nil
        }
    }

    // MARK: - Reset

    /// Reset a single row to the build-in defaults. Mirrors the per-row
    /// Reset affordance shown in the Option A mockup (hover-revealed on
    /// the right of the row).
    private func resetRow(for action: SingleKey.Action) {
        switch action {
        case .toggleRecording:
            toggleSingleKey = .capsLock
            KeyboardShortcuts.reset(.toggleRecording)
            SingleKeyMigration.setTriggerType(.singleKey, for: .toggleRecording)
        case .pushToTalk:
            pushToTalkSingleKey = .none
            KeyboardShortcuts.reset(.pushToTalk)
            SingleKeyMigration.setTriggerType(.chord, for: .pushToTalk)
        case .pasteLastTranscription:
            pasteLastSingleKey = .none
            KeyboardShortcuts.reset(.pasteLastTranscription)
            SingleKeyMigration.setTriggerType(.chord, for: .pasteLastTranscription)
        case .rewriteWithVoice:
            rewriteWithVoiceSingleKey = .none
            KeyboardShortcuts.reset(.rewriteWithVoice)
            SingleKeyMigration.setTriggerType(.chord, for: .rewriteWithVoice)
        case .rewrite:
            rewriteSingleKey = .none
            KeyboardShortcuts.reset(.rewrite)
            SingleKeyMigration.setTriggerType(.chord, for: .rewrite)
        }
        refreshToken &+= 1
    }

    // MARK: - Deep-link scroll

    private func consumePendingSettingsFieldAnchor(with proxy: ScrollViewProxy) {
        guard let anchor = navigator.pendingSettingsFieldAnchor,
              Self.supportedSettingsAnchors.contains(anchor)
        else { return }
        withAnimation {
            proxy.scrollTo(anchor, anchor: .top)
        }
        navigator.clearPendingSettingsFieldAnchor()
    }

    private static let supportedSettingsAnchors: Set<String> = [
        "toggle-recording",
        "push-to-talk",
        "articulate-custom",
        "articulate-fixed",
        "cancel-recording",
    ]
}
