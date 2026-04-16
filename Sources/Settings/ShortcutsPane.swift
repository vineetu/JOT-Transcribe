import KeyboardShortcuts
import SwiftUI

struct ShortcutsPane: View {
    // The pane observes KeyboardShortcuts changes via its onShortcutChange hook
    // so the conflict banner and Recorders reflect edits as they happen.
    @State private var refreshToken: Int = 0

    private static let bindings: [(KeyboardShortcuts.Name, String)] = [
        (.toggleRecording, "Toggle recording"),
        (.cancelRecording, "Cancel recording"),
        (.pushToTalk, "Push to talk (hold)"),
        (.pasteLastTranscription, "Paste last transcription"),
        (.rewriteSelection, "Rewrite selection"),
    ]

    var body: some View {
        let _ = refreshToken
        return Form {
            Section {
                Text("Global shortcuts fire from any app when Input Monitoring is granted. Cancel only fires while a recording is in progress.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(Self.bindings, id: \.0) { name, label in
                    HStack {
                        Text(label)
                        Spacer()
                        KeyboardShortcuts.Recorder(for: name) { _ in
                            refreshToken &+= 1
                        }
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
            .cancelRecording,
            .pushToTalk,
            .pasteLastTranscription,
            .rewriteSelection
        )
        refreshToken &+= 1
    }
}
