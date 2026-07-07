import SwiftUI

/// Speaker labels: Settings sidebar pane for the offline VBx diarization
/// feature (`docs/speaker-diarization/design.md`).
///
/// This is configuration, NOT a master switch (design decision — see the
/// design doc's "Settings & discoverability" section): offline VBx has no
/// background cost. It only runs when the user taps "Detect speakers" in a
/// recording's detail view, for a fraction of a second, then goes fully
/// idle. There is nothing to toggle off, so this pane is just: a short
/// explainer, the one-time model download state, and the model's
/// attribution line. Owner auto-ID (recognizing "your" voice and labeling
/// it automatically) was removed — its match threshold lived in an
/// uncalibrated metric space and never reliably fired. Every speaker now
/// renders as anonymous "Speaker 1" / "Speaker 2" / … and is renamed
/// manually, per-recording, from a recording's detail view.
struct SpeakerLabelsPane: View {
    @EnvironmentObject private var diarizerHolder: DiarizerHolder

    /// Auto-diarize imported files (docs/auto-diarize-imports/design.md),
    /// default ON — same storage key `FileTranscriptionIngest` reads via
    /// plain `UserDefaults` (it's a non-View `ObservableObject`, so it can't
    /// use `@AppStorage` itself).
    @AppStorage("jot.diarize.autoDetectOnImport") private var autoDiarizeImports: Bool = true

    var body: some View {
        Form {
            headerSection
            downloadStatusSection
            autoDetectSection
            attributionSection
        }
        .formStyle(.grouped)
        .onAppear {
            diarizerHolder.refreshCachedStateIfNeeded()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Speaker labels")
                        .font(.headline)
                    ExperimentalBadge()
                }
                Text("Open a recording and tap \"Detect speakers\" to label who said what — each voice gets an anonymous \"Speaker 1\", \"Speaker 2\", etc., which you can rename directly in the transcript. Best for meeting & call recordings where each person is on clean, separate audio, entirely on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var downloadStatusSection: some View {
        switch diarizerHolder.state {
        case .notDownloaded:
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker-recognition model")
                            .font(.system(size: 13))
                        Text("About 22 MB. Downloads once, the first time you use speaker labels.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Download") {
                        Task { try? await diarizerHolder.prepareIfNeeded() }
                    }
                    .controlSize(.small)
                }
            }
        case .downloading(let progress):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading speaker-recognition model…")
                        .font(.system(size: 12, weight: .medium))
                    ProgressView(value: progress)
                }
            }
        case .failed(let message):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Download failed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { try? await diarizerHolder.prepareIfNeeded() }
                    }
                    .controlSize(.small)
                }
            }
        case .ready, .downloadedNotLoaded:
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Speaker-recognition model downloaded")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var autoDetectSection: some View {
        Section {
            Toggle("Detect speakers automatically on imported files", isOn: $autoDiarizeImports)
                .font(.system(size: 13))
            Text("When you import an audio or video file, Jot labels who said what right after transcribing it — no need to tap \"Detect speakers\" yourself. Turn this off to only detect speakers manually, per recording.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var attributionSection: some View {
        Section {
            Text("Speaker recognition uses the pyannote community-1 model (CC-BY-4.0), running entirely on this Mac. Voice data never leaves your device.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
