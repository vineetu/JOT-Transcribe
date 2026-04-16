import AVFoundation
import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

struct GeneralPane: View {
    @AppStorage("jot.inputDeviceUID") private var inputDeviceUID: String = ""
    @AppStorage("jot.retentionDays") private var retentionDays: Int = 7

    @StateObject private var deviceWatcher = InputDeviceWatcher()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var loginToggleError: String?
    @State private var showResetPermissionsAlert = false

    var body: some View {
        Form {
            Section {
                Picker("Input device", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(deviceWatcher.devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                Text("Used for all recordings. System default follows macOS Sound settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch Jot at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                .help("Start Jot automatically when you log in to your Mac.")
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
                        WizardPresenter.present(reason: .manualFromSettings)
                    }
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
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
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
