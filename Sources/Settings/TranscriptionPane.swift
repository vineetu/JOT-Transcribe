import SwiftUI

struct TranscriptionPane: View {
    @AppStorage("jot.defaultModelID") private var defaultModelID: String = ParakeetModelID.tdt_0_6b_v3.rawValue
    @AppStorage("jot.autoPaste") private var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") private var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") private var preserveClipboard: Bool = true

    @State private var isCached: Bool = false
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?

    private var selectedModel: ParakeetModelID {
        ParakeetModelID(rawValue: defaultModelID) ?? .tdt_0_6b_v3
    }

    var body: some View {
        Form {
            Section {
                Picker("Default model", selection: $defaultModelID) {
                    ForEach(ParakeetModelID.allCases, id: \.rawValue) { id in
                        Text(id.displayName).tag(id.rawValue)
                    }
                }
                .onChange(of: defaultModelID) { refreshCacheState() }

                HStack(alignment: .firstTextBaseline) {
                    Text(modelFootprintText(for: selectedModel))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isDownloading {
                        ProgressView(value: downloadProgress)
                            .frame(width: 120)
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else if isCached {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    } else {
                        Button("Download") { startDownload() }
                            .controlSize(.small)
                    }
                }
                if let downloadError {
                    Text(downloadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Automatically paste transcription", isOn: $autoPaste)
                Toggle("Press Return after pasting", isOn: $autoPressEnter)
                    .disabled(!autoPaste)
                if !autoPaste {
                    Text("Requires Automatically paste transcription.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Keep last transcript on clipboard", isOn: Binding(
                    get: { !preserveClipboard },
                    set: { preserveClipboard = !$0 }
                ))
                Text("When off, Jot restores your previous clipboard after pasting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshCacheState() }
    }

    private func refreshCacheState() {
        isCached = ModelCache.shared.isCached(selectedModel)
    }

    private func modelFootprintText(for id: ParakeetModelID) -> String {
        let gb = Double(id.approxBytes) / 1_000_000_000
        return String(format: "Approx. %.2f GB on disk", gb)
    }

    private func startDownload() {
        let model = selectedModel
        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        Task {
            let downloader = ModelDownloader()
            do {
                try await downloader.downloadIfMissing(model) { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                await MainActor.run {
                    isDownloading = false
                    refreshCacheState()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = error.localizedDescription
                    refreshCacheState()
                }
            }
        }
    }
}
