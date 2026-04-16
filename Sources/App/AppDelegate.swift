import AppKit
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.jot.Jot", category: "AppDelegate")
    private let singleInstance = SingleInstance()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Jot launched")

        if singleInstance.anotherInstanceIsRunning() {
            singleInstance.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        singleInstance.installObserver {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        _ = FirstRunState.shared
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
