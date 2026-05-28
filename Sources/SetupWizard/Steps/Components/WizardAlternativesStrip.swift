import KeyboardShortcuts
import SwiftUI

/// The three quick-pick chips + Custom button that sit below the focal
/// chip on the redesigned `TestStep`. Tapping a chip binds the
/// `.toggleRecording` action to that single key in one click; tapping
/// "Custom…" toggles the focal chip into chord-recorder mode (handled by
/// the parent).
///
/// The active chip (matching the user's current binding) is rendered with
/// an accent border + filled background so the strip doubles as a state
/// indicator. Suppressing the active chip from the strip — per the design
/// doc's Open Question 1 default (three chips + Custom; upgraders see Caps
/// Lock added in place of whatever they're already on) — would add
/// "shifted layout when binding changes" friction. We instead keep all
/// three chips visible and use the selection ring to mark the active one.
///
/// Tap semantics: writes to `SingleKey` storage and switches trigger type
/// to `.singleKey` via `SingleKeyMigration.setTriggerType(...)`. The
/// `HotkeyRouter`'s `UserDefaults.didChangeNotification` subscription
/// picks this up and rebinds within the same runloop tick.
struct WizardAlternativesStrip: View {
    /// Currently-active single-key (if any). Nil/none when the user is
    /// on a chord binding.
    let activeSingleKey: SingleKey
    /// True when the parent is hosting a custom recorder inside the focal
    /// chip — used to highlight the "Custom…" button accordingly.
    let isCustomActive: Bool
    /// Tap a quick-pick chip → apply this single key.
    let onPickSingleKey: (SingleKey) -> Void
    /// Tap Custom… → toggle the inline recorder open/closed.
    let onToggleCustom: () -> Void

    /// The three keys offered as quick-picks. Match the design doc's
    /// recommendation: Caps Lock (the new default), ⌥ Space (the legacy
    /// default), and Right Option (the most-requested alt single-key).
    /// ⌥ Space is the chord default exposed via the Custom… recorder, not
    /// a quick-pick — but we surface it here as a labelled chip that
    /// switches to a chord binding when tapped.
    private let quickPicks: [SingleKey] = [.capsLock, .rightOption]

    var body: some View {
        HStack(spacing: 8) {
            Text("Or pick one:")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ForEach(quickPicks) { key in
                quickPickChip(for: key)
            }

            // The legacy ⌥ Space default is a chord, not a single-key.
            // We expose it as its own labelled chip that writes a chord
            // binding directly (chord storage + trigger type = .chord).
            chordQuickPickChip(
                label: "⌥ Space",
                shortcut: KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
            )

            Button {
                onToggleCustom()
            } label: {
                Text(isCustomActive ? "Cancel" : "Custom…")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isCustomActive
                                  ? Color.accentColor.opacity(0.15)
                                  : Color.secondary.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isCustomActive
                                          ? Color.accentColor.opacity(0.55)
                                          : Color.primary.opacity(0.10),
                                          lineWidth: 1)
                    )
                    .foregroundStyle(isCustomActive ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCustomActive ? "Cancel custom shortcut" : "Set a custom shortcut")
        }
    }

    // MARK: - Single-key chip

    @ViewBuilder
    private func quickPickChip(for key: SingleKey) -> some View {
        let isActive = (activeSingleKey == key)
        Button {
            onPickSingleKey(key)
        } label: {
            HStack(spacing: 4) {
                Text(key.glyph)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(key.displayName)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? Color.accentColor.opacity(0.15)
                          : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive
                                  ? Color.accentColor.opacity(0.55)
                                  : Color.primary.opacity(0.10),
                                  lineWidth: 1)
            )
            .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive
                            ? "\(key.displayName) (currently bound)"
                            : "Bind to \(key.displayName)")
    }

    // MARK: - Chord chip (one-click chord binding)

    /// Quick-pick for the legacy ⌥ Space default. Writes through the
    /// `KeyboardShortcuts` API + flips the trigger type to `.chord` so
    /// `HotkeyRouter` picks it up the same way the chord recorder does.
    @ViewBuilder
    private func chordQuickPickChip(
        label: String,
        shortcut: KeyboardShortcuts.Shortcut
    ) -> some View {
        let isActive = isChordActive(shortcut)
        Button {
            SingleKeyMigration.setTriggerType(.chord, for: .toggleRecording)
            KeyboardShortcuts.setShortcut(shortcut, for: .toggleRecording)
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive
                              ? Color.accentColor.opacity(0.15)
                              : Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive
                                      ? Color.accentColor.opacity(0.55)
                                      : Color.primary.opacity(0.10),
                                      lineWidth: 1)
                )
                .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "\(label) (currently bound)" : "Bind to \(label)")
    }

    private func isChordActive(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let binding = SingleKeyMigration.effectiveBinding(for: .toggleRecording)
        guard binding.triggerType == .chord else { return false }
        return binding.chordDescription == shortcut.description
    }
}
