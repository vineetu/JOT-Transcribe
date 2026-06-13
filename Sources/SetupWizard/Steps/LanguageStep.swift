import SwiftUI

/// Step 3 — pick the language you'll speak; Jot resolves + downloads the
/// right on-device model automatically (design §5.2). Replaces the former
/// model picker.
///
/// The selection is persisted via `TranscriberHolder.setLanguage(_:)`, which
/// owns the no-clobber guard and writes both `jot.transcriptionLanguage` and
/// (for the common path) `jot.defaultModelID`. Settings observes the same
/// holder so wizard and Settings stay in sync.
///
/// The wizard advance gate keys on the RESOLVED primary model alone
/// (`installedModelIDs.contains(primaryModelID)`) — it must NOT assume a
/// preview/EOU companion exists, because Japanese (`.tdt_0_6b_ja`) has none
/// (`supportsStreaming == false`, design §5.5).
struct LanguageStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var holder: TranscriberHolder
    @ObservedObject private var permissions = PermissionsService.shared

    /// True while the resolved model is downloading. Only one in-flight at a
    /// time — `startDownload()` no-ops while another is running.
    @State private var isDownloading: Bool = false
    @State private var downloadProgress: Double = 0
    @State private var downloadError: String?

    // Optional Parakeet CTC 110M boost bundle used by the Vocabulary feature.
    // Kept local to this step — a failure here must NOT block "Continue".
    @State private var boostCached: Bool = false
    @State private var isBoostDownloading: Bool = false
    @State private var boostErrorMessage: String?

    /// The model resolved from the currently-selected language.
    private var resolvedModel: ParakeetModelID {
        holder.activeLanguage.modelID()
    }

    private var isResolvedInstalled: Bool {
        holder.installedModelIDs.contains(resolvedModel)
    }

    private var languageBinding: Binding<LanguageChoice> {
        Binding(
            get: { holder.activeLanguage },
            set: { lang in
                Task {
                    await holder.setLanguage(lang)
                    await MainActor.run {
                        downloadError = nil
                        refresh()
                    }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What language will you speak?")
                    .font(.system(size: 22, weight: .semibold))
                Text("Jot transcribes on-device on the Apple Neural Engine. You can change this anytime in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 12) {
                Picker("Language", selection: languageBinding) {
                    ForEach(LanguageChoice.presentationOrder) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)

                // Size-only hint — model name stays hidden (design §5.2).
                Text(downloadHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                downloadStatus
            }

            Text("Jot picks the on-device model for your language automatically. You can switch languages later from Settings → Transcription.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            boostModelSection

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            holder.refreshInstalled()
            refresh()
            updateChrome()
        }
        .onChange(of: holder.primaryModelID) {
            refresh()
            updateChrome()
        }
        .onChange(of: holder.installedModelIDs) {
            updateChrome()
        }
    }

    private var downloadHint: String {
        let size = sizeText(resolvedModel.approxBytes)
        if isResolvedInstalled {
            return "This language's model is downloaded (\(size)) and runs entirely on the Neural Engine."
        }
        return "Downloads a \(size) model that runs entirely on the Neural Engine."
    }

    @ViewBuilder
    private var downloadStatus: some View {
        if isDownloading {
            HStack(spacing: 8) {
                ProgressView(value: downloadProgress)
                    .frame(width: 160)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if isResolvedInstalled {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Ready")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }
        } else {
            Button("Download") { startDownload() }
                .controlSize(.regular)
        }

        if let downloadError {
            Text(downloadError)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Optional vocabulary-boost bundle. Lives at the bottom as a quiet
    /// secondary action; skipping is fine.
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
            Text("Extra on-device model that lets Jot prefer your own terms — product names, jargon, proper nouns. Needed only if you plan to use Jot's Custom Vocabulary feature. Custom Vocabulary lives behind the Advanced toggle in Settings → General; you can download this model later from there.")
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

    private func refresh() {
        boostCached = CtcModelCache.shared.isCached
    }

    private func updateChrome() {
        // Advance precondition keys on the RESOLVED primary model alone
        // (design §5.5 — no EOU/preview companion assumption). The
        // coordinator's `.model` rule already reads
        // `installedModelIDs.contains(primaryModelID)`.
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
        guard !isDownloading else { return }
        let model = resolvedModel
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
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
                    // Holder owns the canonical `installedModelIDs` set that
                    // `coordinator.canAdvance(from: .model)` reads.
                    holder.refreshInstalled()
                    // Warm the now-installed model so the Test step is ready.
                    Task { try? await holder.transcriber.ensureLoaded() }
                    updateChrome()
                }
            } catch {
                await ErrorLog.shared.error(component: "SetupWizard", message: "Parakeet model download failed", context: ["modelID": model.rawValue, "error": ErrorLog.redactedAppleError(error)])
                await MainActor.run {
                    isDownloading = false
                    downloadError = "Download failed: \(error.localizedDescription)"
                    updateChrome()
                }
            }
        }
    }

    private func sizeText(_ bytes: Int64) -> String {
        if bytes < 1_000_000_000 {
            let mb = Double(bytes) / 1_000_000
            return String(format: "~%.0f MB", mb)
        }
        let gb = Double(bytes) / 1_000_000_000
        return String(format: "~%.2f GB", gb)
    }
}
