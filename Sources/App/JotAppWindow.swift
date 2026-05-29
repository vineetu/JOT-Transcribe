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

    /// Shared chatbot voice-input bridge. Owned at this root so the
    /// `recorder.$state` Combine subscription persists across pane
    /// navigation and the mutual-exclusion with global dictation stays
    /// live the whole time the window is up.
    @State private var voiceInput: ChatbotVoiceInput

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
        _voiceInput = State(initialValue: ChatbotVoiceInput(
            pipeline: pipeline,
            recorder: recorder,
            condenser: .appleIntelligence
        ))
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(
                selection: $selection,
                askJotAvailable: !chatStore.isUnavailable
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
        .safeAreaInset(edge: .top) {
            migrationDownloadBanner
        }
        .onAppear {
            navHistory.bind(selection: $selection)
            transcriberHolder.startPendingMigrationDownloadIfNeeded()
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
        if newID == .tdt_0_6b_ja || newID == .nemotron_en {
            Task { await VocabularyRescorerHolder.shared.unload() }
        } else if VocabularyStore.shared.isEnabled,
                  let url = VocabularyStore.shared.fileURL {
            Task { try? await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: url) }
        }
    }

    @ViewBuilder
    private var migrationDownloadBanner: some View {
        if let progress = transcriberHolder.migrationDownloadProgress {
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text("Downloading transcription model \(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        } else if let error = transcriberHolder.migrationDownloadError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Model download failed: \(error)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
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
        // v1.14: Sound pane was removed from the sidebar entirely.
        // Any persisted/incoming selection pointing at `.sound` is
        // redirected to General so the user never lands on an orphan.
        if case .settings(.sound) = raw {
            return .settings(.general)
        }
        guard !advancedEnabled else { return raw }
        switch raw {
        case .askJot, .settings(.vocabulary):
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
            AskJotView(store: chatStore, voiceInput: voiceInput)
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
            case .transcription: TranscriptionPane()
            case .speakerLabels: SpeakerLabelsPane()
            case .vocabulary:    VocabularyPane()
            case .prompts:       PromptsPane(
                                    urlSession: urlSession,
                                    appleIntelligence: appleIntelligence
                                )
            case .sound:         SoundPane()
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
