import ApplicationServices
import AppKit
import Combine
import CoreGraphics
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
    /// Read for `pasteLast()` so the hotkey replays the most recent
    /// Jot output regardless of whether it was a dictation or a
    /// rewrite. Optional so the test harness can construct a
    /// DeliveryService without a rewrite controller and still drive
    /// the dictation paste-last path.
    private weak var rewriteController: RewriteController?

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
    // Bound on how long we wait for a reactivated Origin app to actually
    // become frontmost before posting ⌘V anyway (design §5.2/§7 R2) — the
    // paste must never be dropped waiting on another app.
    private static let originActivationTimeoutMs: UInt64 = 600
    // Small settle delay after Origin activation resolves (notification or
    // timeout), so the target window is genuinely key-ready and not merely
    // "activated" per the notification (design §7 R2).
    private static let originActivationSettleMs: UInt64 = 50

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

    /// Optional companion to `bind(recorder:)` — wires the rewrite
    /// controller so `pasteLast()` can replay the most recent rewrite
    /// when it's newer than the most recent dictation. Called from
    /// composition after both controllers exist.
    func bind(rewriteController: RewriteController) {
        self.rewriteController = rewriteController
    }

    /// Main entry point. Called by the wire-up in AppDelegate whenever
    /// `RecorderController.lastResult` publishes a new transcript.
    ///
    /// `originApp` is "Return to the app I started in" support
    /// (`jot.returnToOriginApp`, docs/return-to-origin-app/design.md):
    /// the app that was frontmost when the dictation that produced
    /// `text` STARTED, threaded here as a parameter from that specific
    /// transcript (never re-read from shared/mutable state — see
    /// `RecorderController.lastResultOriginApp`). Defaults to `nil`,
    /// which reproduces today's behavior exactly — including for
    /// `pasteLast()`, which deliberately never reactivates an origin.
    func deliver(_ text: String, originApp: NSRunningApplication? = nil) async {
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

        await performSandwich(text: text, originApp: originApp)
    }

    /// Re-deliver the most recent Jot output, whether that was a
    /// dictation transcript or a Rewrite result. Picks whichever
    /// source has the newer `*At` timestamp; if only one source has
    /// produced output this run, that one wins. Bound to the
    /// `.pasteLastTranscription` shortcut (renamed in Settings →
    /// Shortcuts to "Paste last result"; the storage key is kept
    /// stable so existing user bindings don't reset).
    func pasteLast() async {
        let transcript = recorder?.lastTranscript ?? ""
        let transcriptAt = recorder?.lastTranscriptAt
        let rewrite = rewriteController?.lastRewrite ?? ""
        let rewriteAt = rewriteController?.lastRewriteAt

        let candidate: String?
        switch (transcriptAt, rewriteAt) {
        case (nil, nil):
            candidate = nil
        case (.some, nil):
            candidate = transcript.isEmpty ? nil : transcript
        case (nil, .some):
            candidate = rewrite.isEmpty ? nil : rewrite
        case let (.some(tAt), .some(rAt)):
            // Newest wins. Tie-break to rewrite — if a user just
            // rewrote a transcript, that's what they'd want pasted,
            // and tied timestamps only happen in a corner case.
            candidate = rAt >= tAt
                ? (rewrite.isEmpty ? nil : rewrite)
                : (transcript.isEmpty ? nil : transcript)
        }

        guard let text = candidate else {
            log.info("pasteLast: no prior output to replay")
            return
        }
        await deliver(text)
    }

    // MARK: - Internals

    private func performSandwich(text: String, originApp: NSRunningApplication?) async {
        let snapshot = pasteboard.snapshot()

        guard pasteboard.write(text) else {
            log.error("pasteboard.setString failed")
            Task { await self.logSink.error(component: "Delivery", message: "Clipboard write failed") }
            pasteboard.restore(snapshot)
            publish(.failed(error: "clipboard write failed"))
            return
        }

        // Return-to-origin (design §5.2): reactivate Origin BEFORE posting
        // ⌘V so the un-targeted synthetic paste lands there instead of
        // wherever Current happens to be. Hard-guarded: Origin must still
        // be running, must actually differ from Current (else this is a
        // no-op — the user never switched), and must be on THIS Space —
        // we never yank the user across Spaces/full-screen to deliver
        // text (design §7 R3).
        if let origin = originApp,
           !origin.isTerminated,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != origin.processIdentifier,
           isOnCurrentSpace(origin) {
            raiseFrontmost(origin)
            await awaitActivation(origin, timeoutMs: Self.originActivationTimeoutMs)
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

    // MARK: - Return to origin app

    /// Bring `app` frontmost. AX is the primary route — Jot is
    /// non-sandboxed and AX-trusted (required for the existing synthetic
    /// ⌘V/⌘C paths anyway), and `AXUIElementSetAttributeValue` on
    /// `kAXFrontmostAttribute` is the deterministic way for a background
    /// app to raise a THIRD app on modern macOS, where
    /// `NSRunningApplication.activate(options:)` alone is best-effort
    /// (design §7 R1/§8). Falls back to `activate(options: [])` if the
    /// AX call doesn't report success.
    private func raiseFrontmost(_ app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // `AXUIElementSetAttributeValue` is a SYNCHRONOUS cross-process AX
        // message; against a hung/unresponsive origin it would block this
        // (MainActor) call up to the AX default (~6s), violating the design's
        // "never block delivery" invariant (§7 R2 only bounds awaitActivation).
        // Cap the AX messaging timeout so a wedged target degrades to the
        // best-effort activate() fallback fast instead of freezing the app.
        AXUIElementSetMessagingTimeout(axApp, 0.4)
        let result = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if result != .success {
            app.activate(options: [])
        }
    }

    /// Hard guard (design §7 R3): never reactivate — and never yank the
    /// user to — an Origin app that isn't on the CURRENT Space (includes
    /// full-screen apps, which run in their own Space).
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly, ...)` only
    /// enumerates windows visible on the active Space, so `app` owning
    /// any window in that list is a reliable same-Space signal without
    /// requiring Screen Recording permission (we only read owner PIDs,
    /// not window names/content).
    private func isOnCurrentSpace(_ app: NSRunningApplication) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let pid = app.processIdentifier
        let ownerPIDKey = kCGWindowOwnerPID as String
        return windowList.contains { info in
            (info[ownerPIDKey] as? pid_t) == pid
        }
    }

    /// Wait (bounded) for `app` to actually become frontmost after
    /// `raiseFrontmost`, via `didActivateApplicationNotification` — the
    /// same notification `PermissionsService` already subscribes to
    /// (`PermissionsService.swift:48`) — rather than a
    /// `frontmostApplication` busy-poll, which can flip before the
    /// target window is genuinely key-ready (design §7 R2). On timeout
    /// we proceed anyway: the paste must never be dropped waiting on
    /// another app.
    private func awaitActivation(_ app: NSRunningApplication, timeoutMs: UInt64) async {
        let pid = app.processIdentifier
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            var observer: NSObjectProtocol?
            let finish = {
                guard !didResume else { return }
                didResume = true
                if let observer {
                    NSWorkspace.shared.notificationCenter.removeObserver(observer)
                }
                continuation.resume()
            }
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { note in
                guard let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      activated.processIdentifier == pid else { return }
                finish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(timeoutMs))) {
                finish()
            }
        }
        // Settle delay so the target window is genuinely key-ready, not
        // just "activated" per the notification.
        try? await Task.sleep(nanoseconds: Self.originActivationSettleMs * 1_000_000)
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
