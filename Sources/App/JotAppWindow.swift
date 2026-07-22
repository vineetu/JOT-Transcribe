import SwiftUI

/// Root content view for the unified Jot window — the single destination
/// the menu bar's "Open Jot…" item opens (design doc §1).
///
/// Shape:
///   • `NavigationSplitView(sidebar:detail:)`
///   • Sidebar: `AppSidebar` bound to `selection`.
///   • Detail: the pane for the current selection, rendered directly.
///     Each pane owns its own scroll behavior — `Form.grouped` for
///     settings panes, `List` for Home, and `ScrollView` for Help —
///     so the window can be freely resized by the user and the
///     content scrolls within when the window is smaller than its
///     natural size (`.windowResizability(.contentMinSize)` in
///     `JotApp.swift`).
///
/// Deep children (inline "Set up AI →" links, popover "Learn more →"
/// footers) change the selection by calling the
/// `\.setSidebarSelection` environment closure installed here — no
/// ad-hoc window lookups, no notifications-as-state.
struct JotAppWindow: View {
    /// Buffer written by the menu bar controller BEFORE opening the
    /// window on a cold-open. Read once as the initial `@State` value so
    /// the first render already has the correct sidebar selection — this
    /// avoids a race where a `.jotWindowSetSidebarSelection` notification
    /// posted before the SwiftUI scene materialized would be dropped
    /// (the `.onReceive` observer isn't registered yet). The
    /// notification path below remains authoritative for re-selections
    /// of an already-open window.
    @MainActor static var pendingSelection: AppSidebarSelection?

    @State private var selection: AppSidebarSelection
    @State private var navHistory: NavigationHistory
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    /// v1.13: master toggle for the Advanced surface. Observed so we can
    /// (a) sanitize incoming sidebar selections that point at now-hidden
    /// panes, and (b) redirect + cancel + scrub history when the user
    /// flips Advanced off mid-session.
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false

    /// Shared Help navigator. Owned at this root so every pane (Help,
    /// Ask Jot, Settings popovers) sees the same instance — deep-link
    /// state set by one consumer is always visible to the next one.
    @State private var helpNavigator: HelpNavigator

    /// Shared Ask Jot chatbot store. Owned at this root so the
    /// conversation survives sidebar navigation (chatbot spec v5 §4 +
    /// gotcha #6 — correctness-critical).
    @State private var chatStore: HelpChatStore

    /// Recording-detail AI summary service. Owned at this root and injected as an
    /// `@EnvironmentObject` (like `LLMConfiguration`) so `RecordingDetailView`
    /// gets its LLM deps by injection instead of reaching `AppServices.live`.
    @State private var summarizer: RecordingSummarizer

    /// Shared chatbot voice-input bridge. Owned at this root so the
    /// `recorder.$state` Combine subscription persists across pane
    /// navigation and the mutual-exclusion with global dictation stays
    /// live the whole time the window is up.
    @State private var voiceInput: ChatbotVoiceInput

    /// Transcript-Q&A Ask Jot store. Owned at the root so the conversation
    /// SURVIVES sidebar navigation (the old per-pane store was torn down on
    /// exit, wiping the chat). Built lazily once the env `ModelContainer` is
    /// available — a `@State` initializer can't read `@Environment`.
    @State private var askStore: AskRecordingsStore?
    @Environment(\.modelContext) private var modelContext

    /// Phase 3 #29: per-graph `LLMConfiguration` injected as an
    /// `@EnvironmentObject` for SwiftUI panes (`RewritePane`,
    /// `AboutPane`) and threaded into `HelpChatStore` via constructor.
    private let llmConfiguration: LLMConfiguration

    /// Phase 4 patch round 5: seams threaded into `RewritePane` for
    /// the Test Connection path and `GeneralPane` for the "Run Setup
    /// Wizard Again" button and destructive Reset alerts. Pre-fix both
    /// panes reached `AppServices.live` lazily on click and could trip on
    /// a fresh-install timing race; constructor-injection mirrors Phase 3
    /// #29.
    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting
    private let audioCapture: any AudioCapturing
    private let keychain: any KeychainStoring
    /// Forwarded into `GeneralPane` → `WizardPresenter.present(...)` so
    /// the wizard's hotkey-driven `TestStep` can temporarily commandeer
    /// `.toggleRecording`.
    private let hotkeyRouter: HotkeyRouter
    /// v1.14: held here so `HomePane` can observe state for the inline
    /// Record pill and call `recorder.toggle()` from the click handler.
    private let recorder: RecorderController

