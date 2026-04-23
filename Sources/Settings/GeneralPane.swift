import AVFoundation
import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @AppStorage("jot.inputDeviceUID") private var inputDeviceUID: String = ""
    @AppStorage("jot.retentionDays") private var retentionDays: Int = 7

    // Injected at the root scene in `JotApp.swift` so the "Run Setup Wizard…"
    // button can forward the shared transcriber into the wizard.
    @Environment(\.transcriber) private var transcriber

    /// Donation reminder toggle — master switch for the Home donation
    /// card AND the About "months saved" badge (one switch, two
    /// surfaces). See `docs/research/donation-reminder.md` §7.5.
    @ObservedObject private var donationStore = DonationStore.shared

    @StateObject private var deviceWatcher = InputDeviceWatcher()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginToggleError: String?
    @State private var showSoftAlert = false
    @State private var showHardAlert = false
    @State private var showPermissionsAlert = false
    @State private var showRestartAlert = false
    @State private var softPopover = false
    @State private var hardPopover = false
    @State private var permsPopover = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("Input device")
                    Spacer()
                    Text("System default")
                        .foregroundStyle(.secondary)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Custom input device selection is temporarily disabled — known bug. Jot follows your macOS Sound settings default for now; a fix is coming.")
                }
                Text("Custom device selection is temporarily disabled while we fix a bug — Jot follows your macOS Sound settings default for now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

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
                        helpAnchor: "help.general.launch-at-login"
                    )
                }
                if let loginToggleError {
                    Text(loginToggleError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Section {
                Picker("Keep recordings", selection: $retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Older recordings are deleted automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

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
                    Button("Restart…") { showRestartAlert = true }
                    InfoPopoverButton(
                        title: "Restart Jot",
                        body: "Fixes stuck global shortcuts by relaunching the app. If another app grabbed a hotkey while Jot was off, macOS silently prevents Jot from re-registering it — restarting re-registers cleanly. Your settings and recordings are preserved.",
                        helpAnchor: "help.troubleshooting.hotkey-stuck"
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
                        guard let transcriber else { return }
                        WizardPresenter.present(reason: .manualFromSettings, transcriber: transcriber)
                    }
                    InfoPopoverButton(
                        title: "Run Setup Wizard Again",
                        body: "Relaunches the first-run onboarding flow. Useful if you want to revisit permissions, model download, or hotkey setup. You can walk through each step again without reinstalling Jot.",
                        helpAnchor: "help.general.setup-wizard"
                    )
                }
            }

            Section("Reset") {
                resetRow(
                    kind: .soft,
                    title: "Reset settings…",
                    caption: "Clears your preferences, API keys, and shortcuts. Keeps your recordings.",
                    popover: $softPopover,
                    alert: $showSoftAlert
                )
                resetRow(
                    kind: .hard,
                    title: "Erase all data…",
                    caption: "Removes recordings, the transcription model, and all settings.",
                    popover: $hardPopover,
                    alert: $showHardAlert
                )
                resetRow(
                    kind: .permissions,
                    title: "Reset permissions…",
                    caption: "Re-asks macOS for microphone, input monitoring, and accessibility.",
                    popover: $permsPopover,
                    alert: $showPermissionsAlert
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
        }
        .formStyle(.grouped)
        .alert("Reset settings?", isPresented: $showSoftAlert) {
            Button("Reset and Relaunch", role: .destructive) { ResetActions.softReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears your preferences, API keys, and shortcuts. Your recordings and downloaded model stay. Jot will relaunch into setup.")
        }
        .alert("Erase all Jot data?", isPresented: $showHardAlert) {
            Button("Erase and Relaunch", role: .destructive) { ResetActions.hardReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every recording, the transcription model (≈600 MB, re-downloads on next launch), and all settings. macOS permissions are untouched. Jot will relaunch into setup.")
        }
        .alert("Reset permissions?", isPresented: $showPermissionsAlert) {
            Button("Reset and Relaunch", role: .destructive) { ResetActions.resetPermissions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revokes Jot's microphone, input monitoring, and accessibility grants so macOS re-asks on next launch. Your recordings and settings stay. Jot will relaunch.")
        }
        .alert("Restart Jot?", isPresented: $showRestartAlert) {
            Button("Restart") { RestartHelper.relaunch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jot will quit and reopen, re-registering global shortcuts from scratch. Your settings and recordings are preserved.")
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            // Bug: custom device pinning records from the wrong device.
            // Force system default until fixed.
            inputDeviceUID = ""
        }
    }

    @ViewBuilder
    private func resetRow(
        kind: ResetKind,
        title: String,
        caption: String,
        popover: Binding<Bool>,
        alert: Binding<Bool>
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
                alert.wrappedValue = true
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
}

@MainActor
final class InputDeviceWatcher: ObservableObject {
    @Published var devices: [AVCaptureDevice] = []
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
