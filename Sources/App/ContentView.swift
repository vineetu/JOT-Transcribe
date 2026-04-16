import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var firstRunState: FirstRunState

    #if DEBUG
    @State private var showSmoke = false
    #endif

    var body: some View {
        #if DEBUG
        ZStack {
            RootView()
            if showSmoke {
                DebugSmokeScreen()
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.opacity)
            }
        }
        .background(
            Button("Toggle smoke", action: { showSmoke.toggle() })
                .keyboardShortcut("d", modifiers: [.command, .control, .option])
                .opacity(0)
                .allowsHitTesting(false)
        )
        #else
        RootView()
        #endif
    }
}

#if DEBUG

private struct DebugSmokeScreen: View {
    @EnvironmentObject private var firstRunState: FirstRunState
    @ObservedObject private var permissions = PermissionsService.shared

    @State private var downloadProgress: Double = 0
    @State private var downloadStatus: DownloadStatus = .idle
    @State private var isDownloading = false

    private enum DownloadStatus: Equatable {
        case idle
        case inProgress
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Debug smoke screen")
                    .font(.title2.bold())
                Text("This panel is DEBUG-only. Press ⌘⌃⌥D to toggle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                firstRunSection
                permissionsSection
                relaunchSection
                modelDownloadSection
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 640)
    }

    // MARK: - First-run row

    private var firstRunSection: some View {
        GroupBox("First run") {
            HStack {
                Text("setupComplete:")
                Text(firstRunState.setupComplete ? "true" : "false")
                    .foregroundStyle(firstRunState.setupComplete ? .green : .orange)
                    .monospaced()
                Spacer()
                Button("Reset first-run") {
                    firstRunState.setupComplete = false
                }
            }
            .padding(6)
        }
    }

    // MARK: - Permissions grid

    private var permissionsSection: some View {
        GroupBox("Permissions") {
            VStack(spacing: 8) {
                ForEach(Capability.allCases, id: \.self) { capability in
                    PermissionRow(
                        capability: capability,
                        status: permissions.statuses[capability] ?? .notDetermined
                    )
                    if capability != Capability.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Relaunch row

    private var relaunchSection: some View {
        GroupBox("Relaunch") {
            HStack {
                Text("Required after Input Monitoring / Accessibility grant.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch app") {
                    RestartHelper.relaunchApp()
                }
            }
            .padding(6)
        }
    }

    // MARK: - Model download row

    private var modelDownloadSection: some View {
        GroupBox("Parakeet model") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(ParakeetModelID.tdt_0_6b_v3.displayName)
                    Spacer()
                    if ModelCache.shared.isCached(.tdt_0_6b_v3) {
                        Text("already cached")
                            .foregroundStyle(.green)
                    }
                }

                ProgressView(value: downloadProgress)

                HStack {
                    Button(isDownloading ? "Downloading…" : "Download Parakeet (tdt_0_6b_v3)") {
                        startDownload()
                    }
                    .disabled(isDownloading)

                    Spacer()

                    statusLabel
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch downloadStatus {
        case .idle:
            EmptyView()
        case .inProgress:
            Text(String(format: "%.0f%%", downloadProgress * 100))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .success:
            Text("Download complete")
                .foregroundStyle(.green)
        case .failure(let message):
            Text("Error: \(message)")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func startDownload() {
        isDownloading = true
        downloadProgress = 0
        downloadStatus = .inProgress

        Task {
            let downloader = ModelDownloader()
            do {
                try await downloader.downloadIfMissing(.tdt_0_6b_v3) { fraction in
                    Task { @MainActor in
                        downloadProgress = fraction
                    }
                }
                await MainActor.run {
                    downloadProgress = 1.0
                    downloadStatus = .success
                    isDownloading = false
                }
            } catch {
                await MainActor.run {
                    downloadStatus = .failure(String(describing: error))
                    isDownloading = false
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let capability: Capability
    let status: PermissionStatus

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(capability.debugDisplayName)
                    .font(.body)
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.debugColor)
                        .frame(width: 8, height: 8)
                    Text(status.debugDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }

            Spacer()

            Button("Request") {
                Task { await PermissionsService.shared.request(capability) }
            }

            if showsSettingsButton {
                Button("Open System Settings") {
                    SystemSettingsLinks.open(for: capability)
                }
            }
        }
    }

    private var showsSettingsButton: Bool {
        switch capability {
        case .inputMonitoring, .accessibilityPostEvents, .accessibilityFullAX:
            return true
        case .microphone:
            return false
        }
    }
}

private extension Capability {
    var debugDisplayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibilityPostEvents: return "Accessibility (post events)"
        case .accessibilityFullAX: return "Accessibility (full AX)"
        }
    }
}

private extension PermissionStatus {
    var debugDisplayName: String {
        switch self {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .granted: return "granted"
        case .requiresRelaunch: return "requiresRelaunch"
        }
    }

    var debugColor: Color {
        switch self {
        case .granted: return .green
        case .requiresRelaunch: return .orange
        case .denied: return .red
        case .notDetermined: return .gray
        }
    }
}

#endif