    @MainActor
    init(
        pipeline: VoiceInputPipeline,
        recorder: RecorderController,
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting,
        audioCapture: any AudioCapturing,
        keychain: any KeychainStoring,
        llmConfiguration: LLMConfiguration,
        hotkeyRouter: HotkeyRouter
    ) {
        self.init(
            pipeline: pipeline,
            recorder: recorder,
            urlSession: urlSession,
            appleIntelligence: appleIntelligence,
            audioCapture: audioCapture,
            keychain: keychain,
            llmConfiguration: llmConfiguration,
            hotkeyRouter: hotkeyRouter,
            navigationHistory: NavigationHistory()
        )
    }

    @MainActor
    init(
        pipeline: VoiceInputPipeline,
        recorder: RecorderController,
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting,
        audioCapture: any AudioCapturing,
        keychain: any KeychainStoring,
        llmConfiguration: LLMConfiguration,
        hotkeyRouter: HotkeyRouter,
        navigationHistory: NavigationHistory
    ) {
        let raw = JotAppWindow.pendingSelection ?? .home
        JotAppWindow.pendingSelection = nil
        // Read the flag directly out of UserDefaults at init time so the
        // very first render already has a sanitized selection. Reading
        // `@AppStorage` from inside `init` isn't supported (the property
        // wrapper isn't materialized until `body` runs). The launch-time
        // `AdvancedFlag.migrateIfNeeded()` call runs from `AppDelegate`
        // BEFORE this `init` executes, so the value is always present.
        let advancedSeed = UserDefaults.standard.bool(forKey: AdvancedFlag.storageKey)
        let initial = JotAppWindow.sanitize(raw, advancedEnabled: advancedSeed)
        _selection = State(initialValue: initial)
        _navHistory = State(initialValue: navigationHistory)
        self.llmConfiguration = llmConfiguration
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
        self.audioCapture = audioCapture
        self.keychain = keychain
        self.hotkeyRouter = hotkeyRouter
        self.recorder = recorder
        // Build the store tied to the same navigator instance we own
        // above so `ShowFeatureTool` → navigator → HelpPane routing
        // writes/reads the same observable.
        let nav = HelpNavigator()
        _helpNavigator = State(initialValue: nav)
        _chatStore = State(initialValue: HelpChatStore(
            navigator: nav,
            urlSession: urlSession,
            llmConfiguration: llmConfiguration,
            appleIntelligence: appleIntelligence
        ))
        _summarizer = State(initialValue: RecordingSummarizer(
            urlSession: urlSession,
            appleClient: appleIntelligence,
            llmConfiguration: llmConfiguration
        ))
        _voiceInput = State(initialValue: ChatbotVoiceInput(
            pipeline: pipeline,
            recorder: recorder,
            condenser: .appleIntelligence
        ))
    }

    /// Build the root-owned Ask Jot store once the env `ModelContainer` is
    /// available. Idempotent.
    private func buildAskStoreIfNeeded() {
        guard askStore == nil else { return }
        askStore = AskRecordingsStore(
            urlSession: urlSession,
            appleClient: appleIntelligence,
            llmConfiguration: llmConfiguration,
            modelContainer: modelContext.container
        )
    }

