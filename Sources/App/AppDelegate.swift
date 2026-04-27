import AppKit
import Combine
import SwiftData
import os.log

/// `.regular` activation policy (set in `applicationDidFinishLaunching`)
/// gives Jot a Dock icon and ⌘Tab entry; `closeInterceptor` below hides
/// the window on ⌘W so hotkeys and the menu-bar extra keep working until
/// ⌘Q. Previously `.accessory` with `LSUIElement = true`, which hid the
/// app from every AppKit surface — unfriendly when the app ever wedged,
/// since users couldn't Force Quit it through normal channels.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.jot.Jot", category: "AppDelegate")
    private let singleInstance = SingleInstance()

    /// Resolved object graph. Constructed inside
    /// `applicationDidFinishLaunching` after the dup-instance check, so a
    /// duplicate launch terminates without spinning up audio actors,
    /// SwiftData containers, or the Sparkle updater. SwiftUI scenes that
    /// previously read `delegate.pipeline` etc. now read
    /// `delegate.services.pipeline` etc.; the IUO is safe because scene
    /// bodies don't evaluate until after `applicationDidFinishLaunching`
    /// returns. ORDERING INVARIANT (prior pre-Phase-0 line 14): the graph
    /// must exist before the first `WindowGroup` body runs — assigning
    /// `services` at the start of `applicationDidFinishLaunching`
    /// satisfies that.
    private(set) var services: AppServices!

    /// Bridge between RecorderController's `$lastResult` and
    /// DeliveryService.deliver(...). Held strongly so the sink outlives
    /// `wireUp(_:)`'s local scope.
    /// **Must never be nilled after initial assignment** — releasing the
    /// cancellable would silently break dictation delivery for the rest
    /// of the session.
    private var deliveryBridge: AnyCancellable?

    /// Strong reference to the proxy delegate installed on the unified
    /// main window so the red close button (and ⌘W) hide it instead of
    /// tearing the SwiftUI scene down. Even as a `.regular` app we want
    /// close-means-hide semantics so closing the window leaves the
    /// menu-bar extra and hotkeys alive — ⌘Q is the only way to quit.
    /// **Must never be nilled after initial assignment** — releasing the
    /// interceptor would let the unified window tear down on close,
    /// which kills the menu-bar route back to the app.
    private var closeInterceptor: MainWindowCloseInterceptor?

    /// Token for the `NSWindow.didBecomeKeyNotification` subscription
    /// that drives install of `closeInterceptor`. Observing globally
    /// (rather than installing at the first menu-bar "Open Jot…" click)
    /// guarantees the hook is active from the very first window
    /// appearance — including launch auto-open and `openWindow` API
    /// paths that bypass the menu-bar controller.
    /// **Must never be nilled after initial assignment** — `AppDelegate.deinit`
    /// removes the observer; nil'ing this field mid-session would silently
    /// break the close-interceptor install path for any window that opens
    /// after the nil.
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        log.info("Jot launched")

        #if DEBUG
        HelpInfraTests.runAll()
        ChatbotVoiceInputTests.runAll()
        #endif

        ResetActions.processPendingHardReset()

        if singleInstance.anotherInstanceIsRunning() {
            singleInstance.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        preConstructionSetup()

        do {
            self.services = try JotComposition.build(systemServices: .live)
        } catch {
            fatalError("JotComposition.build failed: \(error)")
        }

        wireUp(services)
        presentSetupWizardIfNeeded(services)
        prewarmTranscriber(services)
    }

    private func preConstructionSetup() {
        singleInstance.installObserver {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        _ = FirstRunState.shared
        PermissionsService.shared.refreshAll()
        // Bug: custom input device pinning records from the wrong device.
        // Force system default until fixed so previously-set UIDs don't
        // affect the recording path.
        UserDefaults.standard.set("", forKey: "jot.inputDeviceUID")
    }

    /// Pre-warm Parakeet out-of-band so the user's first recording
    /// doesn't pay the 4–6 s ANE specialization latency synchronously,
    /// and so the iOS 26.4-class MLModel load hang (Apple dev forum
    /// 770529) can't park a mid-session recorder in `.transcribing`.
    /// Best-effort: if the model isn't downloaded yet, or pre-warm fails,
    /// the recorder will surface a fast "model still loading" error on
    /// first press rather than silently hanging.
    private func prewarmTranscriber(_ services: AppServices) {
        Task.detached(priority: .utility) { [pipeline = services.pipeline] in
            try? await pipeline.ensureTranscriberLoaded()
        }
    }

    private func wireUp(_ services: AppServices) {
        // Phase 3 wire-up: recorder → delivery → hotkeys. The graph is
        // already constructed; this binds the runtime channel between
        // them.
        services.delivery.bind(recorder: services.recorder)
        services.hotkeyRouter.activate()

        // Deliver the final transcript (transformed if Transform is on,
        // raw otherwise). We observe `$lastResult` as the trigger because
        // it fires exactly once per successful pass, but read
        // `lastTranscript` for the actual text — it holds the
        // post-transform result.
        // ORDERING INVARIANT: `lastTranscript` must be set BEFORE
        // `lastResult` in RecorderController so this sink sees the right
        // value.
        deliveryBridge = services.recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak recorder = services.recorder, weak delivery = services.delivery] _ in
                Task { @MainActor [weak recorder, weak delivery] in
                    guard let text = recorder?.lastTranscript, !text.isEmpty else { return }
                    await delivery?.deliver(text)
                }
            }

        services.menuBar.install()
        services.overlay.install()

        // Install the hide-on-close proxy delegate the first time the
        // unified main window becomes key. Subscribing here (rather than
        // inside `JotMenuBarController.openUnifiedWindow`) makes the
        // hook active for launch auto-open, `openWindow` API, and any
        // other path that surfaces the window — not just the menu-bar
        // "Open Jot…" click.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.installCloseInterceptorIfNeeded(for: note.object as? NSWindow)
            }
        }

        services.recordingPersister.start()

        // Sound chimes: prewarm the five bundled WAVs and subscribe to
        // recorder state so transitions fire audio cues.
        SoundPlayer.shared.prewarm()
        services.soundTriggers.start(recorder: services.recorder)
        services.soundTriggers.start(articulate: services.articulateController)

        // Retention cleanup: purge on launch, hourly thereafter. Respects
        // `jot.retentionDays` (0 = keep forever).
        services.retention.start()
    }

    private func presentSetupWizardIfNeeded(_ services: AppServices) {
        let missingPermissions = [Capability.microphone, .inputMonitoring, .accessibilityPostEvents]
            .contains { services.permissions.statuses[$0] != .granted }
        guard !FirstRunState.shared.setupComplete || missingPermissions else { return }
        let holder = services.transcriberHolder
        let audio = services.audioCapture
        DispatchQueue.main.async {
            WizardPresenter.present(
                reason: .firstRun,
                transcriberHolder: holder,
                audioCapture: audio
            )
        }
    }

    private func installCloseInterceptorIfNeeded(for window: NSWindow?) {
        guard let window else { return }
        // Scope to the unified main window; setup wizard has its own
        // delegate.
        guard window.identifier?.rawValue.contains("jot-main") == true else { return }
        // Idempotent — skip if our interceptor is already installed.
        guard !(window.delegate is MainWindowCloseInterceptor) else { return }

        let interceptor = MainWindowCloseInterceptor()
        interceptor.wrappedDelegate = window.delegate
        window.delegate = interceptor
        window.isReleasedWhenClosed = false
        closeInterceptor = interceptor
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // Closing the main window (red X or ⌘W) must leave the process
    // alive so hotkeys, the menu-bar extra, and the status pill keep
    // working — only ⌘Q quits. AppKit would otherwise auto-terminate a
    // `.regular` app after its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }
}
