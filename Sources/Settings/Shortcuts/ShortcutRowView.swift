import KeyboardShortcuts
import SwiftUI

/// One row in the redesigned Shortcuts pane.
///
/// Layout (Option A in the design doc):
///   • Left column: title (15 pt semibold) → subtitle + inline badge.
///   • Right column: hover-revealed Reset · Mode menu · binding chip · info popover.
///
/// The binding chip is one of three concrete subviews depending on the
/// row's effective trigger type:
///   • `ShortcutSingleKeyChip` — when the user is on the single-key
///     binding for this action.
///   • `ShortcutChordChip` — when the user is on the chord binding.
///   • A static "esc" pill for the Cancel pseudo-row (read-only).
///
/// The mode menu (chord vs single-key) is the discreet escape hatch the
/// design doc's "infer from input" target couldn't reach without a fully
/// custom recorder. Tucked as a `Menu` behind a small icon so it stays
/// out of the way of the 95% case while keeping the dual-mode storage
/// shape user-controllable.
struct ShortcutRowView: View {
    let row: ShortcutsRow
    /// Per-action single-key `@AppStorage` binding owned by the parent
    /// pane. Bindable rows only — the cancel row ignores this.
    let singleKey: Binding<SingleKey>
    let triggerType: SingleKey.TriggerType
    /// Snapshot of "who owns which single-key right now," excluding this
    /// row's own selection. Used by `ShortcutSingleKeyChip` for the
    /// conflict-disabled menu items.
    let singleKeyConflicts: [SingleKey: SingleKey.Action]
    /// Bumped by chord-recorder commits + mode-menu changes so the
    /// parent's conflict computation re-runs. Read into `_` here so the
    /// row re-renders on the same tick — the chord chip caches the
    /// framework's stored shortcut.
    let refreshToken: Int
    /// Anchor target for `ScrollViewReader` deep-links from
    /// `InfoPopoverButton`'s "Learn more →" footer + the legacy
    /// `pendingSettingsFieldAnchor` route.
    let rowID: String?
    /// Called when the row's binding (single-key, chord, or trigger
    /// type) changes. Parent uses this to bump its refresh token /
    /// re-run conflict detection.
    let onBindingChange: () -> Void
    /// Called when the user hits the hover-revealed Reset affordance.
    /// Receives the action so the parent can scope the reset to one row
    /// rather than re-resetting the whole pane.
    let onResetRow: (SingleKey.Action) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let _ = refreshToken
        HStack(alignment: .top, spacing: 12) {
            // Left column: title + subtitle + badge.
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(row.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ShortcutBadge(firing: row.firing)
                }
            }

            Spacer(minLength: 12)

            // Right column: secondary actions + binding chip + info.
            HStack(spacing: 8) {
                rightControls
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .modifier(RowIDModifier(rowID: rowID))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(row.title). \(row.subtitle). \(row.firing.label)."))
    }

    @ViewBuilder
    private var rightControls: some View {
        switch row.kind {
        case .bindable(let action):
            bindableControls(action: action)
        case .cancel:
            cancelControls
        }
    }

    @ViewBuilder
    private func bindableControls(action: SingleKey.Action) -> some View {
        // Hover-revealed Reset. Held in the layout (using opacity rather
        // than removal) so the chip position doesn't shift when the
        // cursor enters/leaves the row.
        Button(action: { onResetRow(action) }) {
            Label("Reset", systemImage: "arrow.uturn.backward")
                .labelStyle(.iconOnly)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(isHovered ? 1.0 : 0.0)
        .accessibilityLabel("Reset \(row.title)")
        .help("Reset to default")
        .allowsHitTesting(isHovered)

        // Mode switch (chord <-> single key). Only the icon shows; the
        // menu carries the two options + the current mode as a checkmark.
        Menu {
            Picker("Trigger type", selection: triggerTypeBinding(for: action)) {
                Text("Chord (modifiers + key)").tag(SingleKey.TriggerType.chord)
                Text("Single key (Caps Lock, Fn, side modifier)").tag(SingleKey.TriggerType.singleKey)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovered ? 1.0 : 0.45)
        .help("Switch between chord and single-key trigger")

        // The active binding chip.
        if triggerType == .singleKey {
            ShortcutSingleKeyChip(
                action: action,
                selection: Binding(
                    get: { singleKey.wrappedValue },
                    set: { newValue in
                        singleKey.wrappedValue = newValue
                        onBindingChange()
                    }
                ),
                conflicts: singleKeyConflicts
            )
        } else {
            ShortcutChordChip(action: action, onChange: onBindingChange)
        }

        InfoPopoverButton(
            title: row.title,
            body: popoverBody(for: action),
            helpAnchor: row.helpAnchor
        )
    }

    @ViewBuilder
    private var cancelControls: some View {
        Text("esc")
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            )
            .foregroundStyle(.secondary)
            .accessibilityLabel("Escape (not configurable)")

        InfoPopoverButton(
            title: row.title,
            body: "Press Escape to cancel an active recording, transform, or rewrite. Hardcoded and not configurable — only active while Jot is mid-capture.",
            helpAnchor: row.helpAnchor
        )
    }

    private func triggerTypeBinding(for action: SingleKey.Action) -> Binding<SingleKey.TriggerType> {
        Binding(
            get: { triggerType },
            set: { newValue in
                SingleKeyMigration.setTriggerType(newValue, for: action)
                onBindingChange()
            }
        )
    }

    private func popoverBody(for action: SingleKey.Action) -> String {
        let chordDefinition = "A chord is a multi-key global hotkey — at least one modifier (⌘ ⌥ ⌃ ⇧) plus another key. Single-key bindings (Caps Lock, Fn, side modifiers) use NSEvent listening and require Accessibility permission."
        switch action {
        case .toggleRecording:
            return "\(chordDefinition) Caps Lock is the recommended single-key — the keyboard LED becomes your recording indicator."
        case .pushToTalk:
            return "\(chordDefinition) Hold the binding to record; release to stop and transcribe."
        case .pasteLastTranscription:
            return "\(chordDefinition) Single press re-pastes the most recent transcript or rewrite at the cursor."
        case .rewriteWithVoice:
            return "\(chordDefinition) Select text in any app, press the binding to start dictating an instruction, press again to send. The selection is replaced with the LLM's response."
        case .rewrite:
            return "\(chordDefinition) Select text in any app, press the binding to apply the built-in Rewrite prompt. No voice instruction step."
        }
    }
}

/// `ScrollViewReader.scrollTo(...)` looks up rows by SwiftUI ID. The
/// optional anchor on `ShortcutRowView` is conditionally applied via
/// this modifier so the non-anchored cases don't pollute the SwiftUI
/// identity tree with empty IDs.
private struct RowIDModifier: ViewModifier {
    let rowID: String?
    func body(content: Content) -> some View {
        if let rowID {
            content.id(rowID)
        } else {
            content
        }
    }
}
