import SwiftUI

struct TranscriptionPane: View {
    @AppStorage("jot.defaultModelID") private var defaultModelID: String = ParakeetModelID.tdt_0_6b_v3.rawValue
    @AppStorage("jot.autoPaste") private var autoPaste: Bool = true
    @AppStorage("jot.autoPressEnter") private var autoPressEnter: Bool = false
    @AppStorage("jot.preserveClipboard") private var preserveClipboard: Bool = true

    @ObservedObject private var llmConfig = LLMConfiguration.shared

    @Environment(\.setSidebarSelection) private var setSidebarSelection

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
                HStack {
                    Picker("Default model", selection: $defaultModelID) {
                        ForEach(ParakeetModelID.allCases, id: \.rawValue) { id in
                            Text(id.displayName).tag(id.rawValue)
                        }
                    }
                    .onChange(of: defaultModelID) { refreshCacheState() }
                    InfoPopoverButton(
                        title: "Default model",
                        body: "The Parakeet speech recognition model Jot uses for transcription. Runs entirely on the Apple Neural Engine. When selected: new recordings are transcribed with this model.",
                        helpAnchor: "help.dictation.model"
                    )
                }

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
                HStack {
                    Toggle("Automatically paste transcription", isOn: $autoPaste)
                        .help("Paste the transcript at your cursor via synthetic ⌘V. When off, the transcript is copied to your clipboard instead.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Automatically paste transcription",
                        body: "Paste the transcript at your cursor via synthetic ⌘V. When on: Jot drops the text right where you were typing. When off: the transcript is placed on your clipboard for manual paste.",
                        helpAnchor: "help.dictation.basics"
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
                        helpAnchor: "help.dictation.basics"
                    )
                }
                if !autoPaste {
                    Text("Requires Automatically paste transcription.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Toggle("Clean up transcript with AI", isOn: $llmConfig.transformEnabled)
                        .disabled(!llmConfig.llmVerified)
                        .help("Sends transcript text to your LLM provider to remove filler words and fix grammar. Configure a provider in AI settings.")
                    Spacer()
                    InfoPopoverButton(
                        title: "Clean up transcript with AI",
                        body: "Sends the raw transcript to your configured LLM for light cleanup — filler removal, grammar, list detection — while preserving your voice. When on: every transcript is transformed before delivery.",
                        helpAnchor: "help.transform.overview"
                    )
                }
                if !llmConfig.llmVerified {
                    Text("Set up an LLM in AI settings first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Set up AI →") {
                        setSidebarSelection(.settings(.ai))
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                if llmConfig.llmVerified {
                    CustomizePromptDisclosure(
                        label: "Customize prompt",
                        text: $llmConfig.transformPrompt,
                        defaultValue: TransformPrompt.default,
                        info: .init(
                            title: "Customize prompt",
                            body: "System prompt for Clean up transcript with AI. Tells the LLM how to polish the raw transcript — filler removal, grammar, list detection — while preserving your voice.",
                            helpAnchor: "help.transform.overview"
                        )
                    )
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
                        helpAnchor: "help.dictation.basics"
                    )
                }
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
