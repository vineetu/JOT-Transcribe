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

    @AppStorage("jot.autoPaste") var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") var preserveClipboard: Bool = true

    @Published private(set) var lastDelivery: DeliveryEvent?

    private let log = Logger(subsystem: "com.jot.Jot", category: "Delivery")
    private let permissions: any PermissionsObserving
    private weak var recorder: RecorderController?

    /// Pasteboarding seam, injected at init. Phase 3 #30: prior to
    /// this refactor `DeliveryService` was a process-wide singleton
    /// with `bind(pasteboard:)` / `bind(logSink:)` late-injection
    /// setters. Two parallel test harnesses racing on those setters
    /// caused the cross-suite flake captured in Task #32. Now each
    /// `JotComposition.build` constructs its own `DeliveryService`
    /// with seams threaded in at init — production and test graphs
    /// can't collide on shared mutable state.
    private let pasteboard: any Pasteboarding

    /// LogSink seam, injected at init. See `pasteboard` doc for the
    /// rationale.
    private let logSink: any LogSink

    // How long to wait before restoring the pre-paste pasteboard. The target
    // app needs enough time to consume ⌘V on its own main thread; empirically
    // ~350ms is safe across the delivery matrix spike.
    private static let restoreDelayMs: UInt64 = 350
    // Interval between posting ⌘V and posting Return when auto-Enter is on.
    private static let enterGapMs: UInt64 = 30

    init(
        pasteboard: any Pasteboarding,
        logSink: any LogSink,
        permissions: (any PermissionsObserving)? = nil
    ) {
        self.pasteboard = pasteboard
        self.logSink = logSink
        self.permissions = permissions ?? PermissionsService.shared
    }

    /// Must be called once after `RecorderController` is constructed so
    /// `pasteLast()` has something to replay. Recorder is constructed
    /// after `DeliveryService` in `JotComposition.build` (so it can
    /// take the delivery as a constructor arg), so this remains a
    /// post-init binder.
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
        let snapshot = pasteboard.snapshot()

        guard pasteboard.write(text) else {
            log.error("pasteboard.setString failed")
            Task { await self.logSink.error(component: "Delivery", message: "Clipboard write failed") }
            pasteboard.restore(snapshot)
            publish(.failed(error: "clipboard write failed"))
            return
        }

        do {
            try pasteboard.postCommandV()
            if autoPressEnter {
                try? await Task.sleep(nanoseconds: Self.enterGapMs * 1_000_000)
                try? pasteboard.postReturn()
            }
        } catch {
            log.error("CGEventPost failed: \(String(describing: error))")
            Task { await self.logSink.error(component: "Delivery", message: "Synthetic paste (⌘V) failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            pasteboard.restore(snapshot)
            publish(.failed(error: "could not post ⌘V: \(error)"))
            return
        }

        publish(.pasted(text: text))

        // Don't block the caller on the restore — the transcript has already
        // been fired into the target app. Schedule the restore so the target
        // has time to read the pasteboard, then (optionally) roll back.
        if preserveClipboard {
            let pasteboard = self.pasteboard
            Task { @MainActor [snapshot, pasteboard] in
                try? await Task.sleep(nanoseconds: Self.restoreDelayMs * 1_000_000)
                pasteboard.restore(snapshot)
            }
        }
    }

    private func writeClipboardOnly(_ text: String, reason: String) {
        // No snapshot/restore here: in clipboard-only mode the user expects
        // the transcript to remain on the clipboard so they can ⌘V it
        // themselves. Overwriting the prior clipboard content is the
        // documented behavior of this mode.
        if pasteboard.write(text) {
            log.info("clipboard-only delivery: \(reason, privacy: .public)")
            publish(.clipboardOnly(text: text, reason: reason))
        } else {
            log.error("pasteboard.setString failed in clipboard-only path")
            Task { await self.logSink.error(component: "Delivery", message: "Clipboard-only write failed", context: ["reason": String(reason.prefix(80))]) }
            publish(.failed(error: "clipboard write failed"))
        }
    }

    private func publish(_ event: DeliveryEvent) {
        lastDelivery = event
    }
}
