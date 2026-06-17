import AppKit
import KeyboardShortcuts

/// User-selectable single-key bindings. These bypass the Carbon Hot Key
/// API (`KeyboardShortcuts`/`MASShortcut`/`HotKey` all wrap it and all
/// refuse modifier-less bindings) by listening to `NSEvent.flagsChanged`
/// directly.
///
/// Each binding has two halves:
///   1. The *key* (this enum) — which physical key to watch.
///   2. The *action's mode* (`SingleKey.Action.mode`) — how presses of
///      that key map to start/stop semantics.
///
/// Why one enum for keys + a separate enum for actions:
///   - The keys are a closed set defined by macOS's `flagsChanged` event
///     stream (Caps Lock, Fn, the four side-specific modifiers, and the
///     four side-agnostic modifiers).
///   - The actions (Toggle Recording, Push to Talk, Paste Last, Rewrite,
///     Rewrite with Voice) decide the *mode* — same key behaves
///     differently depending on which action it's bound to. Right ⌥ on
///     Toggle Recording = tap-to-toggle; same key on Push to Talk =
///     hold-while-talking; same key on Paste Last = single tap fires.
enum SingleKey: String, CaseIterable, Identifiable, Sendable {
    case none
    case capsLock
    case fn
    case rightOption
    case rightCommand
    case rightShift
    case rightControl
    // Function keys (F1–F20). Unlike the modifier keys above, these are
    // ordinary keys that arrive as `keyDown`/`keyUp` (not `flagsChanged`),
    // so they're detected via a keyCode-matched key-event path rather than
    // a modifier-flag transition. See `isFunctionKey` and `SingleKeyHotkey`.
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:          return "None"
        case .capsLock:      return "Caps Lock"
        case .fn:            return "Fn / Globe"
        case .rightOption:   return "Right Option (⌥)"
        case .rightCommand:  return "Right Command (⌘)"
        case .rightShift:    return "Right Shift (⇧)"
        case .rightControl:  return "Right Control (⌃)"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return rawValue.uppercased()
        }
    }

    /// Short user-facing rendering used by Wizard / Status pill.
    var glyph: String {
        switch self {
        case .none:          return ""
        case .capsLock:      return "⇪"
        case .fn:            return "fn"
        case .rightOption:   return "⌥"
        case .rightCommand:  return "⌘"
        case .rightShift:    return "⇧"
        case .rightControl:  return "⌃"
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return rawValue.uppercased()
        }
    }

    /// Set of `kVK_*` codes that match this binding. Caller MUST gate
    /// the event handler on `keyCodes.contains(event.keyCode)` —
    /// `flagsChanged` fires for ANY modifier transition (e.g. pressing
    /// Shift while Caps Lock is on) and without the keyCode filter
    /// we'd fire spuriously.
    var keyCodes: Set<UInt16> {
        switch self {
        case .none:          return []
        case .capsLock:      return [0x39] // kVK_CapsLock
        case .fn:            return [0x3F] // kVK_Function
        case .rightOption:   return [0x3D] // kVK_RightOption
        case .rightCommand:  return [0x36] // kVK_RightCommand
        case .rightShift:    return [0x3C] // kVK_RightShift
        case .rightControl:  return [0x3E] // kVK_RightControl
        case .f1:            return [0x7A] // kVK_F1
        case .f2:            return [0x78] // kVK_F2
        case .f3:            return [0x63] // kVK_F3
        case .f4:            return [0x76] // kVK_F4
        case .f5:            return [0x60] // kVK_F5
        case .f6:            return [0x61] // kVK_F6
        case .f7:            return [0x62] // kVK_F7
        case .f8:            return [0x64] // kVK_F8
        case .f9:            return [0x65] // kVK_F9
        case .f10:           return [0x6D] // kVK_F10
        case .f11:           return [0x67] // kVK_F11
        case .f12:           return [0x6F] // kVK_F12
        case .f13:           return [0x69] // kVK_F13
        case .f14:           return [0x6B] // kVK_F14
        case .f15:           return [0x71] // kVK_F15
        case .f16:           return [0x6A] // kVK_F16
        case .f17:           return [0x40] // kVK_F17
        case .f18:           return [0x4F] // kVK_F18
        case .f19:           return [0x50] // kVK_F19
        case .f20:           return [0x5A] // kVK_F20
        }
    }

    /// Function keys arrive as ordinary `keyDown`/`keyUp` events (not
    /// `flagsChanged`), so `SingleKeyHotkey` routes them through a
    /// keyCode-matched key-event path instead of the modifier-flag
    /// transition path used by Caps Lock / Fn / the side modifiers.
    var isFunctionKey: Bool {
        switch self {
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return true
        default:
            return false
        }
    }

    /// The modifier-flag bit set in `event.modifierFlags` when this
    /// binding is currently active. For Caps Lock that's the latched LED
    /// state; for everything else it's "key currently held."
    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .none:          return nil
        case .capsLock:      return .capsLock
        case .fn:            return .function
        case .rightOption:   return .option
        case .rightCommand:  return .command
        case .rightShift:    return .shift
        case .rightControl:  return .control
        // Function keys are not modifiers — they have no `modifierFlags`
        // bit. Detection happens via keyDown/keyUp keyCode matching.
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
             .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20:
            return nil
        }
    }

    /// Caps Lock is the only physically-latched key here — the OS stores
    /// the LED state, so successive "presses" alternate flag ON / flag
    /// OFF cleanly. Used by `SingleKeyHotkey` to decide between the
    /// natural-toggle path (Caps Lock) and the synthetic-toggle path
    /// (every other key, where toggle behavior is faked from press
    /// edges).
    var isLatched: Bool { self == .capsLock }
}

