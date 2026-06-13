import AppKit
import SwiftData
import SwiftUI

/// About pane — identity, vision, donation ask, privacy pledge.
///
/// One opt-in HTTPS GET on appear: `jot-donations.ideaflow.page/summary`
/// for the inline "$X raised across N donations" caption. No auth, no
/// device identifier, totals only — same endpoint `DonationsView` uses
/// and shares the `@AppStorage` cache so the second visit paints from
/// cache instantly while a refresh runs in the background.
struct AboutPane: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.helpNavigator) private var helpNavigator
    @Environment(\.setSidebarSelection) private var setSidebarSelection
    @EnvironmentObject private var llmConfiguration: LLMConfiguration
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @State private var viewerText = ""
    @State private var isShowingLogViewer = false
    /// Drives the in-app Donations page sheet. Replaces the prior
    /// `Link` to `jot.ideaflow.page/donations` — donations now
    /// browse in-app and only the actual donate step opens
    /// every.org in the system browser.
    @State private var isShowingDonations = false
    /// Drives the in-app feedback composer sheet. Non-nil =
    /// a pre-computed (redacted + raw) log footer is being passed
    /// into the composer to be sent inline with the user's
    /// message. Computed lazily on button press so a fresh log
    /// file is read each time the user opens the sheet.
    @State private var pendingFeedback: FeedbackContext?

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

    /// v1.13: master toggle for the Advanced surface. When off, the
    /// Ask Jot section is hidden so the About pane mirrors the sidebar
    /// — no orphan entry points into a pane that's not in the sidebar.
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false

    /// Cached `/summary` payload — shared with `DonationsView` via the
    /// same `@AppStorage` key so a fetch in either surface warms both.
    @AppStorage("jot.donations.lastSummary") private var cachedSummaryData: Data = Data()

    /// Latest fetched totals. Hydrated from cache on appear for a fast
    /// first paint, then refreshed from the server.
    @State private var donationsSummary: DonationsSummary?

    /// Comparable-tools monthly rate used by `SavingsBadge`. Spec §7.6
    /// pins this at $10/mo; keep it wired to a local constant so there's
    /// one place to update it if competitor pricing shifts.
    private let comparableMonthlyRate = 10

    var body: some View {
        Form {
            identitySection
            updatesSection
            visionSection
            if advancedEnabled && isAskJotAvailable {
                askJotSection
            }
            donationSection
            feedbackSection
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
            // Surface the cached `/summary` payload immediately so the
            // "raised so far" caption paints without a network round-trip,
            // then kick off a refresh in the background.
            if donationsSummary == nil {
                donationsSummary = DonationsService.decodeCachedSummary(from: cachedSummaryData)
            }
            Task { await refreshDonationsSummary() }
        }
        // In-app Donations page. Replaces the old `Link` that took
        // the user out to the website.
        .sheet(isPresented: $isShowingDonations) {
            DonationsView()
        }
        // Feedback composer — always pre-filled with the redacted
        // log + app-details block and an in-sheet toggle to swap to
        // the original log. Driven by a `.sheet(item:)` because the
        // binding carries the (redacted + raw) footers — `Bool`
        // wouldn't carry that payload.
        .sheet(item: $pendingFeedback) { context in
            FeedbackSheet(context: context)
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
            Text("Jot is free. If you'd like to support it, please donate to one of the charities I support instead of paying me.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button {
                    isShowingDonations = true
                } label: {
                    Label("Donate to charity", systemImage: "heart.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Spacer()
            }
            .padding(.vertical, 2)

            if let caption = raisedCaption() {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

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

    /// One-line caption rendered under the Donate button. Returns nil
    /// (no caption row at all) when totals haven't loaded yet or when
    /// the server reports zero donations — better to omit than to
    /// render "$0 raised across 0 donations" on a fresh fetch.
    private func raisedCaption() -> String? {
        guard let summary = donationsSummary, summary.totalDonations > 0 else { return nil }
        let amount = summary.totalRaisedUSD.formatted(
            .currency(code: "USD").precision(.fractionLength(0))
        )
        let count = summary.totalDonations
        return "\(amount) raised across \(count) donation\(count == 1 ? "" : "s")"
    }

    /// Fetch the latest totals from the donations server and persist
    /// to the shared `@AppStorage` cache. Silent on failure — About is
    /// not a place for network-error toasts.
    @MainActor
    private func refreshDonationsSummary() async {
        do {
            let fetched = try await DonationsService.fetchSummary()
            donationsSummary = fetched
            if let data = DonationsService.encodeForCache(fetched) {
                cachedSummaryData = data
            }
        } catch {
            // Intentionally silent — fall back to cached value, or no caption.
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

    // MARK: - Feedback

    /// Lightweight, in-app feedback composer. Posts a plain message
    /// (no log file, no attachments) to the `jot-donations` API.
    /// Separate from the Troubleshooting bug-report flow further
    /// down — that one carries the log file via mailto, this one is
    /// for "thoughts, suggestions, what's not working" plain text.
    /// Sits next to Donation because both are explicit
    /// "engage with the developer" actions.
    private var feedbackSection: some View {
        Section("Feedback") {
            Text("Have thoughts, suggestions, or notice something off? Send a quick note — it goes straight to the developer. Your app version and recent local log are attached so issues can be diagnosed; you can review them in the composer before sending.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button {
                    presentFeedback()
                } label: {
                    Label("Send Feedback", systemImage: "envelope.fill")
                }
                .buttonStyle(.borderedProminent)
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
                .textSelection(.enabled)
        }
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            Text("Errors are logged locally to your Mac. Nothing is sent automatically — when you Send Feedback above, the log is included with your message so the issue can be diagnosed. The buttons below let you inspect the local log directly if you want to see what's stored.")
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
                Spacer()
            }
        }
    }

    /// Compose both the redacted and raw log footers, then present
    /// the feedback composer with them pre-filled. Reads the log
    /// file fresh on every press so a bug encountered seconds before
    /// opening the sheet is included.
    private func presentFeedback() {
        let raw = logText(useRedacted: false)
        let redacted = logText(useRedacted: true)
        let recordingsCount = 0
        let model = transcriberHolder.primaryModelID.rawValue
        let redactedFooter = LogSharing.bugReportFooter(
            logText: redacted,
            recordingsCount: recordingsCount,
            modelIdentifier: model
        )
        let rawFooter = LogSharing.bugReportFooter(
            logText: raw,
            recordingsCount: recordingsCount,
            modelIdentifier: model
        )
        pendingFeedback = FeedbackContext(
            redactedFooter: redactedFooter,
            rawFooter: rawFooter
        )
    }

    // MARK: - Credit

    private var creditSection: some View {
        Section("Acknowledgements") {
            // Surface the exact model in use here (design §5.1 / §8) — the
            // language picker hides model names everywhere else, so this is the
            // one place a user can see which Parakeet variant is active.
            HStack(spacing: 4) {
                Text("Transcription model")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(transcriberHolder.primaryModelID.displayName)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11))
            HStack(spacing: 4) {
                Text("Built by")
                    .foregroundStyle(.secondary)
                Text("Vineet Sriram")
                Spacer()
            }
            .font(.system(size: 11))
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
        var all: [String] = []
        var seen = Set<String>()
        let appendIfSensitive: (String) -> Void = { s in
            guard s.count >= 10 else { return }
            guard seen.insert(s).inserted else { return }
            all.append(s)
        }
        if let recordings = try? modelContext.fetch(descriptor) {
            for recording in recordings {
                appendIfSensitive(recording.transcript)
                if recording.rawTranscript != recording.transcript {
                    appendIfSensitive(recording.rawTranscript)
                }
            }
        }
        // Mirror `LogScanner.fetchTranscripts()` — Rewrite session
        // selection / instruction / output must participate in the
        // About-pane redaction corpus too. Same count >= 10 threshold,
        // same dedup so identical strings don't generate duplicate
        // ranges in `LogRedactor`.
        var sessionDescriptor = FetchDescriptor<RewriteSession>(
            predicate: #Predicate { $0.createdAt >= cutoff }
        )
        sessionDescriptor.fetchLimit = 2000
        if let sessions = try? modelContext.fetch(sessionDescriptor) {
            for s in sessions {
                appendIfSensitive(s.selectionText)
                appendIfSensitive(s.instructionText)
                appendIfSensitive(s.output)
            }
        }
        return all
    }
}
