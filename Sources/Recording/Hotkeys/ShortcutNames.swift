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
///   - articulateCustom: ⌥. (v1.5 rename of `rewriteSelection`; the
///     KeyboardShortcuts raw-value storage key is preserved as
///     `"rewriteSelection"` so any user-customized binding survives the
///     rename. Only the Swift symbol moved.)
///   - articulate: ⌥/ — v1.5 addition. Same selection → LLM → paste
///     pipeline as articulateCustom, but with a hardcoded instruction
///     string and no voice step.
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

    /// User-facing name: "Articulate (Custom)". Raw-value storage key stays
    /// `"rewriteSelection"` so any binding customized in v1.4 survives the
    /// v1.5 rename.
    static let articulateCustom = Self(
        "rewriteSelection",
        default: .init(.period, modifiers: [.option])
    )

    /// v1.5 — fixed-prompt Articulate.
    static let articulate = Self(
        "articulate",
        default: .init(.slash, modifiers: [.option])
    )
}
