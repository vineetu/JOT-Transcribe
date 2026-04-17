import AppKit
import Carbon.HIToolbox
import Foundation
import os.log

/// Hardcoded plain-Escape cancel hotkey.
///
/// `sindresorhus/KeyboardShortcuts` ultimately calls Carbon's
/// `RegisterEventHotKey` — which accepts modifierless registrations but
/// does not reliably deliver plain Escape from other apps, because macOS
/// reserves Escape for responder-chain / cancel semantics. Ctrl+Esc works
/// because the modifier pulls the combo out of that reserved lane. To give
/// the user a truly always-on plain-Escape cancel we have to bypass the
/// Carbon hot-key path entirely.
///
/// Arm/disarm is dynamic: the monitor is installed only while the caller
/// (HotkeyRouter) reports that a cancellable pipeline is active. When Jot
/// is idle the monitor is torn down so Escape flows to whatever app is
/// focused. `addGlobalMonitorForEvents` fundamentally cannot consume events
/// — which is exactly what we want: we listen, trigger our cancel, and
/// never steal the key.
@MainActor
final class EscapeMonitor {
    private let log = Logger(subsystem: "com.jot.Jot", category: "EscapeMonitor")
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onCancel: () -> Void

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    /// Install the monitors. Idempotent — calling twice is a no-op.
    func arm() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            guard Self.isPlainEscape(event) else { return }
            Task { @MainActor in
                self.log.info("plain Escape fired (global)")
                self.onCancel()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard Self.isPlainEscape(event) else { return event }
            self.log.info("plain Escape fired (local)")
            self.onCancel()
            // Swallow inside Jot's own windows so Escape doesn't also
            // close a popover / sheet while cancelling the pipeline.
            return nil
        }
    }

    /// Tear down both monitors. Idempotent.
    func disarm() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private static func isPlainEscape(_ event: NSEvent) -> Bool {
        guard Int(event.keyCode) == kVK_Escape else { return false }
        let disqualifying: NSEvent.ModifierFlags = [.command, .option, .shift, .control, .function]
        return event.modifierFlags.intersection(disqualifying).isEmpty
    }
}
