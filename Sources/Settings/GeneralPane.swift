import AVFoundation
import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @AppStorage("jot.inputDeviceUID") private var inputDeviceUID: String = ""
    /// Cached human-readable name for the saved UID. Populated when the
    /// user selects a device from the picker and read by the
    /// `AudioCapture` fallback path so the "Recorded with system default
    /// — \(savedName) was unavailable." notice can name the missing
    /// device. Empty string when the user is on system default or when
    /// the cache hasn't been populated yet (existing user upgrading;
    /// `AudioCapture.start()` opportunistically backfills).
    @AppStorage("jot.inputDeviceLastName") private var inputDeviceLastName: String = ""
    // Default bumped 7 → 90 in the compressed-history migration. With AAC
    // 16 kbps mono storage (~330 KB/min, vs. WAV's 3.84 MB/min) a 90-day
    // window at typical usage (47 dictations/day × 30 sec avg) lands around
    // ~1.1 GB on disk — comfortable footprint for a desktop app. Existing
    // users keep whatever value they previously set; only fresh installs
    // (and users who never opened Settings → General) pick up the new default.
    @AppStorage("jot.retentionDays") private var retentionDays: Int = 90
    /// "Show Jot in the Dock" — read once at launch in `AppDelegate` via
    /// `dockActivationPolicy(setupComplete:storedShowInDock:)`. Toggling
    /// here writes the value; the change takes effect on next launch.
    @AppStorage("jot.dock.show") private var showInDock: Bool = true
    /// Master toggle for the v1.13 "Advanced" surface (Custom Vocabulary,
    /// Ask Jot chatbot, Push-to-Talk + Paste Last Result rows, About →
    /// Ask Jot section, Help Basics sparkle affordances). Seeded once at
    /// launch by `AdvancedFlag.migrateIfNeeded()` — existing users land
    /// on `true`, fresh installs on `false`. Completing the Setup Wizard
    /// flips this to `true` automatically. Toggling never deletes data;
    /// hidden surfaces preserve their state on disk.
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false

    // ---- Relocated from TranscriptionPane (v1.15 IA collapse) ----
    /// Dictation delivery knobs (advanced-only) — auto-paste, press-return,
    /// keep-clipboard. Moved here from the removed Transcription pane.
    @AppStorage("jot.autoPaste") private var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") private var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") private var preserveClipboard: Bool = true
    @AppStorage("jot.speakerLabels.enabled") private var speakerLabelsEnabled: Bool = true
    /// Semantic-search gate (default ON, opt-out). See `SemanticSearchSettings`.
    @AppStorage(SemanticSearchSettings.enabledKey) private var semanticSearchEnabled: Bool = true

    // ---- Relocated from SoundPane (v1.15 IA collapse) ----
    @AppStorage("jot.sound.recordingStart") private var soundRecordingStart: Bool = true
    @AppStorage("jot.sound.articulateStart") private var soundRewriteStart: Bool = true
    @AppStorage("jot.sound.recordingStop") private var soundRecordingStop: Bool = true
    @AppStorage("jot.sound.recordingCancel") private var soundRecordingCancel: Bool = true
    @AppStorage("jot.sound.transcriptionComplete") private var soundTranscriptionComplete: Bool = true
    @AppStorage("jot.sound.error") private var soundError: Bool = true
    @AppStorage("jot.sound.volume") private var soundVolume: Double = 0.7

    // Injected at the root scene in `JotApp.swift` so the "Run Setup Wizard…"
    // button can forward the shared TranscriberHolder into the wizard.
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    /// Active-language binding + model status row are sourced from the same
    /// holder. Aliased as `holder` to mirror the relocated TranscriptionPane code.
    private var holder: TranscriberHolder { transcriberHolder }
    /// Only used by the (off-by-default) Speaker Labels card relocated from
    /// TranscriptionPane.
    @EnvironmentObject private var identitiesStore: EnrolledIdentitiesStore
    @Environment(\.setSidebarSelection) private var setSidebarSelection

    /// Constructor-injected seams (`audioCapture` and `keychain`) for the
    /// destructive Reset alerts and the Run Setup Wizard button. Pre-fix
    /// these read `AppServices.live?.X` lazily inside action closures, which
    /// silently no-op'd if the live graph wasn't yet attached.
    /// Constructor-injection through `JotAppWindow`'s `.settings(.general)`
    /// route closes the race; same pattern as Phase 4 round 5's
    /// `RewritePane`.
    private let audioCapture: any AudioCapturing
    private let keychain: any KeychainStoring
    /// LLM seams forwarded into `WizardPresenter.present(...)` so the
    /// Cleanup / Rewrite-intro preview demos can resolve a real
    /// `AIService` from coordinator-injected deps. Plumbed in from
    /// `JotAppWindow` (which already holds them for `RewritePane`).
    private let urlSession: URLSession
    private let appleIntelligence: any AppleIntelligenceClienting
    private let llmConfiguration: LLMConfiguration
    /// Forwarded into `WizardPresenter.present(...)` so the wizard's
    /// hotkey-driven `TestStep` can temporarily commandeer
    /// `.toggleRecording` and reinstall the production handler on
    /// disappear. Threaded from `JotAppWindow`.
    private let hotkeyRouter: HotkeyRouter

    init(
        audioCapture: any AudioCapturing,
        keychain injectedKeychain: any KeychainStoring,
        urlSession: URLSession,
        appleIntelligence: any AppleIntelligenceClienting,
        llmConfiguration: LLMConfiguration,
        hotkeyRouter: HotkeyRouter
    ) {
        self.audioCapture = audioCapture
        keychain = injectedKeychain
        self.urlSession = urlSession
        self.appleIntelligence = appleIntelligence
        self.llmConfiguration = llmConfiguration
        self.hotkeyRouter = hotkeyRouter
    }

    /// Donation reminder toggle — master switch for the Home donation
    /// card AND the About "months saved" badge (one switch, two
    /// surfaces). See `docs/research/donation-reminder.md` §7.5.
    @ObservedObject private var donationStore = DonationStore.shared

    @StateObject private var deviceWatcher = InputDeviceWatcher()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginToggleError: String?
    @State private var pendingAlert: ResetAlertKind?
    @State private var softPopover = false
    @State private var hardPopover = false
    @State private var permsPopover = false

    // ---- Relocated from TranscriptionPane: model + semantic download state ----
    /// Per-row download state, keyed by `ParakeetModelID`. Persists across
    /// `holder.refreshInstalled()` calls so an in-flight download keeps its
    /// progress bar.
    @State private var rowState: [ParakeetModelID: RowState] = [:]
    /// Live model-download progress for the semantic-search model (advanced-only).
    @State private var semanticDownload = SemanticDownloadState()

    private struct RowState: Equatable {
        var isDownloading: Bool = false
        var progress: Double = 0
        var error: String?
    }

    private struct SemanticDownloadState: Equatable {
        var isDownloading: Bool = false
        var fraction: Double = 0
        var error: String?
    }

    var body: some View {
        Form {
            Section {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    if !inputDeviceUID.isEmpty,
                       !deviceWatcher.devices.contains(where: { $0.uniqueID == inputDeviceUID }) {
                        Text("Last used (not connected)").tag(inputDeviceUID)
                    }
                    ForEach(deviceWatcher.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                // Cache the device's display name on selection so a
                // future fallback notice can read it even after the
                // device is disconnected.
                .onChange(of: inputDeviceUID) { _, newValue in
                    if newValue.isEmpty {
                        inputDeviceLastName = ""
                    } else if let device = deviceWatcher.devices.first(where: { $0.uniqueID == newValue }) {
                        inputDeviceLastName = device.localizedName
                    }
                }

                // Transcription language + model status (relocated from the
                // removed Transcription pane). v1.16: shown in the same
                // section as Input device, directly beneath it, with no
                // separate "Transcription language" section heading.
                transcriptionLanguageRows
            }

            // Speaker Labels card (off-by-default via Features.speakerLabels).
            if Features.speakerLabels {
                speakerLabelsCard
            }

            if advancedEnabled {
            Section {
                HStack {
                    Toggle("Launch Jot at login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    ))
                    .help("Start Jot automatically when you log in to your Mac.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Launch Jot at login",
                        body: "Start Jot automatically when you log in to your Mac. When on: Jot registers as a login item and reopens in the menu bar each time you sign in.",
                        helpAnchor: "sys-launch-at-login"
                    )
                }
                if let loginToggleError {
                    Text(loginToggleError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                // "Show Jot in the Dock" — applies on next launch. The
                // activation-policy gate in `AppDelegate.applicationDidFinishLaunching`
                // reads `jot.dock.show` once; toggling mid-session does
                // not flip between `.regular` / `.accessory` because the
                // live switch has documented edge cases (window hide on
                // `.accessory`, app-menu reattach quirks). See
                // `docs/plans/hide-dock-icon.md`.
                HStack {
                    Toggle("Show Jot in the Dock", isOn: $showInDock)
                        .help("When off, Jot lives only in the menu bar. Cmd+Tab won't show it. Applies on next launch.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Show Jot in the Dock",
                        body: "When on (default), Jot appears in the Dock and Cmd+Tab. When off, Jot lives only in the menu bar — Cmd+Tab won't show it, and the app menu at the top of the screen is hidden. The menu-bar icon, global hotkeys, and Force Quit (⌥⌘⎋) keep working either way. Changes take effect the next time Jot launches.",
                        helpAnchor: "hide-from-dock"
                    )
                }
                Text("Changes take effect when Jot next launches. When off, Jot lives only in the menu bar; Cmd+Tab won't show it. Force Quit still works.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                // The same `jot.retentionDays` setting now governs both
                // dictation `Recording` rows and `RewriteSession` rows in
                // Home, so the copy is broadened to "library items"
                // rather than the dictation-only "recordings".
                Picker("Keep library items", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Older library items are deleted automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // Dictation delivery knobs (relocated from TranscriptionPane —
            // already advanced-only there, kept advanced-only here).
            dictationDeliverySections

            // Semantic search (relocated from TranscriptionPane). The toggle
            // is default-ON; advanced diagnostics sit beside it.
            semanticSearchSection

            Section("Troubleshooting") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart Jot")
                            .font(.system(size: 13, weight: .regular))
                        Text("Re-register global shortcuts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restart…") { pendingAlert = .restart }
                    InfoPopoverButton(
                        title: "Restart Jot",
                        body: "Fixes stuck global shortcuts by relaunching the app. If another app grabbed a hotkey while Jot was off, macOS silently prevents Jot from re-registering it — restarting re-registers cleanly. Your settings and recordings are preserved.",
                        helpAnchor: "hotkey-stopped-working"
                    )
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run Setup Wizard Again")
                            .font(.system(size: 13, weight: .regular))
                        Text("Walk through permissions, model, and hotkey setup again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run…") {
                        WizardPresenter.present(
                            reason: .manualFromSettings,
                            transcriberHolder: transcriberHolder,
                            audioCapture: audioCapture,
                            urlSession: urlSession,
                            appleIntelligence: appleIntelligence,
                            llmConfiguration: llmConfiguration,
                            hotkeyRouter: hotkeyRouter
                        )
                    }
                    InfoPopoverButton(
                        title: "Run Setup Wizard Again",
                        body: "Relaunches the first-run onboarding flow. Useful if you want to revisit permissions, model download, or hotkey setup. You can walk through each step again without reinstalling Jot.",
                        helpAnchor: "resetting-jot"
                    )
                }
            }


            Section("Reset") {
                resetRow(
                    kind: .soft,
                    title: "Reset settings…",
                    caption: "Clears your preferences, API keys, and shortcuts. Keeps your library items.",
                    popover: $softPopover,
                    pendingAlert: $pendingAlert,
                    alertKind: .soft
                )
                resetRow(
                    kind: .hard,
                    title: "Erase all data…",
                    caption: "Removes all library items, downloaded transcription models, and all settings.",
                    popover: $hardPopover,
                    pendingAlert: $pendingAlert,
                    alertKind: .hard
                )
                resetRow(
                    kind: .permissions,
                    title: "Reset permissions…",
                    caption: "Re-asks for all of Jot's macOS privacy grants.",
                    popover: $permsPopover,
                    pendingAlert: $pendingAlert,
                    alertKind: .permissions
                )
            }

            Section("Reminders") {
                HStack {
                    Toggle(
                        "Show donation reminder and savings estimate",
                        isOn: $donationStore.reminderEnabled
                    )
                    .help("Show the dismissible donation card on Home and the \"months saved\" line in About.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Donation reminder",
                        body: "Jot counts your successful dictations locally to time a single donation nudge on the Home tab, and computes the \"months saved vs comparable tools\" line in About from the day you first launched Jot. Nothing is uploaded — the counters live in your Mac's preferences only. Turn this off to hide both surfaces."
                    )
                }
            }

            // Sound (relocated from the removed Sound pane). v1.16: moved
            // into the Advanced block so chime toggles + volume don't show
            // by default.
            soundSection
            } // end if advancedEnabled

            // Advanced toggle — bottom of General per iOS Settings
            // convention. New users start off; completing the Setup
            // Wizard auto-flips this on. Toggling never deletes data —
            // hidden surfaces preserve their state on disk.
            Section("Advanced") {
                Toggle("Show advanced features", isOn: $advancedEnabled)
                Text("Custom vocabulary, the Ask Jot chatbot, push-to-talk, and other power-user options.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        // Migrated from the legacy `Alert(...primaryButton:secondaryButton:)`
        // API to the modern `.alert(_:isPresented:presenting:actions:message:)`.
        // The legacy form has a documented class of bugs where the destructive
        // button's action closure silently fails to fire — observed behavior
        // matched ours exactly: alert dismisses, NSBeep, no wipe, no relaunch.
        .alert(
            Text(alertTitle(for: pendingAlert)),
            isPresented: Binding(
                get: { pendingAlert != nil },
                set: { if !$0 { pendingAlert = nil } }
            ),
            presenting: pendingAlert
        ) { kind in
            switch kind {
            case .soft:
                Button("Reset and Relaunch", role: .destructive) {
                    ResetActions.softReset(keychain: keychain)
                }
            case .hard:
                Button("Erase and Relaunch", role: .destructive) {
                    ResetActions.hardReset(keychain: keychain)
                }
            case .permissions:
                Button("Reset and Relaunch", role: .destructive) {
                    ResetActions.resetPermissions()
                }
            case .restart:
                Button("Restart") { RestartHelper.relaunch() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            switch kind {
            case .soft:
                Text("Clears your preferences, API keys, and shortcuts. Your library items and downloaded models stay. Jot will relaunch into setup.")
            case .hard:
                Text("Deletes every library item, downloaded transcription models, and all settings. macOS permissions are untouched. Jot will relaunch into setup.")
            case .permissions:
                Text("Revokes all of Jot's macOS privacy grants so macOS re-asks on next launch. Your library items and settings stay. Jot will relaunch.")
            case .restart:
                Text("Jot will quit and reopen, re-registering global shortcuts from scratch. Your settings and library items are preserved.")
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            holder.refreshInstalled()
        }
        .onChange(of: semanticSearchEnabled) { _, isOn in
            // Toggling ON (re-enabling after an opt-out) kicks off the one-time
            // download + a backfill of anything indexed-missing. Toggling OFF is
            // a no-op here — the gate inside the indexer/controller stops all
            // further work; existing chunk rows are harmless and left in place.
            guard isOn else { return }
            Task.detached(priority: .utility) { try? await EmbeddingGemmaService.shared.prewarm() }
            Task(priority: .background) { await RecordingIndexer.shared?.backfillMissing() }
        }
    }

    @ViewBuilder
    private func resetRow(
        kind: ResetKind,
        title: String,
        caption: String,
        popover: Binding<Bool>,
        pendingAlert: Binding<ResetAlertKind?>,
        alertKind: ResetAlertKind
    ) -> some View {
        // Color carries the signal: blue (accent) for recoverable resets,
        // red for the only irreversible action. Matches the iOS Settings
        // "Reset" screen pattern — color alone tells the user "this is
        // tappable" and, separately, "this one is dangerous." No chevron:
        // it would imply navigation, but these open a confirmation alert.
        let isIrreversible = (kind == .hard)
        let titleColor: Color = isIrreversible ? .red : .accentColor
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                pendingAlert.wrappedValue = alertKind
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(titleColor)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                popover.wrappedValue.toggle()
            } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: popover, arrowEdge: .trailing) {
                ResetInfoPopover(kind: kind)
            }
        }
    }

    private func alertTitle(for kind: ResetAlertKind?) -> String {
        switch kind {
        case .soft: return "Reset settings?"
        case .hard: return "Erase all Jot data?"
        case .permissions: return "Reset permissions?"
        case .restart: return "Restart Jot?"
        case .none: return ""
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginToggleError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            loginToggleError = "Couldn't update Login Items: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Transcription language (relocated from TranscriptionPane)

    /// Language-based selection (design §5.3): the user picks a *language*;
    /// Jot resolves the model + recognizer hint automatically. v1.16: emitted
    /// as bare rows (no enclosing `Section` / header) so it renders directly
    /// beneath the Input device picker in the same grouped box.
    @ViewBuilder
    private var transcriptionLanguageRows: some View {
        HStack {
            LabeledContent("Transcription language") {
                LanguagePickerField(selection: languageBinding)
            }
            InfoPopoverButton(
                title: "Transcription language",
                body: "Jot transcribes on-device on the Apple Neural Engine. Pick the language you speak — Jot downloads and loads the right model automatically. You can see exactly which model is in use in About → Acknowledgements.",
                helpAnchor: "transcription-language"
            )
        }
        languageModelStatusRow
    }

    /// Two-way binding over the active language. Reads `holder.activeLanguage`;
    /// writes route through `holder.setLanguage(_:)` which owns the no-clobber
    /// guard and the resolved-model download (design §5.4.1).
    private var languageBinding: Binding<LanguageChoice> {
        Binding(
            get: { holder.activeLanguage },
            set: { lang in Task { await holder.setLanguage(lang) } }
        )
    }

    /// Install-state + download/delete + progress for the model the user is
    /// ACTUALLY running (`primaryModelID`).
    @ViewBuilder
    private var languageModelStatusRow: some View {
        let model = holder.primaryModelID
        let installed = holder.installedModelIDs.contains(model)
        let state = rowState[model] ?? RowState()
        let repair = holder.repairState

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(languageStatusSubtitle(model: model, installed: installed, state: state, repair: repair))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let repair {
                    repairTrailing(repair)
                } else if state.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView(value: state.progress)
                            .frame(width: 100)
                        Text("\(Int(state.progress * 100))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else if installed {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Downloaded")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                } else {
                    Button("Download") { startDownload(model) }
                        .controlSize(.small)
                }
            }
            if let repair, case .failed = repair {
                Text("Couldn’t finish downloading \(repair.modelName). It will retry on next launch, or use Download above.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = state.error, repair == nil {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if repair == nil && !installed && !state.isDownloading {
                Text("Download required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func repairTrailing(_ repair: TranscriberHolder.RepairState) -> some View {
        switch repair {
        case .downloading(_, let progress):
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .failed:
            Button("Retry") { startDownload(holder.primaryModelID) }
                .controlSize(.small)
        }
    }

    private func languageStatusSubtitle(
        model: ParakeetModelID,
        installed: Bool,
        state: RowState,
        repair: TranscriberHolder.RepairState?
    ) -> String {
        let footprint = footprintLabel(for: model)
        if let repair {
            switch repair {
            case .downloading:
                return "Repairing — downloading… · \(footprint)"
            case .failed:
                return "Repair failed · \(footprint)"
            }
        }
        if state.isDownloading {
            return "Downloading… · \(footprint)"
        }
        return installed ? "Installed · \(footprint)" : "Not installed · \(footprint)"
    }

    private func footprintLabel(for id: ParakeetModelID) -> String {
        if id.approxBytes < 1_000_000_000 {
            let mb = Double(id.approxBytes) / 1_000_000
            return String(format: "~%.0f MB", mb)
        }
        let gb = Double(id.approxBytes) / 1_000_000_000
        return String(format: "~%.2f GB", gb)
    }

    private func startDownload(_ model: ParakeetModelID) {
        // The ACTIVE model is the one a self-heal repairs; route its manual
        // download / Retry through `repairState` so a successful retry clears
        // the failure UI everywhere. NON-active models keep the local
        // `rowState` path.
        if model == holder.primaryModelID {
            Task { await holder.runManualRepair(model) }
            return
        }

        rowState[model] = RowState(isDownloading: true, progress: 0, error: nil)

        Task {
            let downloader = ModelDownloader()
            do {
                try await downloader.downloadIfMissing(model) { fraction in
                    Task { @MainActor in
                        if var s = rowState[model] {
                            s.progress = fraction
                            rowState[model] = s
                        }
                    }
                }
                await MainActor.run {
                    rowState[model] = RowState()
                    holder.refreshInstalled()
                }
            } catch {
                await MainActor.run {
                    rowState[model] = RowState(
                        isDownloading: false,
                        progress: 0,
                        error: error.localizedDescription
                    )
                    holder.refreshInstalled()
                }
            }
        }
    }

    /// Pick a deterministic fallback primary when the active model is deleted.
    /// Static + internal so regression tests can exercise the algorithm
    /// without a SwiftUI environment.
    static func pickFallbackPrimary(
        excluding: ParakeetModelID,
        installed: Set<ParakeetModelID>
    ) -> ParakeetModelID? {
        let candidates = installed.subtracting([excluding])
        if candidates.contains(.tdt_0_6b_v3_eou_streaming) {
            return .tdt_0_6b_v3_eou_streaming
        }
        return ParakeetModelID.visibleCases.first(where: { candidates.contains($0) })
    }

    // MARK: - Dictation delivery (relocated from TranscriptionPane, advanced-only)

    @ViewBuilder
    private var dictationDeliverySections: some View {
        Section {
            HStack {
                Toggle("Automatically paste transcription", isOn: $autoPaste)
                    .help("Paste the transcript at your cursor via synthetic ⌘V. When off, the transcript is copied to your clipboard instead.")
                Spacer()
                InfoPopoverButton(
                    title: "Automatically paste transcription",
                    body: "Paste the transcript at your cursor via synthetic ⌘V. When on: Jot drops the text right where you were typing. When off: the transcript is placed on your clipboard for manual paste.",
                    helpAnchor: "dictation"
                )
            }
            HStack {
                Toggle("Press Return after pasting", isOn: $autoPressEnter)
                    .disabled(!autoPaste)
                    .help("Send a Return keystroke after pasting. Useful for chat apps and terminal prompts.")
                Spacer()
                InfoPopoverButton(
                    title: "Press Return after pasting",
                    body: "Send a Return keystroke right after the transcript is pasted. When on: chat apps and terminal prompts auto-submit. Requires Automatically paste transcription.",
                    helpAnchor: "dictation"
                )
            }
            if !autoPaste {
                Text("Requires Automatically paste transcription.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }

        Section {
            HStack {
                Toggle("Keep last transcript on clipboard", isOn: Binding(
                    get: { !preserveClipboard },
                    set: { preserveClipboard = !$0 }
                ))
                .help("Leave the transcript on your clipboard after pasting. When off, Jot restores whatever was on your clipboard before the transcription.")
                Spacer()
                InfoPopoverButton(
                    title: "Keep last transcript on clipboard",
                    body: "Leave the transcribed text on your clipboard after pasting. When on: you can ⌘V the transcript again elsewhere. When off: Jot restores whatever you had on the clipboard before recording.",
                    helpAnchor: "dictation"
                )
            }
            Text("When off, Jot restores your previous clipboard after pasting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Semantic search (relocated from TranscriptionPane)

    @ViewBuilder
    private var semanticSearchSection: some View {
        Section {
            HStack {
                Toggle("Semantic search", isOn: $semanticSearchEnabled)
                InfoPopoverButton(
                    title: "Semantic search",
                    body: "Finds recordings by meaning, not just exact words — searching “rent increase” can surface a recording where you said “the landlord is raising my payment.” It runs fully on-device: enabling it downloads a one-time search model (about 339 MB) and quietly indexes your existing recordings in the background. Exact-text search always works whether this is on or off."
                )
            }
            semanticAdvancedRows
        } header: {
            Text("Semantic search")
        } footer: {
            Text("On-device meaning-based search over your recordings. Downloads a one-time model and indexes in the background; exact-text search works regardless.")
        }
    }

    /// Diagnostics: model download state, live indexing progress, and a
    /// manual rebuild. Already inside the advanced block in General.
    @ViewBuilder
    private var semanticAdvancedRows: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Search model")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if semanticDownload.isDownloading {
                HStack(spacing: 6) {
                    ProgressView(value: semanticDownload.fraction)
                        .frame(width: 100)
                    Text("\(Int(semanticDownload.fraction * 100))%")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if EmbeddingGemmaService.isDownloaded() {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Downloaded").font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
                }
            } else {
                Button("Download") { startSemanticDownload() }
                    .controlSize(.small)
                    .disabled(!semanticSearchEnabled)
            }
        }
        if let error = semanticDownload.error {
            Text(error)
                .font(.system(size: 11)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let indexer = RecordingIndexer.shared, indexer.isSweeping {
            HStack(alignment: .firstTextBaseline) {
                Text("Indexing")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(indexer.sweepDone) of \(indexer.sweepTotal)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }

        HStack {
            Button("Rebuild index") {
                Task { await RecordingIndexer.shared?.rebuildAll() }
            }
            .controlSize(.small)
            .disabled(!semanticSearchEnabled || (RecordingIndexer.shared?.isSweeping ?? false))
            Spacer()
        }
    }

    private func startSemanticDownload() {
        semanticDownload = SemanticDownloadState(isDownloading: true, fraction: 0, error: nil)
        Task {
            do {
                try await EmbeddingGemmaService.shared.prewarm { progress in
                    let frac = progress.bytesTotal > 0
                        ? Double(progress.bytesReceived) / Double(progress.bytesTotal)
                        : 0
                    Task { @MainActor in
                        if semanticDownload.isDownloading {
                            semanticDownload.fraction = min(max(frac, 0), 1)
                        }
                    }
                }
                await MainActor.run { semanticDownload = SemanticDownloadState() }
                Task(priority: .background) { await RecordingIndexer.shared?.backfillMissing() }
            } catch {
                await MainActor.run {
                    semanticDownload = SemanticDownloadState(
                        isDownloading: false, fraction: 0, error: error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Sound (relocated from SoundPane)

    @ViewBuilder
    private var soundSection: some View {
        Section {
            HStack {
                Label("Volume", systemImage: "speaker.wave.1")
                    .labelStyle(.titleOnly)
                Slider(value: $soundVolume, in: 0...1)
                Image(systemName: "speaker.wave.3")
                    .foregroundStyle(.secondary)
                InfoPopoverButton(
                    title: "Chime volume",
                    body: "Controls the loudness of every Jot chime relative to your system output. Applies uniformly to start, stop, cancel, complete, and error sounds.",
                    helpAnchor: "sound-recording-chimes"
                )
            }
            Text("Applies to all Jot chimes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("Sound")
        }

        Section {
            chimeRow("Recording start", isOn: $soundRecordingStart, effect: .recordingStart,
                     help: "Play a chime when recording begins.",
                     popoverBody: "A short chime confirms Jot heard your hotkey. When on: you get audible feedback the moment capture starts, without needing to look at the menu bar.",
                     helpAnchor: "sound-recording-chimes")
            chimeRow("Rewrite start", isOn: $soundRewriteStart, effect: .rewriteStart,
                     help: "Play a chime when a Rewrite with Voice instruction begins.",
                     popoverBody: "A distinct chime — pitch-shifted from the dictation start chime — plays when Rewrite with Voice opens the mic for your voice instruction. When on: you can hear the difference between a dictation session and a Rewrite without looking at the menu bar.",
                     helpAnchor: "sound-recording-chimes")
            chimeRow("Recording stop", isOn: $soundRecordingStop, effect: .recordingStop,
                     help: "Play a chime when recording stops and transcription starts.",
                     popoverBody: "Plays when recording ends and Jot hands off to the transcription model. When on: you know capture finished before transcription latency kicks in.",
                     helpAnchor: "sound-recording-chimes")
            chimeRow("Recording canceled", isOn: $soundRecordingCancel, effect: .recordingCancel,
                     help: "Play a chime when you cancel a recording with Escape.",
                     popoverBody: "A distinct chime that signals Jot dropped the recording. When on: you get clear auditory confirmation that nothing was transcribed or delivered.",
                     helpAnchor: "sound-recording-chimes")
            chimeRow("Transcription complete", isOn: $soundTranscriptionComplete, effect: .transcriptionComplete,
                     help: "Play a chime when the transcript is ready and delivered.",
                     popoverBody: "Plays when the transcript is pasted (or copied, if auto-paste is off). When on: you can look away from the screen and still know delivery succeeded.",
                     helpAnchor: "sound-transcription-complete")
            chimeRow("Error", isOn: $soundError, effect: .error,
                     help: "Play a chime when transcription fails.",
                     popoverBody: "A distinct error chime plays when transcription or delivery fails. When on: failures surface immediately instead of silently dropping.",
                     helpAnchor: "sound-error-chime")
        }
    }

    private func chimeRow(_ label: String, isOn: Binding<Bool>, effect: SoundEffect, help: String, popoverBody: String, helpAnchor: String) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
                .help(help)
            Spacer()
            Button("Test") { SoundPlayer.shared.play(effect) }
                .controlSize(.small)
                .disabled(!isOn.wrappedValue)
            InfoPopoverButton(
                title: label,
                body: popoverBody,
                helpAnchor: helpAnchor
            )
        }
    }

    // MARK: - Speaker Labels card (relocated from TranscriptionPane; off by default)

    @ViewBuilder
    private var speakerLabelsCard: some View {
        Section {
            Button {
                setSidebarSelection(.settings(.speakerLabels))
            } label: {
                HStack {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 14))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker labels")
                            .font(.system(size: 13, weight: .medium))
                        Text(speakerLabelsCardSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(speakerLabelsCardActionLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var speakerLabelsCardSubtitle: String {
        if !identitiesStore.hasIdentities {
            return "Not set up — label who said what in meeting recordings."
        }
        let voiceCount = identitiesStore.identities.count
        let voicesText = voiceCount == 1 ? "1 voice" : "\(voiceCount) voices"
        if speakerLabelsEnabled && SortformerHardwareGate.isSupported {
            return "On (\(voicesText))"
        } else {
            return "Off (\(voicesText))"
        }
    }

    private var speakerLabelsCardActionLabel: String {
        identitiesStore.hasIdentities ? "Manage" : "Set up"
    }
}

private enum ResetAlertKind: Identifiable {
    case soft, hard, permissions, restart
    var id: Self { self }
}

@MainActor
final class InputDeviceWatcher: ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    private var observer: NSObjectProtocol?
    private var disconnectedObserver: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        disconnectedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let disconnectedObserver { NotificationCenter.default.removeObserver(disconnectedObserver) }
    }

    private func refresh() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        devices = session.devices
    }
}
