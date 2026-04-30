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
//
// Why the work happens on a deferred runloop turn (Reset-regression fix):
// Most callers fire from a SwiftUI Alert action closure (Settings → Reset
// settings, Erase all data, Restart; SetupWizard → Reset permissions). Apple
// documents that "All actions in an alert dismiss the alert AFTER the action
// runs" — so when the closure invokes us, the alert's modal session is still
// the topmost AppKit modal session. AppKit rejects `NSApp.terminate(nil)` in
// that state with an NSBeep, no termination, and an orphaned relauncher `sh`
// polling for a PID exit that never comes. Scheduling on `RunLoop.main` in
// `.default` mode (NOT `.modalPanel`) means our `performRelaunch` only runs
// once the runloop has dropped out of the modal panel mode the alert pushed
// — by which point the modal session has been popped and `terminate(nil)`
// is accepted.
//
// `isRelaunching` coalesces accidental duplicate requests in the same alert
// dismissal turn. We clear it whenever control returns to us — both on
// `Process.run` failure and after `NSApp.terminate(nil)` returns without
// actually terminating (rare; means AppKit rejected the request) — so the
// user can retry from another surface instead of being silently locked out.
// In the normal `.terminateNow` path, `terminate` never returns and the
// flag state is moot.
@MainActor
enum RestartHelper {
    private static var isRelaunching = false

    static func relaunch() {
        guard !isRelaunching else { return }
        isRelaunching = true
        // `.default` mode skips runloop turns spent inside the alert's
        // `.modalPanel` mode, so this fires only after the modal session
        // has been torn down — not just on the next main-queue tick.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { performRelaunch() }
        }
    }

    private static func performRelaunch() {
        let bundlePath = Bundle.main.bundlePath
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let script = "while kill -0 \(ownPID) 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \"$0\""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, bundlePath]

        do {
            try task.run()
        } catch {
            isRelaunching = false
            NSLog("RestartHelper: failed to spawn relauncher shell: \(error)")
            return
        }

        NSApp.terminate(nil)
        // Reaches here only if AppKit rejected termination (no
        // `applicationShouldTerminate` is registered, so the default reply
        // is `.terminateNow` and `terminate` would not return). Clearing the
        // guard lets the user retry; the orphan helper shell from the prior
        // attempt is the unavoidable cost.
        isRelaunching = false
    }
}
