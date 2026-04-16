import AppKit
import Foundation

// RestartHelper — relaunch Jot in-place after a permission grant.
//
// Why: Input Monitoring and Accessibility decisions are cached per-process by
// the kernel. A user granting these capabilities in System Settings while Jot
// is running will NOT cause the running process to observe the new status —
// the app must be quit and a *new* binary launch must occur. This helper
// spawns `/usr/bin/open -n -W <bundle>` as a detached child: `-n` forces a
// fresh instance, `-W` makes `open` wait for the app to finish (which it
// won't until we terminate). We then terminate the current process after a
// short delay so `open` sees our exit and launches the replacement.
//
// We do NOT use `NSWorkspace.shared.open(URL(fileURLWithPath: bundlePath))`:
// that call won't reliably start a *second* instance while the first is still
// alive — LaunchServices prefers to activate the running app instead.
enum RestartHelper {
    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", "-W", bundlePath]

        do {
            try task.run()
        } catch {
            NSLog("RestartHelper: failed to spawn /usr/bin/open -n -W: \(error)")
            return
        }

        // Give the child a beat to latch onto our PID before we exit, so it
        // sees the process go away and then launches the replacement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}