    /// Run a pending question from the AI-search button (`pendingAsk`) or the
    /// legacy Help/About → Ask Jot deep-link (`pendingPrefill`). The unified Ask
    /// Jot answers app/feature questions too, so we run it rather than strand it.
    private func consumeAskPending() {
        buildAskStoreIfNeeded()
        guard let askStore else { return }
        let raw = helpNavigator.pendingAsk ?? helpNavigator.pendingPrefill
        guard let question = raw,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        helpNavigator.pendingAsk = nil
        helpNavigator.pendingPrefill = nil
        helpNavigator.focusChatInput = false
        askStore.ask(question)
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(
                selection: $selection,
                // v1.17: transcript-Q&A Ask Jot works with any provider and
                // handles its own readiness/consent states, so it's no longer
                // gated on Apple-Intelligence availability.
                askJotAvailable: true
            )
        } detail: {
            detail
                .environment(\.helpNavigator, helpNavigator)
        }
        .environment(\.navigationHistory, navHistory)
        .environment(\.setSidebarSelection) { newValue in
            // v1.13: deep-links from Help "Open in Settings →", About
            // Ask Jot row, Help Basics sparkles, cloud `ShowFeatureTool`,
            // and any future call site all flow through this closure.
            // Redirect requests that target a now-hidden pane so the
            // detail view never strands the user on an orphan.
            selection = JotAppWindow.sanitize(newValue, advancedEnabled: advancedEnabled)
        }
        .environment(\.helpNavigator, helpNavigator)
        .environmentObject(llmConfiguration)
        .environmentObject(summarizer)
        // Download/switch/repair status floats as a compact card in the
        // bottom-right corner (≈¼ width) rather than a full-width top strip —
        // it's an ambient status, not a modal that should eat the whole header.
        .overlay(alignment: .bottomTrailing) {
            migrationDownloadBanner
                .frame(maxWidth: 360)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(16)
        }
        .onAppear {
            navHistory.bind(selection: $selection)
            transcriberHolder.startPendingMigrationDownloadIfNeeded()
            // Nemotron auto-upgrade (download-first-then-flip). Reuses the
            // same `migrationDownloadBanner` above for progress/error UI.
            transcriberHolder.startPendingNemotronUpgradeIfNeeded()
            // Qwen-retirement → Nemotron Multilingual (download-first-then-flip),
            // same banner. Cross-language English fallback covers the gap.
            transcriberHolder.startPendingNemotronMultilingualUpgradeIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .jotWindowSetSidebarSelection)) { note in
            if let newSelection = note.userInfo?["selection"] as? AppSidebarSelection {
                selection = JotAppWindow.sanitize(newSelection, advancedEnabled: advancedEnabled)
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            guard oldValue != newValue else { return }
            navHistory.pushCurrent(oldValue)
        }
        // Navigator-driven sidebar mutation — sparkle icons, About
        // row, and `ShowFeatureTool` set `navigator.sidebarSelection`
        // and we mirror that into the bound selection. Clear the
        // navigator field after consumption so the same target
        // re-fires cleanly next time.
        .onChange(of: helpNavigator.sidebarSelection) { _, newValue in
            guard let newValue else { return }
            selection = JotAppWindow.sanitize(newValue, advancedEnabled: advancedEnabled)
            helpNavigator.sidebarSelection = nil
        }
        // Build the root-owned Ask Jot store once (so the conversation persists),
        // and run questions pushed from the AI-search button / Help deep-links.
        .task { buildAskStoreIfNeeded() }
        .onChange(of: helpNavigator.pendingAsk) { _, _ in consumeAskPending() }
        .onChange(of: helpNavigator.pendingPrefill) { _, _ in consumeAskPending() }
        // v1.13: when the user flips Advanced off mid-session, redirect
        // any selection pointing at a now-hidden pane, cancel any
        // in-flight Ask Jot stream, and scrub stale back/forward history.
        .onChange(of: advancedEnabled) { _, isOn in
            guard !isOn else { return }
            selection = JotAppWindow.sanitize(selection, advancedEnabled: false)
            chatStore.cancelStream()
            navHistory.filter { sel in
                JotAppWindow.sanitize(sel, advancedEnabled: false) == sel
            }
        }
        // Drop the live CTC rescorer when primary swaps to a model
        // that can't apply it: JA (different tokenizer,
        // `docs/plans/japanese-support.md` §C) or Nemotron-only (the
        // streaming pipeline doesn't expose per-token timings, which
        // the rescorer strictly requires). No idle CoreML resources
        // for a feature that can't apply on the active path. When
        // primary swaps back to a vocab-capable model, re-prepare iff
        // the user's saved master toggle was on — preserves their
        // prior preference without making them retoggle.
        .onChange(of: transcriberHolder.primaryModelID) { _, newValue in
            handlePrimaryModelChange(to: newValue)
        }
    }

    private func handlePrimaryModelChange(to newID: ParakeetModelID) {
        if newID == .tdt_0_6b_ja {
            // Japanese drives vocabulary through alias substitution, not the
            // CTC spotter — tear the spotter down.
            Task { await VocabularyRescorerHolder.shared.unload() }
        } else if VocabularyStore.shared.isEnabled,
                  let url = VocabularyStore.shared.fileURL {
            // v2 / v3 / Nemotron all drive vocabulary through the CTC spotter.
            // (Nemotron used to be unloaded here — that was correct before the
            // no-fork CTC-spotter path existed; now Nemotron must prepare it.)
            Task { try? await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: url) }
        }
    }

    @ViewBuilder
    private var migrationDownloadBanner: some View {
        // Every download/repair state renders through the single shared
        // `ModelDownloadStatusView` (design: docs/plans/model-download-ux-
        // mockup.html) — ONE determinate/indeterminate LINEAR bar, never a
        // circular spinner, and never in the status pill. Priority order: an
        // in-flight self-heal repair is shown first (it defers behind a
        // migration, so the two never fight in practice), then a user-initiated
        // manual/language switch, then the background migration download.
        if let repair = transcriberHolder.repairState {
            ModelDownloadStatusView(
                state: repairStatus(repair),
                style: .banner,
                onRetry: repairRetryAction(for: repair)
            )
        } else if let pending = transcriberHolder.pendingSwitch {
            ModelDownloadStatusView(
                state: pendingSwitchStatus(pending),
                style: .banner,
                onRetry: pendingSwitchRetryAction(for: pending),
                onCancel: { transcriberHolder.cancelPendingSwitch() }
            )
        } else if let progress = transcriberHolder.migrationDownloadProgress {
            ModelDownloadStatusView(
                state: .downloading(
                    title: "Downloading transcription model",
                    meta: "",
                    fraction: progress,
                    subtext: nil
                ),
                style: .banner
            )
        } else if let error = transcriberHolder.migrationDownloadError {
            ModelDownloadStatusView(
                state: .failed(message: "Model download failed. \(error)"),
                style: .banner
            )
        }
    }

    // MARK: - Download/repair status mapping (→ ModelDownloadStatusView.State)

    /// Map the manual/language switch producer onto the shared component. The
    /// user keeps dictating in the active language the whole time (design: the
    /// "Keep dictating in <lang>…" reassurance line).
    private func pendingSwitchStatus(
        _ pending: TranscriberHolder.PendingSwitch
    ) -> ModelDownloadStatusView.State {
        let keepDictating =
            "Keep dictating in \(transcriberHolder.activeLanguage.displayName) — Jot switches over when this finishes."
        switch pending {
        case .downloading(let target, _, let language, let progress):
            let label = switchLanguageLabel(target: target, language: language)
            guard let progress else {
                // Pre-first-byte: indeterminate LINEAR pulse.
                return .working(title: "Downloading \(label)", symbol: .downloading, subtext: keepDictating)
            }
            if progress.phase == .preparing {
                return .working(
                    title: "Preparing the \(label)…",
                    symbol: .preparing,
                    subtext: "Almost ready — optimizing for the Neural Engine."
                )
            }
            return .downloading(
                title: "Downloading \(label)",
                meta: progress.metaLine,
                fraction: progress.fraction,
                subtext: keepDictating
            )
        case .retrying(_, _, _, let error, let nextRetryAt):
            return .retrying(
                message: error.errorDescription ?? "The model download didn’t complete.",
                nextRetryAt: nextRetryAt,
                subtext: "You can keep dictating in \(transcriberHolder.activeLanguage.displayName) meanwhile."
            )
        case .failed(_, _, _, let error):
            return .failed(message: error.errorDescription ?? "The model download didn’t complete.")
        }
    }

    /// "Arabic model" for a language switch; the model display name for a
    /// model-only menu-bar switch (no language attached).
    private func switchLanguageLabel(target: ParakeetModelID, language: LanguageChoice?) -> String {
        if let language { return "\(language.displayName) model" }
        return target.displayName
    }

    /// Retry wiring for the switch producer. `retryPendingSwitch()` re-attempts
    /// without changing the live model.
    private func pendingSwitchRetryAction(
        for pending: TranscriberHolder.PendingSwitch
    ) -> (() -> Void)? {
        switch pending {
        case .downloading:
            return nil
        case .retrying, .failed:
            return { transcriberHolder.retryPendingSwitch() }
        }
    }

    /// Map the self-heal repair producer onto the shared component. `repairState`
    /// carries only a bare `Double?` fraction (no bytes/speed), so the meta line
    /// is empty here — if the integrator upgrades `repairState` to
    /// `ModelDownloadProgress` it would populate exactly like the switch path.
    private func repairStatus(_ repair: TranscriberHolder.RepairState) -> ModelDownloadStatusView.State {
        switch repair {
        case .downloading(let modelName, let progress):
            guard let progress else {
                return .working(title: "Repairing \(modelName)…", symbol: .downloading, subtext: nil)
            }
            return .downloading(title: "Repairing \(modelName)", meta: "", fraction: progress, subtext: nil)
        case .failed(let modelName, _):
            return .failed(message: "Couldn’t finish downloading \(modelName).")
        }
    }

    /// A failed repair retries the ACTIVE model through `runManualRepair`, the
    /// same choke point Settings → General uses.
    private func repairRetryAction(for repair: TranscriberHolder.RepairState) -> (() -> Void)? {
        switch repair {
        case .downloading:
            return nil
        case .failed:
            return { Task { await transcriberHolder.runManualRepair(transcriberHolder.primaryModelID) } }
        }
    }

    // MARK: - Advanced-mode sanitization

    /// Redirect requests for now-hidden panes to `.home` when Advanced is
    /// off. When Advanced is on, behaves as identity. Invoked at the
    /// `\.setSidebarSelection` boundary, the
    /// `.jotWindowSetSidebarSelection` notification handler, the
    /// navigator-driven mirror, the `pendingSelection` init read, and
    /// the runtime flip-off observer — so a deep-link from Help / About /
    /// menu bar / cloud tool-calling never strands the user on an orphan
    /// pane.
    @MainActor
    static func sanitize(
        _ raw: AppSidebarSelection,
        advancedEnabled: Bool
    ) -> AppSidebarSelection {
        // v1.15: the Transcription, Sound, and Prompts panes were folded
        // into General / AI and their enum cases removed, so there is no
        // orphan `.sound`/`.transcription`/`.prompts` selection to
        // redirect here anymore — all former deep-links now construct
        // `.general` / `.ai` directly at the call site.
        // v1.16: Vocabulary is always visible (no longer Advanced-gated),
        // so it is NOT redirected here — only the Ask Jot row remains
        // Advanced-only. The richer in-pane alias editor is gated inside
        // VocabRow, not by hiding the pane.
        guard !advancedEnabled else { return raw }
        switch raw {
        case .askJot:
            return .home
        case .settings(.speakerLabels):
            // Speaker labels is Advanced-only in the sidebar (AppSidebar);
            // redirect any deep-link / stale selection to Home when Advanced
            // is off so the user never lands on a hidden pane.
            return .home
        default:
            return raw
        }
    }

    // MARK: - Detail router

    /// Concrete pane for the current selection. The switch is exhaustive so
    /// adding a case to `AppSidebarSelection` is a compiler-enforced TODO here.
    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomePane(recorder: recorder)
        case .askJot:
            // v1.17: transcript-Q&A Ask Jot (answers over the user's recordings
            // + the app help doc). Store is root-owned so the conversation
            // survives navigation; built in `.task` once the container is ready.
            if let askStore {
                AskRecordingsView(store: askStore) { recordingID in
                    helpNavigator.pendingOpenRecording = recordingID
                    selection = JotAppWindow.sanitize(.home, advancedEnabled: advancedEnabled)
                }
            } else {
                Color.clear
            }
        case .settings(let sub):
            switch sub {
            case .general:       GeneralPane(
                                    audioCapture: audioCapture,
                                    keychain: keychain,
                                    urlSession: urlSession,
                                    appleIntelligence: appleIntelligence,
                                    llmConfiguration: llmConfiguration,
                                    hotkeyRouter: hotkeyRouter
                                )
            case .speakerLabels: SpeakerLabelsPane()
            case .vocabulary:    VocabularyPane()
            case .ai:            RewritePane(
                                    urlSession: urlSession,
                                    appleIntelligence: appleIntelligence
                                )
            case .shortcuts:     ShortcutsPane()
            }
        case .help:
            HelpPane()
        case .about:
            AboutPane()
        }
    }
}

