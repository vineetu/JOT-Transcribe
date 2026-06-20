import AppKit
import AVFoundation
import Combine
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
        ChatbotVoiceInputTests.runAll()
        ShortcutsTests.runAll()
        DockActivationPolicyTests.runAll()
        SpeakerLabelsTests.runAll()
        AdvancedFlagTests.runAll()
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
        services.delivery.bind(recorder: services.recorder)
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
            .sink { [weak self,
                     weak recorder = services.recorder,
                     weak delivery = services.delivery,
                     weak overlay = services.overlay] result in
                Task { @MainActor [weak self, weak recorder, weak delivery, weak overlay] in
                    guard let self, let recorder, let delivery else { return }
                    self.handleDeliveryBridge(
                        result: result,
                        recorder: recorder,
                        delivery: delivery,
                        overlay: overlay
                    )
                }
            }

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

        // Speaker Labels piece A — warmup. Loads Sortformer + replays
        // enrolled clips so slot↔name bindings are live before the first
        // recording. Skipped when: model isn't downloaded yet (a fresh
        // install or pre-feature user); no identities enrolled; master
        // toggle is OFF; hardware is below the 16 GB gate.
        //
        // Per plan Risk #1 the wall-clock cost (replays N ~30 s clips
        // through `enrollSpeaker(withAudio:)`) is empirically unknown.
        // Detached `Task` keeps it off the launch critical path; the
        // first recording after launch may briefly run without labels
        // if warmup hasn't completed.
        let speakerLabelsMasterOn = UserDefaults.standard.object(forKey: "jot.speakerLabels.enabled") as? Bool ?? true
        if Features.speakerLabels,
           speakerLabelsMasterOn,
           SortformerHardwareGate.isSupported {
            let clips = services.enrolledIdentitiesStore.clipsForWarmup()
            switch services.sortformerHolder.state {
            case .offHaveModel where !clips.isEmpty:
                Task { @MainActor [weak holder = services.sortformerHolder] in
                    await holder?.loadIfNeeded(clips: clips)
                }
            case .notSetUp where !clips.isEmpty:
                // Identities already enrolled but model bundle missing or
                // corrupt — auto-redownload so labels resume working without
                // the user having to delete their enrollment to expose the
                // "Set up" CTA.
                Task { @MainActor [weak holder = services.sortformerHolder] in
                    guard let holder else { return }
                    try? await holder.downloadModelIfNeeded()
                    // Re-check the master toggle after the (~250 MB,
                    // multi-second) download. The user may have flipped
                    // Speaker Labels OFF mid-download — in that case the
                    // bundle is on disk but we honor the OFF intent by
                    // skipping the load. The next launch with the toggle
                    // back ON will warm the model from the disk cache.
                    let stillEnabled = UserDefaults.standard.object(forKey: "jot.speakerLabels.enabled") as? Bool ?? true
                    guard stillEnabled else { return }
                    await holder.loadIfNeeded(clips: clips)
                }
            default:
                break
            }
        }
    }

    /// The single dictation auto-paste choke point (`ask-ux.md` §1). Decides
    /// among three paths for a freshly-landed transcript:
    ///   1. `skipNextPaste` — the user stopped via the in-app pill / Esc: persist
    ///      to Recents, surface the saved-to-Recents affordance, no paste.
    ///   2. Ask-before-paste (Slice D) — one or more `askCandidate` corrections
    ///      whose term is STILL present in the FINAL (possibly transformed) text:
    ///      hold the paste, ask "Did you mean X?" sequentially, then deliver once.
    ///   3. The unchanged fast path — deliver immediately (zero added latency).
    @MainActor
    private func handleDeliveryBridge(
        result: TranscriptionResult,
        recorder: RecorderController,
        delivery: DeliveryService,
        overlay: OverlayWindowController?
    ) {
        guard let text = recorder.lastTranscript, !text.isEmpty else { return }

        // v1.14: read-and-clear `skipNextPaste`. When the user stopped via the
        // in-app Record pill or Esc (rather than the trigger hotkey), the
        // recording still persists to Recents but the paste step is suppressed.
        if recorder.skipNextPaste {
            recorder.skipNextPaste = false
            let audioFile = recorder.lastAudioRecording?.fileURL.lastPathComponent
            overlay?.pillViewModel.showSavedToRecents(
                preview: text,
                audioFileName: audioFile
            )
            return
        }

        // Slice D §8 B1 — Transform-safe hold. Char offsets are meaningless after
        // the gate's downstream segmenter / Transform rewrite, so we DON'T splice
        // by offset. Instead, take the gate's structured `{from,to}` ask
        // candidates and string-match against the FINAL text:
        //   * APPLIED candidate (silent-OOV, §9 (i)): the term `to` is already in
        //     the text. Keep = leave it; keep-original = replace `to`→`from`.
        //   * BLOCKED candidate (common-word near-miss, §9 (ii)): the original
        //     `from` is in the text. Confirm = replace `from`→`to`; keep = leave it.
        // Either way we anchor on a word that is ACTUALLY present; if Transform
        // reworded BOTH away, the correction is moot → drop the ask (graceful
        // fallback). Cap at 3 (anti-nag, §4).
        let askable = result.corrections
            .filter { $0.askCandidate }
            .compactMap { AskItem(correction: $0, in: text) }
            .prefix(3)

        guard let pill = overlay?.pillViewModel, !askable.isEmpty else {
            // Unchanged fast path — deliver immediately.
            Task { @MainActor in await delivery.deliver(text) }
            return
        }

        runAskSequence(
            staged: text,
            candidates: Array(askable),
            index: 0,
            delivery: delivery,
            pill: pill
        )
    }

    /// One resolvable ask, anchored on a word currently PRESENT in the staged
    /// text (Slice D). `from`/`term` carry the gate's pair; `applied` records
    /// which the gate did so the bridge knows which edit each decision implies.
    private struct AskItem {
        let from: String
        let term: String
        let applied: Bool

        /// Build only if the relevant word is present in `text`; returns nil
        /// (drop the ask) when neither anchor survived the downstream rewrite.
        init?(correction c: VocabularyRescorerHolder.UXCorrection, in text: String) {
            self.from = c.from
            self.term = c.to
            if AppDelegate.containsWholeWord(c.to, in: text) {
                // The term is in the text → the gate APPLIED it.
                self.applied = true
            } else if AppDelegate.containsWholeWord(c.from, in: text) {
                // The original is in the text → the gate BLOCKED it.
                self.applied = false
            } else {
                return nil
            }
        }
    }

    /// Resolve the ask candidates SEQUENTIALLY in the one pill (§4), mutating the
    /// staged text as each resolves, then `deliver()` exactly once when the queue
    /// empties (§8 M4/M5 — every path terminates in one deliver). Recurses via the
    /// pill's confirm / dismiss closures so the next ask only starts after the
    /// current one resolves.
    @MainActor
    private func runAskSequence(
        staged: String,
        candidates: [AskItem],
        index: Int,
        delivery: DeliveryService,
        pill: PillViewModel
    ) {
        guard index < candidates.count else {
            // Queue drained — deliver the final staged text exactly once.
            // Auto-Enter (if enabled) runs INSIDE deliver(), after the paste,
            // which is correct relative to the resolved text (§8 M3).
            Task { @MainActor in await delivery.deliver(staged) }
            return
        }

        let c = candidates[index]
        // The word this ask anchors on (term if applied, original if blocked).
        // If a PRIOR ask's edit removed it from the staged text, the ask is moot
        // — skip to the next without prompting.
        let anchor = c.applied ? c.term : c.from
        guard Self.containsWholeWord(anchor, in: staged) else {
            runAskSequence(
                staged: staged,
                candidates: candidates,
                index: index + 1,
                delivery: delivery,
                pill: pill
            )
            return
        }

        let next: (String) -> Void = { [weak self] newStaged in
            self?.runAskSequence(
                staged: newStaged,
                candidates: candidates,
                index: index + 1,
                delivery: delivery,
                pill: pill
            )
        }

        // `original` shown on the Keep button is always the word the user spoke
        // (`from`); `term` is always the offered vocabulary term.
        pill.showAskCorrection(
            original: c.from,
            term: c.term,
            onConfirm: {
                // Confirm → the text should hold the TERM. For an applied
                // candidate it already does; for a blocked one, splice from→term.
                let confirmed = c.applied
                    ? staged
                    : Self.replaceWholeWord(c.from, with: c.term, in: staged)
                // Learn it so future dictations auto-apply (rare/OOV) and stop
                // asking (Q3). For a common original the gate still won't
                // auto-apply, but the single confirm pastes the term this time.
                Task { await CorrectionStore.shared.confirm(originalWord: c.from, term: c.term) }
                next(confirmed)
            },
            onDismiss: {
                // Keep-original → the text should hold the ORIGINAL word. For an
                // applied candidate, splice term→from; for a blocked one it's
                // already the original. Write nothing to the store (a passive
                // ignore is not a rejection, §3).
                let kept = c.applied
                    ? Self.replaceWholeWord(c.term, with: c.from, in: staged)
                    : staged
                next(kept)
            }
        )
    }

    /// Whole-word, case-insensitive containment test. Mirrors the gate's
    /// word-boundary logic so "Lisa" doesn't match inside "Lisbon".
    nonisolated static func containsWholeWord(_ word: String, in text: String) -> Bool {
        wholeWordRange(of: word, in: text) != nil
    }

    /// Replace the FIRST whole-word occurrence of `word` with `replacement`,
    /// case-insensitive. Used for keep-original (term → original). Only the first
    /// occurrence is touched — the de-duped correction set carries one entry per
    /// `(from,to)` pair, and replacing all could over-revert a legitimately
    /// repeated term.
    nonisolated static func replaceWholeWord(_ word: String, with replacement: String, in text: String) -> String {
        guard let range = wholeWordRange(of: word, in: text) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }

    /// First whole-word range of `word` in `text` (case-insensitive). A match is
    /// whole-word only when the chars on either side are non-letters.
    nonisolated private static func wholeWordRange(of word: String, in text: String) -> Range<String.Index>? {
        guard !word.isEmpty else { return nil }
        var search = text.startIndex
        while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
            let before: Character? = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after: Character? = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            let okBefore = !(before?.isLetter ?? false)
            let okAfter = !(after?.isLetter ?? false)
            if okBefore && okAfter { return r }
            search = r.upperBound
        }
        return nil
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
