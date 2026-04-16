import AppKit
import Combine
import Foundation
import SwiftUI
import os.log

/// Policy layer on top of `ClipboardSandwich`. Decides *whether* to paste
/// (based on user prefs + Accessibility trust) and publishes the result as
/// a `DeliveryEvent` for the overlay / library to react to.
///
/// Preferences are backed by `@AppStorage` so the future Settings pane can
/// hand-edit the same `UserDefaults` keys without needing to go through
/// this class:
///   - jot.autoPaste (Bool, default true)
///   - jot.autoPressEnter (Bool, default false)
///   - jot.preserveClipboard (Bool, default true)
@MainActor
final class DeliveryService: ObservableObject {
    static let shared = DeliveryService()

    @AppStorage("jot.autoPaste") var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") var preserveClipboard: Bool = true

    @Published private(set) var lastDelivery: DeliveryEvent?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Delivery")
    private let permissions: PermissionsService
    private weak var recorder: RecorderController?

    // How long to wait before restoring the pre-paste pasteboard. The target
    // app needs enough time to consume ⌘V on its own main thread; empirically
    // ~350ms is safe across the delivery matrix spike.
    private static let restoreDelayMs: UInt64 = 350
    // Interval between posting ⌘V and posting Return when auto-Enter is on.
    private static let enterGapMs: UInt64 = 30

    init(permissions: PermissionsService? = nil) {
        self.permissions = permissions ?? PermissionsService.shared
    }

    /// Must be called once after `RecorderController` is constructed so
    /// `pasteLast()` has something to replay.
    func bind(recorder: RecorderController) {
        self.recorder = recorder
    }

    /// Main entry point. Called by the wire-up in AppDelegate whenever
    /// `RecorderController.lastResult` publishes a new transcript.
    func deliver(_ text: String) async {
        guard !text.isEmpty else {
            log.info("deliver called with empty text — skipping")
            return
        }

        if !autoPaste {
            writeClipboardOnly(text, reason: "auto-paste is off")
            return
        }

        permissions.refreshAll()
        if permissions.statuses[.accessibilityPostEvents] != .granted {
            writeClipboardOnly(
                text,
                reason: "grant Accessibility in System Settings to paste automatically"
            )
            return
        }

        await performSandwich(text: text)
    }

    /// Re-deliver whatever transcript the recorder last produced, if any.
    /// Bound to the `.pasteLastTranscription` shortcut.
    func pasteLast() async {
        guard let text = recorder?.lastTranscript, !text.isEmpty else {
            log.info("pasteLast: no last transcript")
            return
        }
        await deliver(text)
    }

    // MARK: - Internals

    private func performSandwich(text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSandwich.snapshot(pasteboard: pasteboard)

        guard ClipboardSandwich.writeString(text, pasteboard: pasteboard) else {
            log.error("pasteboard.setString failed")
            ClipboardSandwich.restore(snapshot, pasteboard: pasteboard)
            publish(.failed(error: "clipboard write failed"))
            return
        }

        do {
            try ClipboardSandwich.postCommandV()
            if autoPressEnter {
                try? await Task.sleep(nanoseconds: Self.enterGapMs * 1_000_000)
                try? ClipboardSandwich.postReturn()
            }
        } catch {
            log.error("CGEventPost failed: \(String(describing: error))")
            ClipboardSandwich.restore(snapshot, pasteboard: pasteboard)
            publish(.failed(error: "could not post ⌘V: \(error)"))
            return
        }

        publish(.pasted(text: text))

        // Don't block the caller on the restore — the transcript has already
        // been fired into the target app. Schedule the restore so the target
        // has time to read the pasteboard, then (optionally) roll back.
        if preserveClipboard {
            Task { @MainActor [snapshot] in
                try? await Task.sleep(nanoseconds: Self.restoreDelayMs * 1_000_000)
                ClipboardSandwich.restore(snapshot, pasteboard: pasteboard)
            }
        }
    }

    private func writeClipboardOnly(_ text: String, reason: String) {
        let pasteboard = NSPasteboard.general
        // No snapshot/restore here: in clipboard-only mode the user expects
        // the transcript to remain on the clipboard so they can ⌘V it
        // themselves. Overwriting the prior clipboard content is the
        // documented behavior of this mode.
        if ClipboardSandwich.writeString(text, pasteboard: pasteboard) {
            log.info("clipboard-only delivery: \(reason, privacy: .public)")
            publish(.clipboardOnly(text: text, reason: reason))
        } else {
            log.error("pasteboard.setString failed in clipboard-only path")
            publish(.failed(error: "clipboard write failed"))
        }
    }

    private func publish(_ event: DeliveryEvent) {
        lastDelivery = event
    }
}
