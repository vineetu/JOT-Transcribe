import AppKit
import Combine
import Sparkle
import SwiftData
import os.log

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.jot.Jot", category: "AppDelegate")
    private let singleInstance = SingleInstance()

    // Exposed so SwiftUI scenes (content, settings, menu-bar, overlay) can
    // @EnvironmentObject them. `RecorderController` and `DeliveryService` are
    // created eagerly at delegate construction time so they are ready before
    // the first `WindowGroup` body runs — environment-object injection can't
    // tolerate nil. Singleton checks etc. still happen in
    // `applicationDidFinishLaunching`; if we turn out to be a duplicate the
    // process terminates before any side effects land.
    let recorder: RecorderController = RecorderController()
    let delivery: DeliveryService = DeliveryService.shared
    private(set) var articulateController: ArticulateController!
    /// SwiftData stack. Shared with the SwiftUI scene via
    /// `.modelContainer(modelContainer)` so both the UI and the
    /// `RecordingPersister` write into the same store.
    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: Recording.self)
        } catch {
            // Can only fail if the underlying store is unreadable — fall back
            // to an in-memory store so the rest of the app still launches
            // rather than crashing at the splash screen.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: Recording.self, configurations: config)
        }
    }()
    private(set) var hotkeyRouter: HotkeyRouter!
    private(set) var menuBar: JotMenuBarController!
    private(set) var overlay: OverlayWindowController!
    private(set) var recordingPersister: RecordingPersister?
    private(set) var retention: RetentionService?
    private(set) var soundTriggers: SoundTriggers?
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var deliveryBridge: AnyCancellable?

    /// Strong reference to the proxy delegate installed on the unified
    /// main window so the red close button hides it instead of tearing
    /// the SwiftUI scene down. The app is a menu-bar agent (LSUIElement),
    /// so without this the user would have no AppKit chrome to reopen
    /// the window after a close.
    private var closeInterceptor: MainWindowCloseInterceptor?

    /// Token for the `NSWindow.didBecomeKeyNotification` subscription
    /// that drives install of `closeInterceptor`. Observing globally
    /// (rather than installing at the first menu-bar "Open Jot…" click)
    /// guarantees the hook is active from the very first window
    /// appearance — including launch auto-open and `openWindow` API
    /// paths that bypass the menu-bar controller.
    private var windowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        PermissionsService.shared.refreshAll()

        // Bug: custom input device pinning records from the wrong device.
        // Force system default until fixed so previously-set UIDs don't
        // affect the recording path.
        UserDefaults.standard.set("", forKey: "jot.inputDeviceUID")

        // Phase 3 wire-up: recorder → delivery → hotkeys. `recorder` and
        // `delivery` are already eagerly instantiated as stored properties.
        delivery.bind(recorder: recorder)

        let articulate = ArticulateController(
            capture: AudioCapture(),
            transcriber: Transcriber()
        )
        self.articulateController = articulate

        let router = HotkeyRouter(recorder: recorder, delivery: delivery, articulateController: articulate)
        router.activate()

        // Deliver the final transcript (transformed if Transform is on,
        // raw otherwise). We observe `$lastResult` as the trigger because it
        // fires exactly once per successful pass, but read `lastTranscript`
        // for the actual text — it holds the post-transform result.
        // ORDERING INVARIANT: `lastTranscript` must be set BEFORE
        // `lastResult` in RecorderController so this sink sees the right value.
        deliveryBridge = recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak delivery, weak recorder] _ in
                Task { @MainActor [weak delivery, weak recorder] in
                    guard let text = recorder?.lastTranscript, !text.isEmpty else { return }
                    await delivery?.deliver(text)
                }
            }

        self.hotkeyRouter = router

        self.menuBar = JotMenuBarController(recorder: recorder, delivery: delivery)
        self.menuBar.install()

        self.overlay = OverlayWindowController(recorder: recorder, delivery: delivery, articulateController: articulate)
        self.overlay.install()

        // Install the hide-on-close proxy delegate the first time the
        // unified main window becomes key. Subscribing here (rather
        // than inside `JotMenuBarController.openUnifiedWindow`) makes
        // the hook active for launch auto-open, `openWindow` API, and
        // any other path that surfaces the window — not just the
        // menu-bar "Open Jot…" click.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                self?.installCloseInterceptorIfNeeded(for: note.object as? NSWindow)
            }
        }

        // Library persister: subscribes to `recorder.$lastResult` and writes
        // a Recording row + WAV filename into SwiftData on each pass.
        let persister = RecordingPersister(
            recorder: recorder,
            context: modelContainer.mainContext
        )
        persister.start()
        self.recordingPersister = persister

        // Sound chimes: prewarm the five bundled WAVs and subscribe to
        // recorder state so transitions fire audio cues.
        SoundPlayer.shared.prewarm()
        let triggers = SoundTriggers()
        triggers.start(recorder: recorder)
        self.soundTriggers = triggers

        // Retention cleanup: purge on launch, hourly thereafter. Respects
        // `jot.retentionDays` (0 = keep forever).
        let retention = RetentionService(context: modelContainer.mainContext)
        retention.start()
        self.retention = retention

        let missingPermissions = [Capability.microphone, .inputMonitoring, .accessibilityPostEvents]
            .contains { PermissionsService.shared.statuses[$0] != .granted }
        if !FirstRunState.shared.setupComplete || missingPermissions {
            DispatchQueue.main.async { [recorder] in
                WizardPresenter.present(reason: .firstRun, transcriber: recorder.transcriber)
            }
        }

        // Pre-warm Parakeet out-of-band so the user's first recording doesn't
        // pay the 4–6 s ANE specialization latency synchronously — and, more
        // importantly, so the iOS 26.4-class MLModel load hang (Apple dev
        // forum 770529) can't park a mid-session recorder in .transcribing.
        // Best-effort: if the model isn't downloaded yet, or pre-warm fails,
        // the recorder will surface a fast "model still loading" error on
        // first press rather than silently hanging.
        Task.detached(priority: .utility) { [recorder] in
            try? await recorder.transcriber.ensureLoaded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // Jot is a menu-bar agent. Closing the main window (red X or ⌘W) must
    // leave the process alive so hotkeys, the menu-bar extra, and the
    // status pill keep working — only ⌘Q quits. LSUIElement alone doesn't
    // guarantee this; AppKit still auto-terminates an app after its last
    // window closes unless the delegate explicitly says otherwise.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func installCloseInterceptorIfNeeded(for window: NSWindow?) {
        guard let window else { return }
        // Scope to the unified main window; setup wizard has its own delegate.
        guard window.identifier?.rawValue.contains("jot-main") == true else { return }
        // Idempotent — skip if our interceptor is already installed.
        guard !(window.delegate is MainWindowCloseInterceptor) else { return }

        let interceptor = MainWindowCloseInterceptor()
        interceptor.wrappedDelegate = window.delegate
        window.delegate = interceptor
        window.isReleasedWhenClosed = false
        closeInterceptor = interceptor
    }

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }
}
