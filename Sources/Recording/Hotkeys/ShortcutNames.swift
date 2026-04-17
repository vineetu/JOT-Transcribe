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
///   - pasteLastTranscription: ⌥.
///   - rewriteSelection: ⌥/
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
        default: .init(.period, modifiers: [.option])
    )

    static let rewriteSelection = Self(
        "rewriteSelection",
        default: .init(.slash, modifiers: [.option])
    )
}
