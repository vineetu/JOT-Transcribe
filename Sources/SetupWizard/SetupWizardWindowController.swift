import AppKit
import SwiftUI

/// Fixed-size, titled window that hosts `SetupWizardView`. Lives outside the
/// main `WindowGroup` scene so it can float over the primary window without
/// interfering with its lifecycle, and so `WizardPresenter` can present it on
/// demand from both first-run and Settings → General.
@MainActor
final class SetupWizardWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: SetupWizardCoordinator
    private let onClose: () -> Void

    init(coordinator: SetupWizardCoordinator, onClose: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onClose = onClose

        let contentSize = NSSize(width: 560, height: 440)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        window.center()
        window.setFrameAutosaveName("")

        let rootView = SetupWizardView()
            .environmentObject(coordinator)
        window.contentView = NSHostingView(rootView: rootView)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
