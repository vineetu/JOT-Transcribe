import SwiftUI

struct TranscriptionPane: View {
    @EnvironmentObject private var holder: TranscriberHolder
    @EnvironmentObject private var identitiesStore: EnrolledIdentitiesStore
    @AppStorage("jot.autoPaste") private var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") private var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") private var preserveClipboard: Bool = true
    @AppStorage("jot.speakerLabels.enabled") private var speakerLabelsEnabled: Bool = true

    /// v1.14: paste / press-return / keep-clipboard toggles are gated
    /// behind the **global** Advanced features flag in Settings →
    /// General — not behind a per-pane disclosure. When Advanced is off
    /// these knobs are hidden entirely; sensible defaults take over.
    @AppStorage(AdvancedFlag.storageKey)
    private var advancedEnabled: Bool = false

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
            // Language-based selection (design §5.3): the user picks a
            // *language*; Jot resolves the model + recognizer hint
            // automatically. Model identity is surfaced only in About →
            // Acknowledgements, never here.
            Section {
                HStack {
                    Picker("Transcription language", selection: languageBinding) {
                        ForEach(LanguageChoice.presentationOrder) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    InfoPopoverButton(
                        title: "Transcription language",
                        body: "Jot transcribes on-device on the Apple Neural Engine. Pick the language you speak — Jot downloads and loads the right model automatically. You can see exactly which model is in use in About → Acknowledgements.",
                        helpAnchor: "transcription-language"
                    )
                }
                languageModelStatusRow
            } header: {
                Text("Transcription language")
            } footer: {
                Text("Jot picks the on-device model for your language automatically. Each model downloads once and runs on the Apple Neural Engine.")
            }

            // v1.13: gate the card on the same kill switch the sidebar
            // already uses. Without this, the card leaks into Transcription
            // settings and tapping it lands on a pane that has no sidebar
            // entry — a navigation dead-end. When Speaker Labels actually
            // ships, flipping `Features.speakerLabels = true` re-surfaces
            // the card and the sidebar row together.
            if Features.speakerLabels {
                speakerLabelsCard
            }

            // v1.14: when the global Advanced flag is OFF, the
            // paste/clipboard knobs aren't shown at all — defaults
            // (auto-paste on, press-return off, keep-clipboard on)
            // handle the unsurprising case. When the user flips
            // Advanced on from Settings → General, the knobs appear
            // here as plain rows (no per-pane disclosure).
            if advancedEnabled {
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
            }

            Section {
                Button {
                    setSidebarSelection(.settings(.ai))
                } label: {
                    HStack {
                        Text("Cleanup, Rewrite, and other AI transcription features")
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

    /// Two-way binding over the active language. Reads `holder.activeLanguage`;
    /// writes route through `holder.setLanguage(_:)` which owns the no-clobber
    /// guard and the resolved-model download (design §5.4.1).
    private var languageBinding: Binding<LanguageChoice> {
        Binding(
            get: { holder.activeLanguage },
            set: { lang in Task { await holder.setLanguage(lang) } }
        )
    }

    /// Install-state + download/delete + progress for the model the user is
    /// ACTUALLY running (`primaryModelID`, the authoritative active model), not
    /// the one the active language would resolve to. Otherwise a grandfathered
    /// user whose stored model differs from their language's default (e.g. still
    /// on v3+EOU while English now resolves to Nemotron) sees a spurious
    /// "Download required" for a model they never chose, while their real model
    /// is installed and working. Labeled by *language*, not model name (§5.3).
    @ViewBuilder
    private var languageModelStatusRow: some View {
        let model = holder.primaryModelID
        let installed = holder.installedModelIDs.contains(model)
        let state = rowState[model] ?? RowState()

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(languageStatusSubtitle(model: model, installed: installed, state: state))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
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
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Downloaded")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                } else {
                    Button("Download") { startDownload(model) }
                        .controlSize(.small)
                }
            }
            if let error = state.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !installed && !state.isDownloading {
                Text("Download required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func languageStatusSubtitle(
        model: ParakeetModelID,
        installed: Bool,
        state: RowState
    ) -> String {
        let footprint = footprintLabel(for: model)
        if state.isDownloading {
            return "Downloading… · \(footprint)"
        }
        return installed ? "Installed · \(footprint)" : "Not installed · \(footprint)"
    }

    @ViewBuilder
    private var speakerLabelsCard: some View {
        Section {
            Button {
                setSidebarSelection(.settings(.speakerLabels))
            } label: {
                HStack {
                    Image(systemName: "person.wave.2")
                        .font(.system(size: 14))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker labels")
                            .font(.system(size: 13, weight: .medium))
                        Text(speakerLabelsCardSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(speakerLabelsCardActionLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var speakerLabelsCardSubtitle: String {
        if !identitiesStore.hasIdentities {
            return "Not set up — label who said what in meeting recordings."
        }
        let voiceCount = identitiesStore.identities.count
        let voicesText = voiceCount == 1 ? "1 voice" : "\(voiceCount) voices"
        if speakerLabelsEnabled && SortformerHardwareGate.isSupported {
            return "On (\(voicesText))"
        } else {
            return "Off (\(voicesText))"
        }
    }

    private var speakerLabelsCardActionLabel: String {
        identitiesStore.hasIdentities ? "Manage" : "Set up"
    }

    private func footprintLabel(for id: ParakeetModelID) -> String {
        if id.approxBytes < 1_000_000_000 {
            let mb = Double(id.approxBytes) / 1_000_000
            return String(format: "~%.0f MB", mb)
        }
        let gb = Double(id.approxBytes) / 1_000_000_000
        return String(format: "~%.2f GB", gb)
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

    /// Pick a deterministic fallback primary when the active model is
    /// deleted. Prefer the current default if installed; otherwise the
    /// first remaining visible model. Returns nil only when no
    /// other model is installed (caller's `canDelete` already gates this).
    /// Static + internal so regression tests can exercise the algorithm
    /// without a SwiftUI environment.
    static func pickFallbackPrimary(
        excluding: ParakeetModelID,
        installed: Set<ParakeetModelID>
    ) -> ParakeetModelID? {
        let candidates = installed.subtracting([excluding])
        if candidates.contains(.tdt_0_6b_v3_eou_streaming) {
            return .tdt_0_6b_v3_eou_streaming
        }
        return ParakeetModelID.visibleCases.first(where: { candidates.contains($0) })
    }
}
