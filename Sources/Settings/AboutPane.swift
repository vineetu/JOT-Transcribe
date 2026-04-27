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
    @Environment(\.helpNavigator) private var helpNavigator
    @Environment(\.setSidebarSelection) private var setSidebarSelection
    @EnvironmentObject private var llmConfiguration: LLMConfiguration
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @State private var pendingShareAction: ShareAction?
    @State private var viewerText = ""
    @State private var isShowingLogViewer = false

    /// Whether Apple Intelligence is currently available on this Mac.
    /// Computed once on appearance; the Ask Jot row hides entirely
    /// when unavailable per chatbot spec v5 §10. Refreshed on
    /// `.onAppear` so toggling Apple Intelligence in System Settings
    /// while the About pane is mounted eventually reflects on
    /// re-open.
    @State private var isAskJotAvailable: Bool = AppleIntelligenceClient.isAvailable

    /// Donation state lives here so the "Thanks for donating" line and the
    /// "N months saved" badge update without relaunching the window.
    @ObservedObject private var donationStore = DonationStore.shared

    /// Comparable-tools monthly rate used by `SavingsBadge`. Spec §7.6
    /// pins this at $10/mo; keep it wired to a local constant so there's
    /// one place to update it if competitor pricing shifts.
    private let comparableMonthlyRate = 10

    var body: some View {
        Form {
            identitySection
            updatesSection
            visionSection
            if isAskJotAvailable {
                askJotSection
            }
            donationSection
            privacySection
            troubleshootingSection
            creditSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Re-check availability every time the About pane
            // materializes — lets a user who enabled Apple
            // Intelligence in System Settings see the row on their
            // next visit.
            isAskJotAvailable = AppleIntelligenceClient.isAvailable
        }
        // Using `.sheet(item:)` instead of `.sheet(isPresented:)` with a
        // conditional body: guarantees the sheet is only presented when a
        // non-nil action exists, so the body can never evaluate to empty
        // (which would leave the sheet with no Cancel button and nothing
        // for Esc to latch onto).
        .sheet(item: $pendingShareAction) { action in
            PrivacyScanSheet(
                action: action,
                llmConfiguration: llmConfiguration,
                onProceed: handleShare
            )
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
                ScrollView {
                    Text(viewerText.isEmpty ? "(log is empty)" : viewerText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
            }
            .padding()
            .frame(minWidth: 700, minHeight: 480)
            .onAppear { viewerText = logText(useRedacted: false) }
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

    private var updatesSection: some View {
        Section {
            Button {
                (NSApp.delegate as? AppDelegate)?.services.updaterController.checkForUpdates(nil)
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for Updates…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(versionString)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Check for Updates")
            .accessibilityHint("Checks for a newer version of Jot.")
        }
    }

    // MARK: - Vision

    private var visionSection: some View {
        Section("Vision") {
            Text("To use AI to optimize your natural flow of thought and clearly articulate your ideas — empowering you to think for yourself rather than letting the AI do the thinking for you.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .textSelection(.enabled)
        }
    }

    // MARK: - Ask Jot (chatbot spec v5 §10)

    /// About tab entry point into Ask Jot. Routes to the `.askJot`
    /// sidebar entry and focuses its TextField without pre-filling —
    /// context-free entry, unlike the Basics sparkle icons which
    /// pre-fill a hero-specific question. Hidden when Apple
    /// Intelligence is unavailable (the pane would be disabled).
    private var askJotSection: some View {
        Section {
            Button {
                helpNavigator.focusChatInput = true
                setSidebarSelection(.askJot)
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask Jot")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("Ask about any feature in plain English.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask Jot")
            .accessibilityHint("Opens the Ask Jot chatbot.")
        }
    }

    // MARK: - Donation

    private var donationSection: some View {
        Section("Support") {
            // Honesty constraint (spec §3 + donation-reminder author note):
            // the developer has NOT personally vetted every cause inside the
            // every.org fund, and we don't know the fee split, so we don't
            // claim "100% goes to causes" or "personally vetted" anywhere.
            // The only true, one-sentence claim is that the fund supports
            // education.
            Text("Jot is free. If you'd like to support it, please donate to charity through my every.org fund that supports education instead of paying me.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

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

            // Donation acknowledgment: shown only after the user has
            // clicked a donate link from the Home card or the button
            // above (state transitions to `.donated(Date())`). Quiet
            // one-liner — not a celebration (spec §6.7).
            if case .donated(let date) = donationStore.state {
                DonationAcknowledgment(date: date)
                    .padding(.top, 2)
            }

            // Savings badge: "You've been using Jot for N months — about
            // $X saved vs $10/mo tools." Gated on months >= 1 so day-one
            // users don't see "$0 saved", and on the reminder toggle so
            // opting out hides both the Home card AND this line (one
            // switch, two surfaces — spec §7.6).
            let months = monthsSinceInstall
            if months >= 1 && donationStore.reminderEnabled {
                SavingsBadge(months: months, monthlyRate: comparableMonthlyRate)
                    .padding(.top, 2)
            }
        }
    }

    /// Whole months elapsed since `firstLaunchDate`, rounded DOWN (spec
    /// §7.6 — under-promise). A negative value (clock skew) is clamped
    /// to 0 so a badly-set clock never shows a weird "-3 months".
    private var monthsSinceInstall: Int {
        let comps = Calendar.current.dateComponents(
            [.month],
            from: donationStore.firstLaunchDate,
            to: Date()
        )
        return max(comps.month ?? 0, 0)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Text("Transcription runs entirely on-device. No telemetry, no analytics, no accounts. The only automatic network calls Jot makes are the first-run transcription model download and a daily update check. AI features, when enabled, talk to whichever provider you configure.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .textSelection(.enabled)
        }
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            Text("Errors are logged locally to your Mac. Nothing is sent automatically. If you hit an issue, share the log file manually.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("View log") { isShowingLogViewer = true }
                Button("Copy log") {
                    guard let pb = AppServices.live?.pasteboard else { return }
                    LogSharing.copyToClipboard(logText(useRedacted: false), pasteboard: pb)
                }
                Button("Reveal in Finder") { LogSharing.revealInFinder(ErrorLog.logFileURL) }
                Button("Send via email") { pendingShareAction = .email }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            Text("Send to: jottranscribe@gmail.com")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
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
            guard let pb = AppServices.live?.pasteboard else { return }
            LogSharing.copyToClipboard(text, pasteboard: pb)
        case .reveal:
            LogSharing.revealInFinder(useRedacted ? (LogSharing.writeTemp(text) ?? ErrorLog.logFileURL) : ErrorLog.logFileURL)
        case .email:
            guard let pb = AppServices.live?.pasteboard else { return }
            LogSharing.openEmail(
                logText: text,
                recordingsCount: 0,
                modelIdentifier: transcriberHolder.primaryModelID.rawValue,
                pasteboard: pb
            )
        case .view:
            viewerText = text
            isShowingLogViewer = true
        }
    }

    private func logText(useRedacted: Bool) -> String {
        let raw = (try? String(contentsOf: ErrorLog.logFileURL, encoding: .utf8)) ?? ""
        guard useRedacted else { return raw }
        let config = llmConfiguration
        let keys = LLMConfiguration.bucketedProviders.map { config.apiKey(for: $0) }
        let baseURLs = LLMConfiguration.bucketedProviders.map { config.baseURL(for: $0) }
        let results = PrivacyScanner.scan(
            logContents: raw,
            currentAPIKeys: keys,
            customBaseURLs: baseURLs,
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
