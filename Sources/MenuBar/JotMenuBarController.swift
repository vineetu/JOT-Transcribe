import AppKit
import Combine
import Foundation
import os.log

/// Owns the `NSStatusItem` (menu-bar extra) and its `NSMenu`. The icon and
/// "Toggle Recording" label are driven by Combine subscriptions to
/// `RecorderController.$state` and `$lastTranscript`.
///
/// This controller is deliberately side-effect free in `init` — creating the
/// `NSStatusItem` happens in `install()` so `AppDelegate` can choose when to
/// actually plant something in the menu bar.
@MainActor
final class JotMenuBarController: NSObject {
    // MARK: - Dependencies

    private let recorder: RecorderController
    private let delivery: DeliveryService

    // MARK: - UI

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    private var toggleItem: NSMenuItem?
    private var copyLastItem: NSMenuItem?

    // MARK: - Subscriptions

    private var stateCancellable: AnyCancellable?
    private var transcriptCancellable: AnyCancellable?

    private let log = Logger(subsystem: "com.jot.Jot", category: "MenuBar")

    // MARK: - Init

    init(recorder: RecorderController, delivery: DeliveryService) {
        self.recorder = recorder
        self.delivery = delivery
        super.init()
    }

    /// Installs the status item in the system menu bar and wires up Combine
    /// subscriptions. Safe to call exactly once, from
    /// `applicationDidFinishLaunching`.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon(for: recorder.state)
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item

        stateCancellable = recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyState(state)
            }

        transcriptCancellable = recorder.$lastTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.copyLastItem?.isEnabled = (transcript?.isEmpty == false)
            }
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        menu.autoenablesItems = false

        let toggle = NSMenuItem(
            title: Self.toggleTitle(for: recorder.state),
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = Self.toggleEnabled(for: recorder.state)
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        let copyLast = NSMenuItem(
            title: "Copy Last Transcription",
            action: #selector(copyLastTranscription),
            keyEquivalent: ""
        )
        copyLast.target = self
        copyLast.isEnabled = (recorder.lastTranscript?.isEmpty == false)
        menu.addItem(copyLast)
        copyLastItem = copyLast

        let showWindow = NSMenuItem(
            title: "Show Window",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        showWindow.target = self
        menu.addItem(showWindow)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(
            title: "Quit Jot",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - State reflection

    private func applyState(_ state: RecorderController.State) {
        toggleItem?.title = Self.toggleTitle(for: state)
        toggleItem?.isEnabled = Self.toggleEnabled(for: state)

        if let image = Self.icon(for: state) {
            image.isTemplate = true
            statusItem?.button?.image = image
        }
    }

    private static func toggleTitle(for state: RecorderController.State) -> String {
        switch state {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing…"
        case .error: return "Retry"
        }
    }

    private static func toggleEnabled(for state: RecorderController.State) -> Bool {
        switch state {
        case .transcribing: return false
        case .idle, .recording, .error: return true
        }
    }

    private static func icon(for state: RecorderController.State) -> NSImage? {
        let symbolName: String
        switch state {
        case .idle: symbolName = "mic.fill"
        case .recording: symbolName = "mic.and.signal.meter.fill"
        case .transcribing: symbolName = "waveform"
        case .error: symbolName = "exclamationmark.triangle.fill"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription(for: state)
        )
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return image?.withSymbolConfiguration(config)
    }

    private static func accessibilityDescription(for state: RecorderController.State) -> String {
        switch state {
        case .idle: return "Jot: idle"
        case .recording: return "Jot: recording"
        case .transcribing: return "Jot: transcribing"
        case .error: return "Jot: error"
        }
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        Task { @MainActor in
            await recorder.toggle()
        }
    }

    @objc private func copyLastTranscription() {
        guard let text = recorder.lastTranscript, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })
            ?? NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        // macOS 14 (Sonoma) renamed the AppKit responder-chain selector from
        // `showPreferencesWindow:` to `showSettingsWindow:` to match the
        // SwiftUI `Settings` scene. We are macOS 14+ only (see CLAUDE.md), so
        // the new selector is the only one we need to support.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
