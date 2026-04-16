import SwiftUI
import KeyboardShortcuts

@main
struct HotkeyToggleApp: App {
    @StateObject private var model = SpikeModel()

    var body: some Scene {
        WindowGroup("Hotkey Toggle Spike") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 420)
                .onAppear { model.install() }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class SpikeModel: ObservableObject {
    @Published var toggleRecordingEnabled: Bool = true {
        didSet { applyEnablement(for: .toggleRecording, enabled: toggleRecordingEnabled) }
    }
    @Published var cancelEnabled: Bool = false {
        didSet { applyEnablement(for: .cancelRecording, enabled: cancelEnabled) }
    }
    @Published var log: [String] = []

    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            self?.append("FIRED: toggleRecording (⌥Space)")
        }
        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak self] in
            self?.append("FIRED: cancelRecording (Esc)")
        }
        // Match initial toggle state.
        applyEnablement(for: .toggleRecording, enabled: toggleRecordingEnabled)
        applyEnablement(for: .cancelRecording, enabled: cancelEnabled)
        append("Installed shortcut handlers. Initial: toggleRecording=\(toggleRecordingEnabled), cancel=\(cancelEnabled)")
    }

    private func applyEnablement(for name: KeyboardShortcuts.Name, enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(name)
            append("ENABLE \(name.rawValue)")
        } else {
            KeyboardShortcuts.disable(name)
            append("DISABLE \(name.rawValue)")
        }
    }

    func append(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        log.insert("[\(ts)] \(line)", at: 0)
        if log.count > 500 { log.removeLast(log.count - 500) }
    }

    func clearLog() { log.removeAll() }
}

struct ContentView: View {
    @ObservedObject var model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotkey Toggle Spike (S2)")
                .font(.title2).bold()
            Text("Verify that KeyboardShortcuts.enable/.disable actually releases the OS-level registration — specifically that Esc returns to other apps when disabled.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("Shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable Toggle Recording (⌥Space)", isOn: $model.toggleRecordingEnabled)
                    Toggle("Enable Cancel Recording (Esc)", isOn: $model.cancelEnabled)
                }
                .padding(8)
            }

            HStack {
                Button("Clear log") { model.clearLog() }
                Spacer()
                Text("Log lines: \(model.log.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            GroupBox("Log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 200)
            }
        }
        .padding(20)
    }
}
