import AppKit
import Foundation

/// Single entry point for showing the setup wizard. Both the first-run gate
/// in `AppDelegate` and the "Run Setup Wizard…" button in General settings
/// call through here so only one window can ever be open, and so the starting
/// step + presentation side effects (activation, center, finish handling)
/// live in one place.
///
/// `.firstRun` starts from Welcome and marks setup complete on finish.
/// `.manualFromSettings` also starts from Welcome — all step views read the
/// same `@AppStorage` keys as Settings, so there is no separate "preload"
/// phase to run. Finishing the manual wizard still marks setup complete (a
/// no-op if it already is).
@MainActor
enum WizardPresenter {
    enum PresentReason {
        case firstRun
        case manualFromSettings
    }

    private static var controller: SetupWizardWindowController?

    static func present(reason: PresentReason) {
        if let controller {
            // Already open — just bring it forward.
            controller.present()
            return
        }

        let coordinator = SetupWizardCoordinator(
            startingAt: .welcome,
            onFinish: { closeWindow() }
        )
        let wc = SetupWizardWindowController(
            coordinator: coordinator,
            onClose: { controller = nil }
        )
        self.controller = wc
        wc.present()
    }

    static func isPresented() -> Bool {
        controller != nil
    }

    private static func closeWindow() {
        controller?.close()
        controller = nil
    }
}
