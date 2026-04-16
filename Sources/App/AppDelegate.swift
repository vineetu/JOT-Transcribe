import AppKit
import Combine
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

    private var deliveryBridge: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Phase 3 wire-up: recorder → delivery → hotkeys. `recorder` and
        // `delivery` are already eagerly instantiated as stored properties.
        delivery.bind(recorder: recorder)
        let router = HotkeyRouter(recorder: recorder, delivery: delivery)
        router.activate()

        // Any time the recorder publishes a fresh non-nil transcription
        // result, ship it into the delivery pipeline. We observe
        // `lastResult` rather than `state` because a single transition into
        // `.idle` from `.transcribing` is the event we actually care about,
        // and `lastResult` changes exactly once per successful pass.
        deliveryBridge = recorder.$lastResult
            .compactMap { $0 }
            .sink { [weak delivery] result in
                Task { @MainActor [weak delivery] in
                    await delivery?.deliver(result.text)
                }
            }

        self.hotkeyRouter = router

        self.menuBar = JotMenuBarController(recorder: recorder, delivery: delivery)
        self.menuBar.install()

        self.overlay = OverlayWindowController(recorder: recorder, delivery: delivery)
        self.overlay.install()

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

        // First-run gate. Deferred to the next main-queue turn so the primary
        // `WindowGroup` has a chance to materialize before the wizard window
        // orders itself front — otherwise the main window flashes on top of
        // the wizard on cold launch.
        if !FirstRunState.shared.setupComplete {
            DispatchQueue.main.async {
                WizardPresenter.present(reason: .firstRun)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
