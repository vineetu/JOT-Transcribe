import SwiftUI
import AppKit

@main
struct DeliveryMatrixApp: App {
    @StateObject private var model = SpikeModel()

    var body: some Scene {
        WindowGroup("Delivery Matrix Spike") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class SpikeModel: ObservableObject {
    @Published var sampleText: String = "The quick brown fox jumps over the lazy dog. 0123456789."
    @Published var log: [String] = []
    @Published var countdown: Int = 0
    @Published var autoEnter: Bool = false

    func append(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        log.insert("[\(ts)] \(line)", at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }

    func startPaste() {
        guard countdown == 0 else { return }
        countdown = 3
        append("Countdown started — switch focus to target app now.")
        Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdown -= 1
            }
            let text = sampleText
            let autoEnter = self.autoEnter
            let result = Paster.paste(text: text, pressEnter: autoEnter)
            append(result)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: SpikeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delivery Matrix Spike (S1)")
                .font(.title2).bold()
            Text("Paste synthetic ⌘V via CGEventPost. Focus a target app during the countdown.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("Sample text") {
                TextEditor(text: $model.sampleText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 60)
            }

            HStack(spacing: 12) {
                Button(action: { model.startPaste() }) {
                    if model.countdown > 0 {
                        Text("Pasting in \(model.countdown)…")
                    } else {
                        Text("Paste to frontmost app in 3 s")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.countdown > 0)

                Toggle("Also press Return", isOn: $model.autoEnter)
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
                .frame(minHeight: 180)
            }
        }
        .padding(20)
    }
}
