import SwiftUI

struct TranscriptionPane: View {
    @EnvironmentObject private var holder: TranscriberHolder
    @AppStorage("jot.autoPaste") private var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") private var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") private var preserveClipboard: Bool = true

    @Environment(\.setSidebarSelection) private var setSidebarSelection

    /// Per-row download state, keyed by `ParakeetModelID`. Persists across
    /// `holder.refreshInstalled()` calls so an in-flight download keeps its
    /// progress bar even if `installedModelIDs` mutates underneath us
    /// (e.g. another row finishes first).
    @State private var rowState: [ParakeetModelID: RowState] = [:]

    private struct RowState: Equatable {
        var isDownloading: Bool = false
        var progress: Double = 0
        var error: String?
    }

    var body: some View {
        Form {
            Section {
                ForEach(ParakeetModelID.allCases, id: \.rawValue) { model in
                    modelRow(model)
                }
            } header: {
                Text("Speech recognition models")
            } footer: {
                Text("Each model is downloaded once and runs on the Apple Neural Engine. Multiple models can be installed; only the primary is hot in memory.")
            }

            Section {
                HStack {
                    Toggle("Automatically paste transcription", isOn: $autoPaste)
                        .help("Paste the transcript at your cursor via synthetic ⌘V. When off, the transcript is copied to your clipboard instead.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Automatically paste transcription",
                        body: "Paste the transcript at your cursor via synthetic ⌘V. When on: Jot drops the text right where you were typing. When off: the transcript is placed on your clipboard for manual paste.",
                        helpAnchor: "dictation"
                    )
                }
                HStack {
                    Toggle("Press Return after pasting", isOn: $autoPressEnter)
                        .disabled(!autoPaste)
                        .help("Send a Return keystroke after pasting. Useful for chat apps and terminal prompts.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Press Return after pasting",
                        body: "Send a Return keystroke right after the transcript is pasted. When on: chat apps and terminal prompts auto-submit. Requires Automatically paste transcription.",
                        helpAnchor: "dictation"
                    )
                }
                if !autoPaste {
                    Text("Requires Automatically paste transcription.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack {
                    Toggle("Keep last transcript on clipboard", isOn: Binding(
                        get: { !preserveClipboard },
                        set: { preserveClipboard = !$0 }
                    ))
                    .help("Leave the transcript on your clipboard after pasting. When off, Jot restores whatever was on your clipboard before the transcription.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Keep last transcript on clipboard",
                        body: "Leave the transcribed text on your clipboard after pasting. When on: you can ⌘V the transcript again elsewhere. When off: Jot restores whatever you had on the clipboard before recording.",
                        helpAnchor: "dictation"
                    )
                }
                Text("When off, Jot restores your previous clipboard after pasting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                Button {
                    setSidebarSelection(.settings(.ai))
                } label: {
                    HStack {
                        Text("Cleanup, Articulate, and other AI transcription features")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Configured in AI settings.")
            }
        }
        .formStyle(.grouped)
        .onAppear { holder.refreshInstalled() }
    }

    @ViewBuilder
    private func modelRow(_ model: ParakeetModelID) -> some View {
        let installed = holder.installedModelIDs.contains(model)
        let state = rowState[model] ?? RowState()
        let isPrimary = holder.primaryModelID == model

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                // Primary radio. Only meaningful for installed models.
                // When the primary points at a not-installed model the
                // radio is rendered as filled (reflects stored
                // preference) but the row also surfaces the "Download
                // required" hint below — no implicit fetch.
                Button {
                    Task { await holder.setPrimary(model) }
                } label: {
                    Image(systemName: isPrimary ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isPrimary ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!installed)
                .help(installed ? "Make primary" : "Install this model first")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 13, weight: isPrimary ? .semibold : .regular))
                    Text(rowSubtitle(for: model, installed: installed, state: state))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                rowTrailing(model: model, installed: installed, state: state, isPrimary: isPrimary)
            }
            if let error = state.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isPrimary && !installed && !state.isDownloading {
                Text("Download required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func rowTrailing(
        model: ParakeetModelID,
        installed: Bool,
        state: RowState,
        isPrimary: Bool
    ) -> some View {
        if state.isDownloading {
            HStack(spacing: 6) {
                ProgressView(value: state.progress)
                    .frame(width: 100)
                Text("\(Int(state.progress * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if installed {
            Button("Delete") { delete(model) }
                .controlSize(.small)
                .disabled(!canDelete(model))
                .help(canDelete(model)
                      ? "Remove the model files from disk."
                      : "Install another model first; the primary cannot be removed.")
        } else {
            Button("Download") { startDownload(model) }
                .controlSize(.small)
        }
    }

    private func rowSubtitle(
        for model: ParakeetModelID,
        installed: Bool,
        state: RowState
    ) -> String {
        let footprint = footprintLabel(for: model)
        if state.isDownloading {
            return "Downloading… · \(footprint)"
        }
        return installed ? "Installed · \(footprint)" : "Not installed · \(footprint)"
    }

    private func footprintLabel(for id: ParakeetModelID) -> String {
        let gb = Double(id.approxBytes) / 1_000_000_000
        return String(format: "~%.2f GB", gb)
    }

    /// The currently-primary model can be deleted only if at least one
    /// other model is installed (so Jot still has something to fall back
    /// to as primary). Non-primary models are always deletable.
    private func canDelete(_ model: ParakeetModelID) -> Bool {
        if holder.primaryModelID != model { return true }
        return holder.installedModelIDs.contains(where: { $0 != model })
    }

    private func startDownload(_ model: ParakeetModelID) {
        rowState[model] = RowState(isDownloading: true, progress: 0, error: nil)

        Task {
            let downloader = ModelDownloader()
            do {
                try await downloader.downloadIfMissing(model) { fraction in
                    Task { @MainActor in
                        if var s = rowState[model] {
                            s.progress = fraction
                            rowState[model] = s
                        }
                    }
                }
                await MainActor.run {
                    rowState[model] = RowState()
                    holder.refreshInstalled()
                }
            } catch {
                await MainActor.run {
                    rowState[model] = RowState(
                        isDownloading: false,
                        progress: 0,
                        error: error.localizedDescription
                    )
                    holder.refreshInstalled()
                }
            }
        }
    }

    private func delete(_ model: ParakeetModelID) {
        // If the user is deleting the *active* primary, transfer primary
        // to a remaining installed model BEFORE removing the cache.
        // Otherwise `primaryModelID` lingers on a now-uncached model and
        // the next cold transcriber load throws `model-missing`. Order:
        // setPrimary → removeCache → refreshInstalled.
        if holder.primaryModelID == model {
            let fallback = pickFallback(excluding: model)
            guard let fallback else {
                // canDelete already guards this — if no fallback exists
                // the Delete button is disabled. Defensive no-op.
                return
            }
            Task {
                await holder.setPrimary(fallback)
                await MainActor.run {
                    ModelCache.shared.removeCache(for: model)
                    rowState[model] = RowState()
                    holder.refreshInstalled()
                }
            }
            return
        }

        // Reuse the shared cache so the on-disk path matches the
        // downloader's. A `ModelCache(root:)` minted ad-hoc would point
        // at a different directory and silently no-op.
        ModelCache.shared.removeCache(for: model)
        rowState[model] = RowState()
        holder.refreshInstalled()
    }

    private func pickFallback(excluding: ParakeetModelID) -> ParakeetModelID? {
        Self.pickFallbackPrimary(
            excluding: excluding,
            installed: holder.installedModelIDs
        )
    }

    /// Pick a deterministic fallback primary when the active model is
    /// deleted. Prefer v3 if installed; otherwise the first remaining
    /// `ParakeetModelID.allCases` element. Returns nil only when no
    /// other model is installed (caller's `canDelete` already gates this).
    /// Static + internal so regression tests can exercise the algorithm
    /// without a SwiftUI environment.
    static func pickFallbackPrimary(
        excluding: ParakeetModelID,
        installed: Set<ParakeetModelID>
    ) -> ParakeetModelID? {
        let candidates = installed.subtracting([excluding])
        if candidates.contains(.tdt_0_6b_v3) { return .tdt_0_6b_v3 }
        return ParakeetModelID.allCases.first(where: { candidates.contains($0) })
    }
}
