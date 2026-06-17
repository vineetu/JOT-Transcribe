import SwiftUI

/// Menu-styled chip used when the action's effective trigger type is
/// `.singleKey`. Mirrors the affordance Toggle Recording has had since
/// v1.6 (Caps Lock / Fn / side-modifier picker) but rendered as a
/// chip-styled `Menu` so it lines up visually with the chord recorder
/// chip on adjacent rows.
///
/// Conflict handling: if another action has already claimed a single-key
/// (excluding this row's own selection), that entry is rendered with the
/// other action's name appended ("Right Option (⌥) — used by Push to
/// Talk") and disabled. Matches the legacy `ShortcutsPane` semantics so
/// users can't double-bind a key to two actions silently.
struct ShortcutSingleKeyChip: View {
    let action: SingleKey.Action
    @Binding var selection: SingleKey
    /// Map of "this key is currently claimed by THAT action," excluding
    /// the row's own selection. Computed once per render by the parent
    /// so each row sees the same snapshot.
    let conflicts: [SingleKey: SingleKey.Action]

    var body: some View {
        Menu {
            Button("None") { selection = .none }
            Divider()
            // Modifier-key options (Caps Lock / Fn / side modifiers).
            ForEach(modifierPickerCases) { key in
                keyButton(for: key)
            }
            // Function keys grouped under their own labeled section.
            if !functionPickerCases.isEmpty {
                Section("Function keys") {
                    ForEach(functionPickerCases) { key in
                        keyButton(for: key)
                    }
                }
            }
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// The action's non-function-key picker options, in declared order.
    private var modifierPickerCases: [SingleKey] {
        action.pickerCases.filter { !$0.isFunctionKey }
    }

    /// The action's function-key picker options (F1–F20).
    private var functionPickerCases: [SingleKey] {
        action.pickerCases.filter { $0.isFunctionKey }
    }

    @ViewBuilder
    private func keyButton(for key: SingleKey) -> some View {
        let conflict = conflicts[key]
        Button {
            selection = key
        } label: {
            if let conflict {
                Text("\(key.displayName) — used by \(conflict.displayName)")
            } else {
                Text(key.displayName)
            }
        }
        .disabled(conflict != nil && selection != key)
    }

    @ViewBuilder
    private var chipLabel: some View {
        // Always show the full human-readable display name ("Caps Lock",
        // "Fn / Globe", "Right Option (⌥)" …) — never just the glyph in
        // isolation. The chord chip on adjacent rows is a full
        // `KeyboardShortcuts.Recorder` text-field; making this chip the
        // same physical size keeps the right column visually consistent
        // across rows regardless of which trigger mode is active.
        // Sized to match KeyboardShortcuts.Recorder's NSView intrinsics —
        // `minimumWidth = 130, height = 24` per RecorderCocoa.swift:30,93.
        // Locking both dimensions keeps the right column visually aligned
        // whether a row is in chord mode or single-key mode.
        Text(displayText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selection == .none ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .frame(width: ShortcutChipSize.width, height: ShortcutChipSize.height, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var displayText: String {
        selection == .none ? "Not set" : selection.displayName
    }
}
