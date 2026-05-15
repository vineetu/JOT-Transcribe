import AVFoundation
import KeyboardShortcuts
import SwiftUI

/// Step 5 (merged) — "your dictation shortcut" + "try your hotkey" in
/// one page. Shows the current `.toggleRecording` binding, exposes inline
/// controls to pick a single key or chord trigger, and then drives an
/// end-to-end smoke test from the *real* hotkey press.
///
/// Why merged: users were setting a binding on the previous "Shortcuts"
/// step, hitting Continue, and only verifying it on the next "Test"
/// step — which made the relationship between the two pages confusing
/// (especially after the trigger can now be either a single key or chord).
///
/// Why hotkey-driven test (and not an in-app Test button): the button
/// bypasses the global event tap and Input Monitoring permission, so
/// it passes even when the real dictation hotkey would silently fail.
/// Forcing the user to press the actual hotkey here proves three
/// things in one step: the binding is correct, Input Monitoring is
/// granted, and the global tap is firing.
///
/// We commandeer the `.toggleRecording` handler on appear via
/// `HotkeyRouter.setToggleRecordingOverride(...)` and restore the
/// production handler on disappear. This keeps the wizard's test off the
/// real recorder pipeline — no paste, no Library persistence, no chime,
/// no menu-bar icon flicker — while still exercising the entire hotkey
/// stack the production flow depends on.
///
/// Capture + transcription use `coordinator.audioCapture` and
/// `coordinator.transcriber`, the same instances the production
/// recorder shares, so warming the ANE here carries over to the first
/// post-wizard real dictation.
///
/// A 12-second silent timer surfaces a remediation hint if no press
/// arrives — that almost always means Input Monitoring isn't granted
/// or the binding got clobbered.
struct TestStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var holder: TranscriberHolder

    @State private var phase: TestPhase = .waitingForStart
    @State private var transcript: String = ""
    @State private var errorMessage: String?
    @State private var hotkeyDidFire: Bool = false
    @State private var showTimeoutHint: Bool = false
    @State private var timeoutTask: Task<Void, Never>?
    /// Bumped by the inline `KeyboardShortcuts.Recorder`'s onChange so
    /// `shortcutDisplay` re-evaluates after a chord edit. `@AppStorage`
    /// handles the single-key half reactively on its own.
    @State private var bindingsRefreshToken: Int = 0
    /// Read live so the displayed hotkey reflects edits the user may
    /// make in a different Settings window between wizard runs.
    @AppStorage(SingleKey.storageKey) private var toggleSingleKey: SingleKey = .none
    @AppStorage("jot.hotkey.toggleRecording.triggerType") private var toggleTriggerTypeRaw: String = ""

    private var selectedModel: ParakeetModelID {
        holder.primaryModelID
    }

    /// The hotkey shown in the big chip follows the active trigger type.
    private var shortcutDisplay: String {
        _ = bindingsRefreshToken
        _ = toggleSingleKey
        _ = toggleTriggerTypeRaw
        return SingleKeyMigration.effectiveBinding(for: .toggleRecording).displayLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your dictation shortcut")
                    .font(.system(size: 22, weight: .semibold))
                Text("Press your hotkey from any app to start and stop recording. Change it if you want, then test it below.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            bindingControls

            remediationBanner

            hotkeyCard

            if showTimeoutHint && phase == .waitingForStart {
                timeoutHint
            }

            transcriptBlock

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            coordinator.hotkeyRouter?.setToggleRecordingOverride {
                Task { @MainActor in handleHotkeyPress() }
            }
            armTimeoutHintIfNeeded()
            updateChrome()
        }
        .onDisappear {
            coordinator.hotkeyRouter?.clearToggleRecordingOverride()
            timeoutTask?.cancel()
        }
    }

    // MARK: - Binding controls

    /// Inline trigger-type picker plus the active editor for `.toggleRecording`.
    /// Changes here write to `@AppStorage` / `UserDefaults` and
    /// `HotkeyRouter.applySingleKeys()` rebinds on the next
    /// `UserDefaults.didChangeNotification` tick — so the next press
    /// of the new binding fires the wizard's test override correctly.
    @ViewBuilder
    private var bindingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Trigger type", selection: triggerTypeBinding) {
                ForEach(SingleKey.TriggerType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                if triggerType == .singleKey {
                    Picker("", selection: $toggleSingleKey) {
                        Text(SingleKey.none.displayName).tag(SingleKey.none)
                        Divider()
                        ForEach(SingleKey.Action.toggleRecording.pickerCases) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                } else {
                    KeyboardShortcuts.Recorder(for: .toggleRecording) { _ in
                        bindingsRefreshToken &+= 1
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Change anytime in Settings → Shortcuts.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var triggerType: SingleKey.TriggerType {
        _ = toggleTriggerTypeRaw
        return SingleKeyMigration.effectiveTriggerType(for: .toggleRecording)
    }

    private var triggerTypeBinding: Binding<SingleKey.TriggerType> {
        Binding(
            get: { triggerType },
            set: { type in
                SingleKeyMigration.setTriggerType(type, for: .toggleRecording)
                bindingsRefreshToken &+= 1
            }
        )
    }

    // MARK: - Banner

    @ViewBuilder
    private var remediationBanner: some View {
        let mic = PermissionsService.shared.statuses[.microphone] == .granted
        let modelReady = ModelCache.shared.isCached(selectedModel)
        if !mic || !modelReady {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    if !mic {
                        Text("Microphone permission is not granted.")
                            .font(.system(size: 13, weight: .semibold))
                        Button("Go back to Permissions") {
                            coordinator.goTo(.permissions)
                        }
                        .controlSize(.small)
                    } else {
                        Text("Model isn't downloaded yet.")
                            .font(.system(size: 13, weight: .semibold))
                        Button("Go back to Model") {
                            coordinator.goTo(.model)
                        }
                        .controlSize(.small)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
        }
    }

    // MARK: - Hotkey card

    @ViewBuilder
    private var hotkeyCard: some View {
        VStack(spacing: 14) {
            Text(shortcutDisplay)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(hotkeyForeground)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hotkeyBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(hotkeyBorder, lineWidth: 1)
                )

            Text(calloutText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(calloutColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    /// Callout text color tracks phase the same way the chip does —
    /// red while recording so the "stop" instruction reads as the
    /// active concern, otherwise secondary.
    private var calloutColor: Color {
        switch phase {
        case .recording: return .red
        case .transcribing: return .accentColor
        default: return .secondary
        }
    }

    private var hotkeyForeground: Color {
        switch phase {
        case .recording: return .red
        case .transcribing: return .accentColor
        default: return .primary
        }
    }

    private var hotkeyBackground: Color {
        switch phase {
        case .recording: return Color.red.opacity(0.10)
        case .transcribing: return Color.accentColor.opacity(0.08)
        default: return Color.primary.opacity(0.05)
        }
    }

    private var hotkeyBorder: Color {
        switch phase {
        case .recording: return Color.red.opacity(0.45)
        case .transcribing: return Color.accentColor.opacity(0.45)
        default: return Color.primary.opacity(0.10)
        }
    }

    private var calloutText: String {
        switch phase {
        case .waitingForStart:
            return "Press it now to start recording."
        case .recording:
            return "Listening… press the same hotkey to stop."
        case .transcribing:
            return "Transcribing…"
        case .done, .failed:
            return "Press the hotkey again to run another test."
        }
    }

    // MARK: - Timeout hint

    private var timeoutHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Hotkey didn't fire?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Most often this means Input Monitoring isn't granted. Go back to Permissions and make sure Jot is checked in System Settings → Privacy & Security → Input Monitoring (add manually via + → Applications if it's not listed).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Go back to Permissions") {
                    coordinator.goTo(.permissions)
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptBlock: some View {
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
        case .failed:
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

    // MARK: - Timeout hint timer

    private func armTimeoutHintIfNeeded() {
        // Only arm once per appearance — and never after the user has
        // already proven the hotkey works. If the user navigates back
        // and forward, SwiftUI rebuilds the view; `hotkeyDidFire` and
        // `showTimeoutHint` reset with it, which is the right
        // semantics.
        guard !hotkeyDidFire else { return }
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            if !hotkeyDidFire {
                showTimeoutHint = true
            }
        }
    }

    // MARK: - Hotkey handler

    @MainActor
    private func handleHotkeyPress() {
        hotkeyDidFire = true
        showTimeoutHint = false
        timeoutTask?.cancel()
        switch phase {
        case .waitingForStart, .done, .failed:
            startCapture()
        case .recording:
            stopCaptureAndTranscribe()
        case .transcribing:
            // Ignore — transcription is in flight, presses queue badly
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
                let result = try await transcriber.transcribe(recording.samples)
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
