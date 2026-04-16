import KeyboardShortcuts

/// Canonical names for every global shortcut Jot registers. Declared in one
/// place so `HotkeyRouter`, the future Settings pane, and the Setup Wizard
/// all refer to the same identities.
///
/// Defaults match the feature inventory:
///   - toggleRecording: ⌥Space (always-on)
///   - cancelRecording: Esc with no modifiers (dynamic — only active while recording)
///   - pushToTalk: unbound by default (user opts in from Settings)
///   - pasteLastTranscription: unbound by default
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

    static let pasteLastTranscription = Self("pasteLastTranscription")

    static let rewriteSelection = Self("rewriteSelection")
}
