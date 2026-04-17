import AppKit
import Foundation

// RestartHelper — relaunch Jot in-place after a permission grant.
//
// Why: Input Monitoring and Accessibility decisions are cached per-process by
// the kernel. A user granting these capabilities in System Settings while Jot
// is running will NOT cause the running process to observe the new status —
// the app must be quit and a *new* binary launch must occur.
//
// Why we don't just `open -n` and terminate: Jot has a `SingleInstance` check
// in `applicationDidFinishLaunching` that pings any peer instance via
// `DistributedNotificationCenter`. If we launch the replacement *before* we
// terminate, the replacement pings us, we pong, the replacement thinks it's a
// duplicate, and kills itself. Then we terminate too and nothing is running.
//
// Fix: spawn a detached `/bin/sh` child that waits for OUR PID to exit, then
// runs `open -n`. `-n` forces a fresh instance; we omit `-W` because we don't
// need `open` to hang around. The sh process is reparented to launchd when we
// exit, so it survives our termination and launches the replacement cleanly
// with no live peer to confuse the single-instance check.
//
// We do NOT use `NSWorkspace.shared.open(URL(fileURLWithPath: bundlePath))`:
// that call won't reliably start a *second* instance while the first is still
// alive — LaunchServices prefers to activate the running app instead.
enum RestartHelper {
    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let script = "while kill -0 \(ownPID) 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$0\""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, bundlePath]

        do {
            try task.run()
        } catch {
            NSLog("RestartHelper: failed to spawn relauncher shell: \(error)")
            return
        }

        NSApp.terminate(nil)
    }
}
