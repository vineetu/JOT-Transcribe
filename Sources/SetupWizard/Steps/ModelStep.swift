import SwiftUI

/// Step 3 — pick a Parakeet model and download it if not already cached.
///
/// The selection is persisted to `jot.defaultModelID` (the same AppStorage key
/// the Transcription Settings pane uses) so the wizard and Settings stay in
/// sync. The Settings button on step 6 / day-2 always reads the same key.
struct ModelStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @AppStorage("jot.defaultModelID") private var defaultModelID: String = ParakeetModelID.tdt_0_6b_v3.rawValue

    @State private var cacheByID: [ParakeetModelID: Bool] = [:]
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?

    private var selectedModel: ParakeetModelID {
        ParakeetModelID(rawValue: defaultModelID) ?? .tdt_0_6b_v3
    }

    private var selectedIsCached: Bool {
        cacheByID[selectedModel] ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick a transcription model")
                    .font(.system(size: 22, weight: .semibold))
                Text("Parakeet runs entirely on the Apple Neural Engine. Downloaded once, then used offline.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(ParakeetModelID.allCases, id: \.rawValue) { model in
                    ModelOptionRow(
                        model: model,
                        isSelected: model == selectedModel,
                        isCached: cacheByID[model] ?? false,
                        onSelect: { defaultModelID = model.rawValue }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if selectedIsCached {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Already downloaded.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: downloadProgress)
                        Text("\(Int(downloadProgress * 100))% downloaded")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    HStack(spacing: 10) {
                        Text(sizeLabel(for: selectedModel))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download") { startDownload() }
                            .controlSize(.small)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshCache()
            updateChrome()
        }
        .onChange(of: defaultModelID) {
            refreshCache()
            updateChrome()
        }
    }

    private func sizeLabel(for id: ParakeetModelID) -> String {
        let gb = Double(id.approxBytes) / 1_000_000_000
        return String(format: "Approx. %.2f GB on disk", gb)
    }

    private func refreshCache() {
        var updated: [ParakeetModelID: Bool] = [:]
        for id in ParakeetModelID.allCases {
            updated[id] = ModelCache.shared.isCached(id)
        }
        cacheByID = updated
    }

    private func updateChrome() {
        coordinator.setChrome(WizardStepChrome(
            primaryTitle: "Continue",
            canAdvance: selectedIsCached && !isDownloading,
            isPrimaryBusy: false,
            showsSkip: true
        ))
    }

    private func startDownload() {
        let model = selectedModel
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        updateChrome()

        Task {
            let downloader = ModelDownloader()
            do {
                try await downloader.downloadIfMissing(model) { fraction in
                    Task { @MainActor in downloadProgress = fraction }
                }
                await MainActor.run {
                    isDownloading = false
                    downloadProgress = 1.0
                    refreshCache()
                    updateChrome()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    errorMessage = "Download failed: \(error.localizedDescription)"
                    refreshCache()
                    updateChrome()
                }
            }
        }
    }
}

private struct ModelOptionRow: View {
    let model: ParakeetModelID
    let isSelected: Bool
    let isCached: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        Text(sizeText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if isCached {
                            Text("Downloaded")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sizeText: String {
        let gb = Double(model.approxBytes) / 1_000_000_000
        return String(format: "~%.2f GB", gb)
    }
}