// MARK: - Action mapping

extension SingleKey {
    enum TriggerType: String, Sendable, CaseIterable {
        case singleKey
        case chord

        var displayName: String {
            switch self {
            case .singleKey: return "Single key"
            case .chord:     return "Chord"
            }
        }
    }

    /// The five user-bindable hotkey actions. Each declares its trigger
    /// mode and the picker set it shows. Maps 1:1 to `KeyboardShortcuts.Name`
    /// — the chord side of each binding still flows through there.
    enum Action: String, CaseIterable, Sendable {
        case toggleRecording
        case pushToTalk
        case pasteLastTranscription
        case rewriteWithVoice
        case rewrite

        /// `@AppStorage` / `UserDefaults` key for this action's single-key
        /// choice. Stable across renames (matches the old
        /// `jot.hotkey.toggleRecording.singleKey` so existing users don't
        /// reset).
        var storageKey: String { "jot.hotkey.\(rawValue).singleKey" }

        /// `@AppStorage` / `UserDefaults` key for this action's active trigger type.
        var triggerTypeStorageKey: String { "jot.hotkey.\(rawValue).triggerType" }

        /// Raw `KeyboardShortcuts` storage name. Use for raw defaults reads so
        /// `KeyboardShortcuts.Name.init` cannot seed defaults while classifying.
        var rawKeyboardShortcutsName: String {
            switch self {
            case .toggleRecording:        return "toggleRecording"
            case .pushToTalk:             return "pushToTalk"
            case .pasteLastTranscription: return "pasteLastTranscription"
            case .rewriteWithVoice:       return "rewriteSelection"
            case .rewrite:                return "articulate"
            }
        }

        /// Runtime `KeyboardShortcuts` name. This may initialize declared defaults;
        /// do not use it for raw migration classification.
        var keyboardShortcutsName: KeyboardShortcuts.Name {
            switch self {
            case .toggleRecording:        return .toggleRecording
            case .pushToTalk:             return .pushToTalk
            case .pasteLastTranscription: return .pasteLastTranscription
            case .rewriteWithVoice:       return .rewriteWithVoice
            case .rewrite:                return .rewrite
            }
        }

        var hasDeclaredChordDefault: Bool {
            switch self {
            case .pushToTalk:
                return false
            case .toggleRecording, .pasteLastTranscription, .rewriteWithVoice, .rewrite:
                return true
            }
        }

