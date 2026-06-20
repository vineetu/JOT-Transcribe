import KeyboardShortcuts

/// Canonical names for every global shortcut Jot registers. Declared in one
/// place so `HotkeyRouter`, the Settings pane, and the Setup Wizard all
/// refer to the same identities.
///
/// Defaults match the feature inventory:
///   - toggleRecording: ⌥Space (always-on)
///   - cancelRecording: Esc with no modifiers (dynamic — only active while
///     a cancellable pipeline is running). NOT shown in Settings — treated
///     as a hardcoded key the user can't rebind.
///   - pushToTalk: unbound by default (user opts in from Settings)
///   - pasteLastTranscription: ⌥,
///   - rewriteWithVoice: ⌥. (v1.4 introduced this binding under raw-value
///     storage key `"rewriteSelection"`; v1.6 carried that key forward
///     under the new Swift symbol so user-customized bindings survive
///     every Swift-level rename. Only the Swift symbol moved.)
///   - rewrite: ⌥/ — v1.5 addition. Same selection → LLM → paste pipeline
///     as `rewriteWithVoice`, but with a hardcoded instruction string and
///     no voice step. The KeyboardShortcuts raw-value storage key remains
///     stable across renames so any v1.5 user-customized binding survives.
/// Keep raw string declarations in sync with
/// `SingleKey.Action.rawKeyboardShortcutsName`.
extension KeyboardShortcuts.Name {
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.space, modifiers: [.option])
    )

    static let cancelRecording = Self(
        "cancelRecording",
        default: .init(.escape, modifiers: [])
    )

    static let pushToTalk = Self("pushToTalk")

    static let pasteLastTranscription = Self(
        "pasteLastTranscription",
        default: .init(.comma, modifiers: [.option])
    )

    /// User-facing name: "Rewrite with Voice". Raw-value storage key stays
    /// `"rewriteSelection"` so any binding customized in v1.4 / v1.5
    /// survives the v1.6 rename.
    static let rewriteWithVoice = Self(
        "rewriteSelection",
        default: .init(.period, modifiers: [.option])
    )

    /// User-facing name: "Rewrite". Raw-value storage key stays
    /// `"articulate"` so any binding customized in v1.5 survives the
    /// v1.6 rename.
    static let rewrite = Self(
        "articulate",
        default: .init(.slash, modifiers: [.option])
    )

    /// Slice D (ask-before-paste). Confirm the live "Did you mean X?" pill —
    /// apply the offered term and paste. Bound to plain Return, and like
    /// `cancelRecording` it is **dynamic**: enabled ONLY while the pill is in
    /// `.askCorrection`, disabled otherwise, so it never steals Return from
    /// other apps. NOT shown in Settings (a hardcoded, non-rebindable key).
    static let confirmCorrection = Self(
        "confirmCorrection",
        default: .init(.return, modifiers: [])
    )

    /// Slice D. Dismiss the live "Did you mean X?" pill — keep the original
    /// word and paste. Bound to plain Esc; dynamic, enabled ONLY while the pill
    /// is in `.askCorrection`. NOT shown in Settings.
    static let dismissCorrection = Self(
        "dismissCorrection",
        default: .init(.escape, modifiers: [])
    )
}
