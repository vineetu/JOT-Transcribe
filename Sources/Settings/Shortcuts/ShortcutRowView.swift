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
        HStack(alignment: .center, spacing: 12) {
            // v1.14: row subtitle removed — it duplicated the info popover
            // and crowded the left column. The popover (rightmost dot) is
            // where the feature description lives; the title carries the
            // identity and the firing badge carries the gating context.
            Text(row.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            // Firing-context pill in its own slot, just before the controls.
            // Sized to its content (`fixedSize()` inside `ShortcutBadge`),
            // never wraps. Sits at a consistent x across rows because the
            // controls to its right are all fixed-width.
            ShortcutBadge(firing: row.firing)

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
        .accessibilityLabel(Text("\(row.title). \(row.firing.label)."))
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
                Text("Single key (Caps Lock, Fn, side modifier, F1–F20)").tag(SingleKey.TriggerType.singleKey)
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

        // Fixed-width chip slot. Same container for chord recorder,
        // single-key menu, and the cancel "esc" pill on the cancel row —
        // anchors the right column so the trailing InfoPopover dot stays
        // pinned at the same x across every row regardless of which chip
        // variant the row is rendering.
        ZStack {
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
        }
        .frame(width: ShortcutChipSize.width, height: ShortcutChipSize.height)

        InfoPopoverButton(
            title: row.title,
            body: popoverBody(for: action),
            helpAnchor: row.helpAnchor
        )
    }

    @ViewBuilder
    private var cancelControls: some View {
        // Invisible mirrors of the reset button and mode-menu icon in
        // bindable rows. `.hidden()` keeps the layout footprint so the
        // chip slot lines up at the same x as the bindable rows above —
        // and any future tweak to the real icons' sizes carries over to
        // these placeholders automatically because they reuse the exact
        // same modifiers.
        Label("Reset", systemImage: "arrow.uturn.backward")
            .labelStyle(.iconOnly)
            .font(.system(size: 11))
            .hidden()

        Image(systemName: "slider.horizontal.3")
            .font(.system(size: 11))
            .frame(width: 18, height: 18)
            .hidden()

        // Same fixed-width slot as the bindable rows so "esc" lines up
        // pixel-for-pixel with the chord recorder and single-key menu in
        // the column above it.
        ZStack {
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
        }
        .frame(width: ShortcutChipSize.width, height: ShortcutChipSize.height)

        InfoPopoverButton(
            title: row.title,
            // v1.14 recording-safety contract: Esc no longer discards the
            // recording. It stops, transcribes, and saves the result to
            // Recents — the paste step is skipped. For an in-flight
            // transform / rewrite (after the recording moment) Esc still
            // aborts the operation outright.
            body: "Press Esc to stop an in-flight recording — the transcript is saved to Recents without pasting. While Jot is transcribing or rewriting, Esc aborts the operation. Hardcoded to Esc, only listens while Jot is mid-capture.",
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

    /// v1.14: per-row popovers describe the *feature*, not the binding
    /// mechanics. The chord-vs-single-key explanation lives only in the
    /// top-level "Global shortcuts" popover in the pane header
    /// (`ShortcutsPane.header`) where it isn't duplicated five times.
    private func popoverBody(for action: SingleKey.Action) -> String {
        switch action {
        case .toggleRecording:
            return "Tap to start dictating, tap again to stop. The transcript pastes at your cursor."
        case .pushToTalk:
            return "Hold the key to dictate, release to stop and paste — like a walkie-talkie. Useful when you want recording to stop the instant you let go."
        case .pasteLastTranscription:
            return "Re-paste the most recent transcript or rewrite at the cursor. Useful for dropping the same text into a second app without dictating again."
        case .rewriteWithVoice:
            return "Select text in any app, press the key to start dictating an instruction, press again to send. Jot replaces the selection with the LLM's response."
        case .rewrite:
            return "Select text in any app, tap to apply the default Rewrite prompt. Hold to open the prompt picker and choose a different one."
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
