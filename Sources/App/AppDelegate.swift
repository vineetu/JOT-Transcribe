import AppKit
import AVFoundation
import JotVocabCore
import SwiftData
import os.log

/// `.regular` activation policy (set in `applicationDidFinishLaunching`)
/// gives Jot a Dock icon and ⌘Tab entry; `closeInterceptor` below hides
/// the window on ⌘W so hotkeys and the menu-bar extra keep working until
/// ⌘Q. Previously `.accessory` with `LSUIElement = true`, which hid the
/// app from every AppKit surface — unfriendly when the app ever wedged,
/// since users couldn't Force Quit it through normal channels.
///
/// The "Show Jot in the Dock" preference (`jot.dock.show`, default true)
/// lets the user opt back into `.accessory` for a menu-bar-only Jot. The
/// decision is made once at `applicationDidFinishLaunching` via
/// `dockActivationPolicy(setupComplete:storedShowInDock:)` — no
/// mid-session policy juggling. While the Setup Wizard is still pending
/// (`FirstRunState.shared.setupComplete == false`), we force `.regular`
/// regardless so the wizard always has a Dock icon during the macOS
/// Settings round-trip for permission grants.

/// Pure decision function for the macOS activation policy at launch.
///
/// - Parameters:
///   - setupComplete: `FirstRunState.shared.setupComplete` at launch.
///     When `false`, we force `.regular` so the Setup Wizard window has
///     a Dock icon during permission grant flows.
///   - storedShowInDock: The user's `jot.dock.show` preference, or `nil`
///     if no value has been written yet (default behavior: show in Dock).
/// - Returns: The `NSApplication.ActivationPolicy` to apply at launch.
///
/// Pulled out as a free function so DEBUG tests can exercise the matrix
/// without launching the app or touching `NSApplication`.
func dockActivationPolicy(
    setupComplete: Bool,
    storedShowInDock: Bool?
) -> NSApplication.ActivationPolicy {
    let forceRegular = !setupComplete
    let showInDock = forceRegular || (storedShowInDock ?? true)
    return showInDock ? .regular : .accessory
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
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
    @Published private(set) var services: AppServices!

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
        // If a previous run died mid-recording with the output device muted,
        // the Mac is silent right now and nothing on screen says why. Undo it
        // before anything else. No-op in the normal case.
        AudioTakeover.shared.restorePendingAfterCrash()
        // One-shot Advanced-mode migration (v1.13). Must run BEFORE any
        // SwiftUI scene materializes so `@AppStorage("jot.advanced.enabled")`
        // bindings in `AppSidebar` / `JotAppWindow` see the seeded value on
        // first read. Idempotent; gated by `jot.advanced.migrated`.
        AdvancedFlag.migrateIfNeeded()

        let wasSetupCompleteAtLaunch = FirstRunState.shared.setupComplete
        // Read the "Show Jot in the Dock" preference once at launch. The
        // gate forces `.regular` while the Setup Wizard is pending so
        // permission round-trips through System Settings keep a Dock
        // icon to come back to. After setup completes, subsequent
        // launches honor the user's stored toggle.
        let storedShowInDock = UserDefaults.standard.object(forKey: "jot.dock.show") as? Bool
        let policy = dockActivationPolicy(
            setupComplete: wasSetupCompleteAtLaunch,
            storedShowInDock: storedShowInDock
        )
        NSApp.setActivationPolicy(policy)
        log.info("Jot launched")

        // Hotfix: ensure Jot appears in System Settings → Privacy → Microphone
        // by force-triggering TCC registration on launch. Only fires when
        // status is .notDetermined; no-op when already granted/denied.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        }

        #if DEBUG
        HelpInfraTests.runAll()
        ThemeTests.runAll()
        ChatbotVoiceInputTests.runAll()
        ShortcutsTests.runAll()
        DockActivationPolicyTests.runAll()
        AdvancedFlagTests.runAll()
        WebVTTExporterTests.runAll()
        SpeakerTimelineTests.runAll()
        SpeakerTimelineTextEditTests.runAll()
        RecordingTextMutationTests.runAll()
        TranscriptSearchTests.runAll()
        RecordingSummaryTests.runAll()
        VocabAskFilterTests.runAll()
        SegmentSlicingTests.runAll()
        ModelSwitchTests.runAll()
        DownloadRetryTests.runAll()
        ModelPickerDisplayTests.runAll()
        LanguageVisibilityTests.runAll()
        ChipTierTests.runAll()
        RewriteHintFormatterTests.runAll()
        #endif

        ResetActions.processPendingHardReset()

        if singleInstance.anotherInstanceIsRunning() {
            singleInstance.activateExistingInstance()
            NSApp.terminate(nil)
            return
        }

        // Vocabulary-core adoption (design §3, L3): relocate the single curated
        // `vocabulary.txt` from its legacy `Jot/Vocabulary/` path to the unified
        // `Vocabulary/` root the package + `VocabularyStore` now resolve. Runs
        // unconditionally (idempotent — no-op once moved) and STRICTLY BEFORE the
        // first `VocabularyStore` / `CorrectionStore` / `CorrectionProvenance`
        // touch below, so no `save()` can write to the new path while the file
        // still sits at the old one (or race the move).
        VocabMigration.relocateVocabularyFileIfNeeded()
        // One-time: drop learned rules whose original is an everyday word (the
        // learning guard refuses new ones). After the relocation above.
        Task { await MacVocabCore.migrateCommonOriginalRulesIfNeeded() }
        // One-time: pairs learned from edits move into the list as sounds-likes.
        Task { await MacVocabCore.migrateEditLearnedPairsIfNeeded() }

        preConstructionSetup()

        do {
            self.services = try JotComposition.build(systemServices: .live)
        } catch {
            fatalError("JotComposition.build failed: \(error)")
        }

        wireUp(services)
        let setupPresented = presentSetupWizardIfNeeded(
            services,
            wasSetupCompleteAtLaunch: wasSetupCompleteAtLaunch
        )
        if !setupPresented {
            DispatchQueue.main.async {
                SingleOrChordMigrationWizardPresenter.presentIfNeeded(
                    wasSetupCompleteAtLaunch: wasSetupCompleteAtLaunch
                )
            }
        }
        prewarmTranscriber(services)
    }

    private func preConstructionSetup() {
        singleInstance.installObserver {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        _ = FirstRunState.shared
        // Singleton init already triggers refreshAll() (PermissionsService.swift:59); no need to re-invoke.
        _ = PermissionsService.shared
    }

    /// Pre-warm Parakeet out-of-band so the user's first recording
    /// doesn't pay the 4–6 s ANE specialization latency synchronously,
    /// and so the iOS 26.4-class MLModel load hang (Apple dev forum
    /// 770529) can't park a mid-session recorder in `.transcribing`.
    ///
    /// Startup model-integrity self-heal (design §Phase 1, review G1): this
    /// prewarm is now ALSO the integrity probe. It is the SINGLE live launch
    /// load on `holder.transcriber` — its result is observed (no longer a
    /// discarded fire-and-forget) and routed into the self-heal so a missing /
    /// corrupt model is detected at launch instead of reactively at the cursor.
    /// We deliberately do NOT spin a second `Transcriber` to probe: that would
    /// double the multi-GB ANE load and race FluidAudio's process-global
    /// `sharedMLArrayCache`.
    ///
    /// Best-effort: if the model isn't downloaded yet, or the probe surfaces a
    /// failure, the self-heal kicks in (re-download + route + persistent pill);
    /// a hotkey pressed before it finishes still gets a fast user-visible state.
    private func prewarmTranscriber(_ services: AppServices) {
        let holder = services.transcriberHolder
        Task.detached(priority: .utility) { [holder] in
            let result = await holder.probeActiveModelOnLaunch()
            await MainActor.run {
                if result.allHealthy {
                    holder.markActiveModelHealthy()
                }
            }
            if !result.allHealthy {
                await holder.beginSelfHeal(failedSides: result.failedSides)
            }
        }
    }

    private func wireUp(_ services: AppServices) {
        // Phase 3 wire-up: recorder → delivery → hotkeys. The graph is
        // already constructed; this binds the runtime channel between
        // them.
        services.delivery.bind(library: services.modelContainer.mainContext)
        // Wire the rewrite controller so `pasteLast()` can replay
        // rewrite outputs (not just dictation transcripts) — picks
        // whichever was most recent. Optional binding so harness
        // tests that don't construct a rewrite controller still get
        // the dictation-only paste-last path.
        services.delivery.bind(rewriteController: services.rewriteController)
        // One-shot migration that introduced single-key Toggle Recording.
        // Must run BEFORE `hotkeyRouter.activate()`
        // so the router's first `applySingleKeys()` reads the
        // migration-installed default.
        SingleKeyMigration.runIfNeeded()
        services.hotkeyRouter.activate()

        // The one `$lastResult` sink: save each finished dictation, then
        // deliver it (asking "Did you mean…?" first when the gate flagged a
        // word), with the saved row's id travelling alongside the text.
        services.dictationBridge.start()

        services.menuBar.install()
        services.overlay.install()

        // v1.14: wire the saved-to-Recents pill's click handler. Tapping
        // the affordance opens the main window on the Recents pane AND
        // navigates to the just-saved Recording detail. The audio file
        // name is captured at pill-show time and forwarded through
        // `invokeSavedToRecentsTap()` so a click here always references
        // *that session's* recording, never a stale one.
        services.overlay.pillViewModel.onSavedToRecentsTap = {
            [weak menuBar = services.menuBar] audioFile in
            menuBar?.openHomeFromOverlay()
            guard let audioFile else { return }
            // Small delay so the SwiftUI scene has materialized
            // `RecordingsListView` before the notification posts.
            // Without this, a cold-open hit races the view's
            // `.onReceive` registration and the navigation drops on
            // the floor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NotificationCenter.default.post(
                    name: .jotRecentsOpenRecording,
                    object: nil,
                    userInfo: ["audioFileName": audioFile]
                )
            }
        }

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

        // The failure edge only ("Never lose audio"): a dictation whose
        // transcription failed after its audio was saved gets a pending row.
        services.recordingPersister.start()

        // Phase 4 (startup self-heal design): drive the pending
        // migration / Nemotron-upgrade downloads at LAUNCH, not only from
        // `JotAppWindow.onAppear` — otherwise hotkey-only users (who may never
        // open the window) never get them. Both are idempotent once-flag
        // guarded, so the retained `onAppear` calls are harmless duplicates.
        // These also retire their pending markers, which the self-heal's launch
        // deferral guard reads to avoid running a 3rd concurrent download.
        services.transcriberHolder.startPendingMigrationDownloadIfNeeded()
        services.transcriberHolder.startPendingNemotronUpgradeIfNeeded()
        services.transcriberHolder.startPendingNemotronMultilingualUpgradeIfNeeded()

        // Vocabulary spotter: prepare the CTC bundle at LAUNCH when boosting is
        // on and the primary is CTC-capable (everything except JA, which uses
        // alias substitution). Preparation was previously tied to the main
        // window / Vocabulary pane appearing, so a hotkey-only user — never
        // opening a window — got a `nil` spotter and ZERO vocabulary on every
        // dictation. Best-effort; the holder logs its own failures.
        // CTC-capable = everything except JA, which uses alias substitution
        // rather than the CTC spotter.
        if VocabularyStore.shared.isEnabled,
           services.transcriberHolder.primaryModelID != .tdt_0_6b_ja,
           let vocabURL = VocabularyStore.shared.fileURL {
            Task { try? await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: vocabURL) }
        }

        // Semantic search (default ON): warm the embedding model (downloading it
        // if needed) and backfill any not-yet-indexed recordings at launch. The
        // Settings toggle's onChange only fires on an EDIT — it never fires when
        // the stored default already matches ON — so without this kick the
        // existing library is never indexed and search returns nothing until the
        // user manually toggles. backfillMissing() guards its own re-entrancy.
        if SemanticSearchSettings.isEnabled {
            Task.detached(priority: .utility) { try? await EmbeddingGemmaService.shared.prewarm() }
            Task(priority: .background) { await RecordingIndexer.shared?.backfillMissing() }
        }
        // One-time: drop search chunks left behind by recordings deleted
        // before deleting a recording removed its chunks (they could still
        // surface a deleted recording in Ask Jot). Runs whatever the toggle.
        ChunkStore.purgeOrphanedChunksOnce(container: services.modelContainer)

        // Sound chimes: prewarm the five bundled WAVs and subscribe to
        // recorder state so transitions fire audio cues. Prewarm runs on
        // a detached utility Task so the WAV decode + AVAudioPlayer
        // construction don't block the launch critical path.
        Task.detached(priority: .utility) {
            await MainActor.run { SoundPlayer.shared.prewarm() }
        }
        services.soundTriggers.start(recorder: services.recorder)
        services.soundTriggers.start(rewrite: services.rewriteController)

        // Retention cleanup: purge on launch, hourly thereafter. Respects
        // `jot.retentionDays` (0 = keep forever).
        services.retention.start()

        // "Never lose audio" safety net (docs/resilient-transcription/design.md):
        // one-time scan adopting any audio file with no Recording row as a
        // pending row (crash mid-transcription, force-quit, or a
        // pre-existing shipped orphan).
        services.orphanRecordingScanner.start()

        // Speaker diarization (Nemotron 3): deliberately NO launch-time
        // warmup (design D4). The model downloads/loads lazily the first
        // time the user opens Settings → Speaker labels or taps "Detect
        // speakers" — there is no background cost to eagerly pay at launch.
    }

    private func presentSetupWizardIfNeeded(
        _ services: AppServices,
        wasSetupCompleteAtLaunch: Bool
    ) -> Bool {
        let missingPermissions = [Capability.microphone, .inputMonitoring, .accessibilityPostEvents]
            .contains { services.permissions.statuses[$0] != .granted }
        guard !FirstRunState.shared.setupComplete || missingPermissions else { return false }
        let holder = services.transcriberHolder
        let audio = services.audioCapture
        let urlSession = services.urlSession
        let appleIntelligence = services.appleIntelligence
        let llmConfiguration = services.llmConfiguration
        let logSink = services.logSink
        let hotkeyRouter = services.hotkeyRouter
        let promptStore = services.promptStore
        DispatchQueue.main.async {
            WizardPresenter.present(
                reason: .firstRun,
                transcriberHolder: holder,
                audioCapture: audio,
                urlSession: urlSession,
                appleIntelligence: appleIntelligence,
                llmConfiguration: llmConfiguration,
                logSink: logSink,
                hotkeyRouter: hotkeyRouter,
                promptStore: promptStore,
                onDismiss: {
                    SingleOrChordMigrationWizardPresenter.presentIfNeeded(
                        wasSetupCompleteAtLaunch: wasSetupCompleteAtLaunch
                    )
                }
            )
        }
        return true
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
