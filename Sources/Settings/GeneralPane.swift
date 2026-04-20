import AVFoundation
import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @AppStorage("jot.inputDeviceUID") private var inputDeviceUID: String = ""
    @AppStorage("jot.retentionDays") private var retentionDays: Int = 7

    // Already injected at the root scene in `JotApp.swift` — consumed here so
    // the "Run Setup Wizard…" button can forward the recorder's long-lived
    // Transcriber into the wizard (shared-instance refactor).
    @EnvironmentObject private var recorder: RecorderController

    @StateObject private var deviceWatcher = InputDeviceWatcher()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginToggleError: String?
    @State private var showResetPermissionsAlert = false

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
            }

            Section {
                HStack {
                    Button("Run Setup Wizard…") {
                        WizardPresenter.present(
                            reason: .manualFromSettings,
                            transcriber: recorder.transcriber
                        )
                    }
                    InfoPopoverButton(
                        title: "Run Setup Wizard",
                        body: "Relaunches the first-run onboarding flow. Useful if you want to revisit permissions, model download, or hotkey setup. When on: you can walk through each step again without reinstalling Jot.",
                        helpAnchor: "help.general.setup-wizard"
                    )
                    Spacer()
                    Button(role: .destructive) {
                        showResetPermissionsAlert = true
                    } label: {
                        Text("Reset permissions…")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset permissions?", isPresented: $showResetPermissionsAlert) {
            Button("Reset and Relaunch", role: .destructive, action: resetPermissions)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes Microphone, Input Monitoring, and Accessibility for Jot, then relaunches the app. You will be prompted again.")
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            // Bug: custom device pinning records from the wrong device.
            // Force system default until fixed.
            inputDeviceUID = ""
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

    private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jot.Jot"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "All", bundleID]
        try? task.run()
        task.waitUntilExit()
        RestartHelper.relaunchApp()
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
