import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self(
        "toggleRecording",
        default: .init(.space, modifiers: [.option])
    )
    static let cancelRecording = Self(
        "cancelRecording",
        default: .init(.escape, modifiers: [])
    )
}
