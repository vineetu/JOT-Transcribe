// caps-lock-probe.swift
//
// Tiny prototype for testing the proposed Caps Lock recording hotkey.
//
// Build + sign:
//   swiftc -O tools/caps-lock-probe.swift -o tools/caps-lock-probe
//   codesign --force \
//       --sign "Developer ID Application: Vineet Sriram (8VB2ULDN22)" \
//       --options runtime tools/caps-lock-probe
//
// Run:
//   ./tools/caps-lock-probe
//
// First run will fail silently because macOS needs Accessibility
// permission for `NSEvent.addGlobalMonitorForEvents`. Grant it:
//   System Settings → Privacy & Security → Accessibility →
//   click the + button, navigate to this binary, add it, toggle on.
// Then re-run.
//
// Behavior under test:
//   • Caps Lock ON  → "START RECORDING" log line
//   • Caps Lock OFF → "STOP RECORDING" log line
//   • Both global (system-wide) and local (this terminal's window)
//     monitors are installed so we can compare whether they both
//     fire and whether timing differs.
//   • The macOS ~100ms anti-fat-finger delay still applies — taps
//     faster than that may not register. Try slow taps first; then
//     rapid taps to confirm the floor.
//   • Ctrl+C exits.

import AppKit
import Foundation

let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

var recording = false

// Pre-load the chime sounds once. NSSound(named:) on macOS resolves
// against /System/Library/Sounds/ — these are guaranteed to exist.
// Keep retained references so play() doesn't race garbage collection.
let startChime = NSSound(named: NSSound.Name("Glass"))
let stopChime = NSSound(named: NSSound.Name("Pop"))

func log(_ s: String) {
    print("[\(formatter.string(from: Date()))] \(s)")
    fflush(stdout)
}

func handle(_ event: NSEvent, source: String) {
    guard event.keyCode == 0x39 else { return } // kVK_CapsLock
    let isOn = event.modifierFlags.contains(.capsLock)
    if isOn {
        if !recording {
            recording = true
            startChime?.stop()  // rewind if it's still playing from a fast re-press
            startChime?.play()
            log("[\(source)] Caps Lock ON  →  ▶ START RECORDING 🔊")
        } else {
            log("[\(source)] Caps Lock ON  →  (already recording, ignored)")
        }
    } else {
        if recording {
            recording = false
            stopChime?.stop()
            stopChime?.play()
            log("[\(source)] Caps Lock OFF →  ■ STOP RECORDING 🔊")
        } else {
            log("[\(source)] Caps Lock OFF →  (not recording, ignored)")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon, no menu bar

// Check Accessibility up front so we fail loudly instead of silently.
let trusted = AXIsProcessTrusted()
log("Accessibility granted: \(trusted ? "✓ YES" : "✗ NO — global monitor won't fire")")
if !trusted {
    log("To grant: System Settings → Privacy & Security → Accessibility → + → select this binary.")
    log("Then re-run.")
}

log("Initial Caps Lock state: \(NSEvent.modifierFlags.contains(.capsLock) ? "ON" : "OFF")")
log("Probe is live. Tap Caps Lock to test. Ctrl+C to exit.")
print("---")
fflush(stdout)

// Global monitor: fires for events targeting OTHER apps (the real use
// case). Requires Accessibility.
_ = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    handle(event, source: "global")
}

// Local monitor: fires for events targeting THIS app's windows. Doesn't
// require permission. We have no UI window here, but the monitor is
// cheap to install and confirms the API path works regardless of
// permission state.
_ = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
    handle(event, source: "local")
    return event
}

// Handle Ctrl+C cleanly.
signal(SIGINT) { _ in
    print("\n--- Probe stopped. ---")
    exit(0)
}

app.run()
