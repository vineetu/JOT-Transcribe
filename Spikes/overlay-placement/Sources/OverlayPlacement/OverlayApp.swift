import AppKit

@main
enum OverlayApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no dock icon; overlay-only
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = OverlayController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.show()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSLog("[OverlayPlacement] launched; %d screen(s) detected", NSScreen.screens.count)
    }

    @objc private func screensChanged(_ note: Notification) {
        NSLog("[OverlayPlacement] didChangeScreenParameters — re-placing overlay")
        controller.replace()
    }
}
