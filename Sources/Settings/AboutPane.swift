import AppKit
import SwiftData
import SwiftUI

/// About pane — identity, vision, donation ask, privacy pledge.
///
/// No automatic network calls: the donation total lives on the web at
/// `jot-donations.ideaflow.page/summary` and opens in the user's browser.
/// Keeps Jot's privacy invariant intact (model download + daily appcast +
/// user-configured LLMs are the only outbound calls from within the app).
struct AboutPane: View {
    @Environment(\.modelContext) private var modelContext
    @State private var pendingShareAction: ShareAction?
    @State private var viewerText = ""
    @State private var isShowingLogViewer = false

    var body: some View {
        Form {
            identitySection
            visionSection
            donationSection
            privacySection
            troubleshootingSection
            creditSection
        }
        .formStyle(.grouped)
        // Using `.sheet(item:)` instead of `.sheet(isPresented:)` with a
        // conditional body: guarantees the sheet is only presented when a
        // non-nil action exists, so the body can never evaluate to empty
        // (which would leave the sheet with no Cancel button and nothing
        // for Esc to latch onto).
        .sheet(item: $pendingShareAction) { action in
            PrivacyScanSheet(action: action, onProceed: handleShare)
        }
        .sheet(isPresented: $isShowingLogViewer) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Error Log").font(.headline)
                    Spacer()
                    Button("Done") { isShowingLogViewer = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.bottom, 10)
                TextEditor(text: $viewerText).font(.system(.body, design: .monospaced))
                    .disabled(true)
            }
            .padding()
            .frame(minWidth: 700, minHeight: 480)
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jot")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Press a hotkey, speak, paste.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(versionString)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    // MARK: - Vision

    private var visionSection: some View {
        Section("Vision") {
            Text("To use AI to optimize your natural flow of thought and clearly articulate your ideas — empowering you to think for yourself rather than letting the AI do the thinking for you.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Donation

    private var donationSection: some View {
        Section("Support") {
            Text("Jot is free. If you'd like to support it, please donate to charity through my every.org fund instead of paying me — 100% goes to causes I've personally vetted.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Link(destination: URL(string: "https://www.every.org/@vineet.sriram")!) {
                    Label("Donate to charity", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Link(destination: URL(string: "https://jot.ideaflow.page/donations")!) {
                    Label("See total raised", systemImage: "chart.bar.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Text("Transcription runs entirely on-device. No telemetry, no analytics, no accounts. The only automatic network calls Jot makes are the first-run transcription model download and a daily update check. AI features, when enabled, talk to whichever provider you configure.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            Text("Errors are logged locally to your Mac. Nothing is sent automatically. If you hit an issue, share the log file manually.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("View log") { viewerText = logText(useRedacted: false); isShowingLogViewer = true }
                Button("Copy log") { pendingShareAction = .copy }
                Button("Reveal in Finder") { pendingShareAction = .reveal }
                Button("Send via email") { pendingShareAction = .email }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            Text("Send to: jottranscribe@gmail.com")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Credit

    private var creditSection: some View {
        Section {
            HStack(spacing: 4) {
                Text("Built by")
                    .foregroundStyle(.secondary)
                Text("Vineet Sriram")
                Spacer()
            }
            .font(.system(size: 11))
        }
    }

    private func handleShare(useRedacted: Bool, action: ShareAction) {
        let text = logText(useRedacted: useRedacted)
        switch action {
        case .copy:
            LogSharing.copyToClipboard(text)
        case .reveal:
            LogSharing.revealInFinder(useRedacted ? (LogSharing.writeTemp(text) ?? ErrorLog.logFileURL) : ErrorLog.logFileURL)
        case .email:
            LogSharing.openEmail(logText: text, recordingsCount: 0)
        case .view:
            viewerText = text
            isShowingLogViewer = true
        }
    }

    private func logText(useRedacted: Bool) -> String {
        let raw = (try? String(contentsOf: ErrorLog.logFileURL, encoding: .utf8)) ?? ""
        guard useRedacted else { return raw }
        let results = PrivacyScanner.scan(
            logContents: raw,
            currentAPIKey: LLMConfiguration.shared.apiKey,
            customBaseURL: UserDefaults.standard.string(forKey: "jot.llm.baseURL"),
            knownTranscripts: recentTranscripts(),
            homeDirectory: NSHomeDirectory()
        )
        return LogRedactor.redact(raw, using: results).text
    }

    private func recentTranscripts() -> [String] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .distantPast
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.createdAt >= cutoff })
        descriptor.fetchLimit = 2000
        guard let recordings = try? modelContext.fetch(descriptor) else { return [] }
        return recordings.flatMap { recording in
            var texts: [String] = []
            if recording.transcript.count >= 10 { texts.append(recording.transcript) }
            if recording.rawTranscript.count >= 10, recording.rawTranscript != recording.transcript {
                texts.append(recording.rawTranscript)
            }
            return texts
        }
    }
}