        var defaultChordDescription: String? {
            switch self {
            case .toggleRecording:        return "⌥Space"
            case .pushToTalk:             return nil
            case .pasteLastTranscription: return "⌥,"
            case .rewriteWithVoice:       return "⌥."
            case .rewrite:                return "⌥/"
            }
        }

        var defaultTriggerType: TriggerType {
            switch self {
            case .toggleRecording:
                return .singleKey
            case .pushToTalk, .pasteLastTranscription, .rewriteWithVoice, .rewrite:
                return .chord
            }
        }

        /// User-facing label for the row in Settings → Shortcuts.
        var displayName: String {
            switch self {
            case .toggleRecording:        return "Toggle recording"
            case .pushToTalk:             return "Push to talk"
            // Display label says "result" because v1.9.5 broadened this
            // hotkey to replay the most recent Jot output — dictation OR
            // rewrite, whichever fired more recently. Storage key
            // (`rawValue: "pasteLastTranscription"`, raw KeyboardShortcuts
            // name `"pasteLastTranscription"`) stays the same so existing
            // user bindings survive the rename.
            case .pasteLastTranscription: return "Paste last result"
            case .rewriteWithVoice:       return "Rewrite with Voice"
            case .rewrite:                return "Rewrite"
            }
        }

        /// How presses of the bound single-key map to start/stop:
        ///   • `.toggle` — tap to start, tap to stop. Toggle Recording
        ///     (the Caps-Lock-as-LED-indicator hero) and Rewrite with
        ///     Voice (instructions are usually short — tap-tap-done is
        ///     friendlier than holding a modifier while speaking).
        ///   • `.hold` — start while held, stop on release. Push to
        ///     Talk's defining shape.
        ///   • `.tap` — fire once on press. Paste Last is single-shot with
        ///     no ongoing state.
        ///   • Rewrite is `.hold` so the press/release pair drives the
        ///     Prompt Picker tap-vs-hold dispatcher (`RewriteHoldDetector`):
        ///     onStart begins the 1.2s threshold timer, onStop either fires
        ///     today's default Rewrite (early release) or is a no-op
        ///     (picker already opened). Single-shot tap semantics are
        ///     preserved at the dispatcher layer.
        var mode: TriggerMode {
            switch self {
            case .toggleRecording, .rewriteWithVoice: return .toggle
            case .pushToTalk, .rewrite:                return .hold
            case .pasteLastTranscription:              return .tap
            }
        }

        /// Keys offered in this action's single-key picker. Caps Lock is
        /// reserved for Toggle Recording — the headline single-key feature
        /// — and excluded everywhere else. For the other actions, all
        /// momentary modifiers (Fn, side-specific, and side-agnostic) are
        /// offered. Function keys (F1–F20) are offered for every action.
        var pickerCases: [SingleKey] {
            self == .toggleRecording
                ? [.capsLock] + SingleKey.modifierCases + SingleKey.functionKeyCases
                : SingleKey.modifierCases + SingleKey.functionKeyCases
        }
    }

    /// Trigger semantics — see `SingleKey.Action.mode`.
    enum TriggerMode: Sendable {
        case hold, toggle, tap
    }

    /// All non-Caps-Lock modifier options, ordered for the picker.
    static let modifierCases: [SingleKey] = [
        .fn,
        .rightOption, .rightCommand, .rightShift, .rightControl,
    ]

    /// Function-key options (F1–F20), ordered for the picker. Grouped
    /// under a "Function keys" header in the single-key menu.
    static let functionKeyCases: [SingleKey] = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]
}

// MARK: - Backwards-compat shim

extension SingleKey {
    /// Legacy alias for `SingleKey.Action.toggleRecording.storageKey`.
    /// Older callers (Setup Wizard, migration) still reference this;
    /// the value is the same string so no UserDefaults migration is
    /// required.
    static let storageKey: String = SingleKey.Action.toggleRecording.storageKey
}
