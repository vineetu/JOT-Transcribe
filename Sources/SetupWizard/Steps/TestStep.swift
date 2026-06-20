import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Step 5 (merged) — "your dictation shortcut" + "try your hotkey" in
/// one page. v1.13 redesign per `docs/wizard-shortcuts-redesign/design.md`:
///
///   • One focal chip is the page's primary affordance (no more
///     segmented "Trigger type" Picker as the first interactive control).
///   • Three quick-pick chips below the chip (Caps Lock, ⌥ Right Option,
///     ⌥ Space) — tap to bind in one click.
///   • "Custom…" toggles a `KeyboardShortcuts.Recorder` inside the focal
///     chip for chord-style bindings.
///   • Input Monitoring missing → proactive top banner from page load
///     (replacing the v1.12 12 s silent-timer remediation hint).
///   • Fresh-install vs upgrader copy diverges so existing users see
///     "let's make sure it still works" instead of "press it now."
///
/// Why merged stays merged: users were setting a binding on the previous
/// "Shortcuts" step, hitting Continue, and only verifying it on the next
/// "Test" step — which made the relationship between the two pages
/// confusing. The 2026-05 redesign keeps the merge but declutters the
/// rendering so the chip can carry the page on its own.
///
/// Why hotkey-driven test (and not an in-app Test button): the button
/// bypasses the global event tap and Input Monitoring permission, so it
/// passes even when the real dictation hotkey would silently fail.
/// Forcing the user to press the actual hotkey here proves three things
/// in one step: the binding is correct, Input Monitoring is granted, and
/// the global tap is firing.
///
/// We commandeer the `.toggleRecording` handler on appear via
/// `HotkeyRouter.setToggleRecordingOverride(...)` and restore the
/// production handler on disappear. This keeps the wizard's test off the
/// real recorder pipeline — no paste, no Library persistence, no chime,
/// no menu-bar icon flicker — while still exercising the entire hotkey
/// stack the production flow depends on.
///
/// Capture + transcription use `coordinator.audioCapture` and
/// `coordinator.transcriber`, the same instances the production recorder
/// shares, so warming the ANE here carries over to the first
/// post-wizard real dictation.
struct TestStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var holder: TranscriberHolder
    @ObservedObject private var permissions = PermissionsService.shared

    @State private var phase: TestPhase = .waitingForStart
    @State private var transcript: String = ""
    @State private var errorMessage: String?
    /// True while the user has the chord recorder open inside the focal
    /// chip. The quick-pick strip's "Custom…" toggles this.
    @State private var isEditingBinding: Bool = false
    /// Bumped by the inline `KeyboardShortcuts.Recorder` so any computed
    /// view of `effectiveBinding(...)` re-evaluates after a chord commit.
    /// `@AppStorage` handles the single-key half reactively on its own.
    @State private var bindingsRefreshToken: Int = 0
    /// Set once on appear so the header copy doesn't flip between fresh
    /// and upgrader framings if the user changes their binding mid-flow.
    @State private var isUpgrader: Bool = false

    @AppStorage(SingleKey.storageKey) private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""

    private var selectedModel: ParakeetModelID {
        holder.primaryModelID
    }

    /// The hotkey shown in the focal chip follows the active trigger type.
    private var shortcutDisplay: String {
        _ = bindingsRefreshToken
        _ = toggleSingleKey
        _ = toggleTriggerTypeRaw
        return SingleKeyMigration.effectiveBinding(for: .toggleRecording).displayLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            // Banners stack above the chip — the chip stays the focal point.
            inputMonitoringBanner
            remediationBanner

            // Focal chip + quick-pick strip + the test-result chrome below.
            VStack(spacing: 14) {
                WizardShortcutChip(
                    label: shortcutDisplay,
                    phase: chipPhase,
                    recorderName: .toggleRecording,
                    onRecorderChange: {
                        bindingsRefreshToken &+= 1
                        // Committing a chord through the recorder closes
                        // the editing state — same semantics as
                        // Apple-shipped recorders.
                        isEditingBinding = false
                    }
                )

                if !isEditingBinding {
                    calloutCopy
                }

                WizardAlternativesStrip(
                    activeSingleKey: effectiveSingleKey,
                    isCustomActive: isEditingBinding,
                    onPickSingleKey: applySingleKey,
                    onToggleCustom: toggleCustomRecorder
                )
                .disabled(phase == .recording || phase == .transcribing)
                .opacity((phase == .recording || phase == .transcribing) ? 0.35 : 1.0)
            }

            // Caps Lock LED education (only when the active binding IS
            // Caps Lock, and only while idle — too noisy mid-test).
            if shouldShowCapsLockCallout {
                capsLockCallout
            }

            // Live-test result chrome (transcript, success, failure).
            testResultBlock

            Spacer(minLength: 0)

            footerTip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            isUpgrader = computeIsUpgrader()
            coordinator.hotkeyRouter?.setToggleRecordingOverride {
                Task { @MainActor in handleHotkeyPress() }
            }
            updateChrome()
        }
        .onDisappear {
            coordinator.hotkeyRouter?.clearToggleRecordingOverride()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 22, weight: .semibold))
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }

    private var headerTitle: String {
        isUpgrader ? "Try your dictation shortcut" : "Your dictation shortcut"
    }

    private var headerSubtitle: String {
        if isUpgrader {
            return "Looks like you've already got a hotkey — let's make sure it still works."
        }
        return "Press your shortcut from any app to start and stop recording. Tap a chip to change it."
    }

    /// Owner is treated as an "upgrader" for header-copy purposes when
    /// the v1.12+ setup-complete flag is set OR when they've already
    /// moved away from the fresh-install default (single-key Caps Lock).
    /// The signal is conservative: any deviation from the freshly-migrated
    /// state shows the upgrader framing.
    private func computeIsUpgrader() -> Bool {
        if FirstRunState.shared.setupComplete { return true }
        let binding = SingleKeyMigration.effectiveBinding(for: .toggleRecording)
        switch binding.triggerType {
        case .singleKey:
            return binding.singleKey != .capsLock && binding.singleKey != .none
        case .chord:
            return true
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var inputMonitoringBanner: some View {
        let status = permissions.statuses[.inputMonitoring] ?? .notDetermined
        if status != .granted {
            WizardPermissionBanner(
                variant: .inputMonitoring(needsRelaunch: status == .requiresRelaunch),
                onGoBackToPermissions: { coordinator.goTo(.permissions) },
                onGoBackToModel: { coordinator.goTo(.model) },
                onOpenSystemSettings: { SystemSettingsLinks.open(for: .inputMonitoring) },
                onRestart: { RestartHelper.relaunch() }
            )
        }
    }

    @ViewBuilder
    private var remediationBanner: some View {
        let mic = PermissionsService.shared.statuses[.microphone] == .granted
        let modelReady = ModelCache.shared.isCached(selectedModel)
        if !mic {
            WizardPermissionBanner(
                variant: .microphone,
                onGoBackToPermissions: { coordinator.goTo(.permissions) },
                onGoBackToModel: { coordinator.goTo(.model) },
                onOpenSystemSettings: { SystemSettingsLinks.open(for: .microphone) },
                onRestart: { RestartHelper.relaunch() }
            )
        } else if !modelReady {
            WizardPermissionBanner(
                variant: .modelNotDownloaded,
                onGoBackToPermissions: { coordinator.goTo(.permissions) },
                onGoBackToModel: { coordinator.goTo(.model) },
                onOpenSystemSettings: {},
                onRestart: {}
            )
        }
    }

    // MARK: - Callouts

    @ViewBuilder
    private var calloutCopy: some View {
        Text(calloutText)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(calloutColor)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var calloutText: String {
        if !isInputMonitoringGranted {
            return "Pressing your hotkey now won't work — grant Input Monitoring above."
        }
        switch phase {
        case .waitingForStart:
            return "Press it now to start recording."
        case .recording:
            return "Listening… press it again to stop."
        case .transcribing:
            return "Transcribing…"
        case .done, .failed:
            return "Press the hotkey again to run another test."
        }
    }

    private var calloutColor: Color {
        if !isInputMonitoringGranted { return .secondary }
        switch phase {
        case .recording:    return .red
        case .transcribing: return .accentColor
        default:            return .secondary
        }
    }

    private var shouldShowCapsLockCallout: Bool {
        let binding = SingleKeyMigration.effectiveBinding(for: .toggleRecording)
        guard binding.triggerType == .singleKey, binding.singleKey == .capsLock else {
            return false
        }
        // Only educate while idle. Mid-test the chip + callout copy carry
        // the moment-to-moment messaging.
        return phase == .waitingForStart && !isEditingBinding
    }

    @ViewBuilder
    private var capsLockCallout: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text("Pressing Caps Lock now will start Jot — your keyboard's Caps Lock light becomes your recording indicator while it's on.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    @ViewBuilder
    private var footerTip: some View {
        HStack(spacing: 6) {
            Text("Tip:")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("Press Esc to cancel a recording at any time.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text("Change anytime in Settings → Shortcuts.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Test result block

    @ViewBuilder
    private var testResultBlock: some View {
        switch phase {
        case .waitingForStart, .recording:
            EmptyView()
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .done:
            doneBlock
        case .failed:
            failedBlock
        }
    }

    @ViewBuilder
    private var doneBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if transcript.isEmpty {
                Text("Didn't catch anything — try again and speak a little louder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                    Text("Your hotkey, mic, and model all work.")
                        .font(.system(size: 13, weight: .medium))
                }
                Text("YOU SAID")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                Text(transcript)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    )
            }
        }
    }

    @ViewBuilder
    private var failedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let errorMessage {
                    Text(verbatim: errorMessage)
                } else {
                    Text("Test failed.")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Chip phase mapping

    /// The focal chip's visual state. Editing wins over everything else
    /// so the recorder is visible regardless of where the test pipeline
    /// happens to be — though in practice we disable the quick-pick
    /// strip during recording/transcribing so the user can't enter
    /// editing mid-test.
    private var chipPhase: WizardShortcutChip.Phase {
        if isEditingBinding { return .editing }
        if !isInputMonitoringGranted { return .disabled }
        switch phase {
        case .waitingForStart: return .idle
        case .recording:       return .recording
        case .transcribing:    return .transcribing
        case .done:            return transcript.isEmpty ? .failed : .passed
        case .failed:          return .failed
        }
    }

    private var isInputMonitoringGranted: Bool {
        (permissions.statuses[.inputMonitoring] ?? .notDetermined) == .granted
    }

    private var effectiveSingleKey: SingleKey {
        let binding = SingleKeyMigration.effectiveBinding(for: .toggleRecording)
        return binding.triggerType == .singleKey ? binding.singleKey : .none
    }

    // MARK: - Binding writes

    /// Apply a quick-pick single key. Switches trigger type to
    /// `.singleKey` (which clears the chord storage in
    /// `SingleKeyMigration`) and writes the new single key. The
    /// `HotkeyRouter`'s UserDefaults observer rebinds within the same
    /// runloop tick.
    private func applySingleKey(_ key: SingleKey) {
        SingleKeyMigration.setTriggerType(.singleKey, for: .toggleRecording)
        UserDefaults.standard.set(key.rawValue, forKey: SingleKey.Action.toggleRecording.storageKey)
        bindingsRefreshToken &+= 1
        isEditingBinding = false
    }

    private func toggleCustomRecorder() {
        // Opening the custom recorder leaves storage untouched until the
        // recorder commits or is dismissed. Closing without a commit
        // simply returns the chip to its previous (still-active) binding.
        isEditingBinding.toggle()
    }

    // MARK: - Coordinator chrome

    private func updateChrome() {
        coordinator.setChrome(WizardStepChrome(
            primaryTitle: "Continue",
            canAdvance: true,
            isPrimaryBusy: false,
            showsSkip: false
        ))
    }

    // MARK: - Hotkey handler

    @MainActor
    private func handleHotkeyPress() {
        // If the user is mid-edit (custom recorder open) the recorder
        // owns the keyboard — production override doesn't fire because
        // the trigger isn't yet bound at the system level. This branch is
        // just defence in depth.
        guard !isEditingBinding else { return }
        switch phase {
        case .waitingForStart, .done, .failed:
            startCapture()
        case .recording:
            stopCaptureAndTranscribe()
        case .transcribing:
            // Ignore — transcription is in flight, presses queue badly.
            break
        }
    }

    // MARK: - Capture / transcribe (wizard-owned, no delivery)

    private func startCapture() {
        transcript = ""
        errorMessage = nil
        phase = .recording

        let transcriber = coordinator.transcriber
        let capture = coordinator.audioCapture
        Task { @MainActor in
            do {
                try await transcriber.ensureLoaded()
                try await capture.start()
            } catch {
                await ErrorLog.shared.error(
                    component: "SetupWizard",
                    message: "Wizard hotkey-test capture start failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
                errorMessage = "Couldn't start recording: \(error.localizedDescription)"
                phase = .failed
            }
        }
    }

    private func stopCaptureAndTranscribe() {
        let transcriber = coordinator.transcriber
        let capture = coordinator.audioCapture
        Task { @MainActor in
            do {
                let recording = try await capture.stop()
                phase = .transcribing
                let result = try await transcriber.transcribe(recording.samples, recordsProvenance: false)
                transcript = result.text
                coordinator.testTranscript = result.text
                phase = .done
            } catch {
                await ErrorLog.shared.error(
                    component: "SetupWizard",
                    message: "Wizard hotkey-test stop/transcribe failed",
                    context: ["error": ErrorLog.redactedAppleError(error)]
                )
                errorMessage = "Test failed: \(error.localizedDescription)"
                phase = .failed
            }
        }
    }
}

fileprivate enum TestPhase: Equatable {
    case waitingForStart
    case recording
    case transcribing
    case done
    case failed
}
