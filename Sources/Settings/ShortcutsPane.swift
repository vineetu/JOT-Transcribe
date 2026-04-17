import KeyboardShortcuts
import SwiftUI

struct ShortcutsPane: View {
    // The pane observes KeyboardShortcuts changes via its onShortcutChange hook
    // so the conflict banner and Recorders reflect edits as they happen.
    @State private var refreshToken: Int = 0

    private static let bindings: [(KeyboardShortcuts.Name, String)] = [
        (.toggleRecording, "Toggle recording"),
        (.pushToTalk, "Push to talk (hold)"),
        (.pasteLastTranscription, "Paste last transcription"),
        (.rewriteSelection, "Rewrite selection"),
    ]

    var body: some View {
        let _ = refreshToken
        return Form {
            Section {
                HStack(alignment: .top) {
                    Text("Global shortcuts fire from any app when Input Monitoring is granted. Press Escape to cancel an active recording — it's hardcoded and only active while Jot is mid-capture.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    InfoPopoverButton(
                        title: "Global shortcuts",
                        body: "macOS requires shortcuts to include at least one modifier key (⌘, ⌥, ⌃, or ⇧). Bare single-key bindings like F5 or A alone are not supported and the recorder will reject them.",
                        helpAnchor: "help.shortcuts.mac-limits"
                    )
                }
            }

            Section {
                ForEach(Self.bindings, id: \.0) { name, label in
                    HStack {
                        Text(label)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: name) { _ in
                            refreshToken &+= 1
                        }
                        InfoPopoverButton(
                            title: label,
                            body: popoverBody(for: name),
                            helpAnchor: "help.shortcuts.basics"
                        )
                    }
                }
            }

            if let conflict = conflictMessage() {
                Section {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults", action: resetToDefaults)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func popoverBody(for name: KeyboardShortcuts.Name) -> String {
        switch name {
        case .toggleRecording:
            return "Press to start recording; press again to stop and transcribe. The primary dictation hotkey. Fires globally from any app."
        case .pushToTalk:
            return "Hold to record; release to transcribe. Prefer this when you want precise control over the capture window."
        case .pasteLastTranscription:
            return "Paste the most recent transcript again at the cursor. Handy when you need the same text in multiple places."
        case .rewriteSelection:
            return "Select text in any app, press this shortcut, speak an instruction — Jot rewrites the selection with your configured LLM and pastes it back."
        default:
            return "A global hotkey. Requires at least one modifier key (⌘, ⌥, ⌃, or ⇧)."
        }
    }

    private func conflictMessage() -> String? {
        var seen: [KeyboardShortcuts.Shortcut: [String]] = [:]
        for (name, label) in Self.bindings {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
                seen[shortcut, default: []].append(label)
            }
        }
        let duplicates = seen.filter { $0.value.count > 1 }
        guard let first = duplicates.first else { return nil }
        return "Conflict: \(first.value.joined(separator: " and ")) share the same binding."
    }

    private func resetToDefaults() {
        KeyboardShortcuts.reset(
            .toggleRecording,
            .pushToTalk,
            .pasteLastTranscription,
            .rewriteSelection
        )
        refreshToken &+= 1
    }
}
