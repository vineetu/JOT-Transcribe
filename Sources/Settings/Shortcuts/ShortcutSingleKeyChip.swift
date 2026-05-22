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
            ForEach(action.pickerCases) { key in
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
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 4) {
            if selection == .none {
                Text("Not set")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else if !selection.glyph.isEmpty {
                Text(selection.glyph)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                Text(selection.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
