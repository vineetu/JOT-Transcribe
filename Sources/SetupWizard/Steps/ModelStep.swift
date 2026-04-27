import SwiftUI

/// Step 3 — pick a Parakeet model and download it if not already cached.
///
/// The selection is persisted via `TranscriberHolder.setPrimary(_:)`,
/// which writes the active id to `UserDefaults` under
/// `TranscriberHolder.defaultsKey`. Settings panes observe the same
/// holder so wizard and Settings stay in sync.
struct ModelStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var holder: TranscriberHolder
    @ObservedObject private var permissions = PermissionsService.shared

    @State private var cacheByID: [ParakeetModelID: Bool] = [:]
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var errorMessage: String?

    // Optional Parakeet CTC 110M boost bundle used by the Vocabulary
    // feature. Kept local to this step — the main transcription pipeline
    // doesn't need it, so a failure here must NOT block "Continue". A
    // user who skips can always download later from Settings → Vocabulary.
    @State private var boostCached: Bool = false
    @State private var isBoostDownloading: Bool = false
    @State private var boostErrorMessage: String?

    private var selectedModel: ParakeetModelID {
        holder.primaryModelID
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
            .textSelection(.enabled)

            VStack(spacing: 8) {
                ForEach(ParakeetModelID.allCases, id: \.rawValue) { model in
                    ModelOptionRow(
                        model: model,
                        isSelected: model == selectedModel,
                        isCached: cacheByID[model] ?? false,
                        onSelect: {
                            Task { await holder.setPrimary(model) }
                        }
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

            Text("Need Japanese? Add it from Settings → Transcription after setup.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            boostModelSection

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshCache()
            updateChrome()
        }
        .onChange(of: holder.primaryModelID) {
            refreshCache()
            updateChrome()
        }
    }

    /// Optional vocabulary-boost bundle. Lives at the bottom of the step
    /// as a quiet secondary action so users who don't need custom vocab
    /// aren't visually burdened. Skipped download is fine — the user
    /// can trigger it any time from Settings → Vocabulary.
    @ViewBuilder
    private var boostModelSection: some View {
        Divider().padding(.vertical, 4)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Vocabulary boost (optional)")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            Text("Extra on-device model that lets Jot prefer your own terms — product names, jargon, proper nouns. Needed only if you plan to use Settings → Vocabulary. You can download it later from that pane.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                if boostCached {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Already downloaded.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else if isBoostDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading ≈100 MB…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("≈100 MB")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Download") { startBoostDownload() }
                        .controlSize(.small)
                }
            }
            if let boostErrorMessage {
                Text(boostErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startBoostDownload() {
        guard !isBoostDownloading else { return }
        isBoostDownloading = true
        boostErrorMessage = nil
        Task {
            do {
                _ = try await CtcModelCache.shared.ensureLoaded()
                await MainActor.run {
                    boostCached = CtcModelCache.shared.isCached
                    isBoostDownloading = false
                }
            } catch {
                await ErrorLog.shared.error(component: "SetupWizard", message: "CTC boost model load failed", context: ["error": ErrorLog.redactedAppleError(error)])
                await MainActor.run {
                    boostErrorMessage = error.localizedDescription
                    isBoostDownloading = false
                }
            }
        }
    }

    private func sizeLabel(for id: ParakeetModelID) -> String {
        let gb = Double(id.approxBytes) / 1_000_000_000
        return String(format: String(localized: "Approx. %.2f GB on disk"), gb)
    }

    private func refreshCache() {
        boostCached = CtcModelCache.shared.isCached
        var updated: [ParakeetModelID: Bool] = [:]
        for id in ParakeetModelID.allCases {
            updated[id] = ModelCache.shared.isCached(id)
        }
        cacheByID = updated
    }

    private func updateChrome() {
        // Phase 3 #31: persistent precondition (model installed) lives
        // on the coordinator; view-only ephemeral state (download in
        // flight) AND-combines on top.
        let state = WizardState(
            permissionGrants: permissions.statuses,
            installedModelIDs: holder.installedModelIDs,
            primaryModelID: holder.primaryModelID
        )
        let persistent = coordinator.canAdvance(from: .model, given: state)
        coordinator.setChrome(WizardStepChrome(
            primaryTitle: "Continue",
            canAdvance: persistent && !isDownloading,
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
                await ErrorLog.shared.error(component: "SetupWizard", message: "Parakeet model download failed", context: ["modelID": model.rawValue, "error": ErrorLog.redactedAppleError(error)])
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
