import SwiftUI

/// Plain-text feedback composer. Presented as a `.sheet` from
/// `AboutPane`. POSTs the entered text to `FeedbackClient.send(...)`
/// and swaps to a Thanks state on success.
///
/// Light/dark mode notes:
/// - All visible color comes from system semantic tokens
///   (`Color.secondary`, `.red`, `.green`, `Color(nsColor:
///   .textBackgroundColor)`, `Color(nsColor: .separatorColor)`).
///   No hard-coded hex values — AppKit/SwiftUI swap their
///   resolved colors automatically when the user toggles
///   Appearance, so this sheet adapts without any
///   `@Environment(\.colorScheme)` branching.
/// - `TextEditor`'s default background is opaque white in light
///   mode and unreadable in dark mode; `.scrollContentBackground(
///   .hidden)` plus an explicit `Color(nsColor:
///   .textBackgroundColor)` is the documented Sonoma+ way to make
///   it follow Appearance.
/// Inputs that put `FeedbackSheet` in bug-report mode. When set,
/// the sheet pre-fills the editor with empty space at the top
/// (where the user types their description) followed by the chosen
/// log footer at the bottom, and exposes a toggle to swap between
/// the redacted and original logs inline. Distinct from a separate
/// bug-report sheet so the two flows share one composer / one
/// network path / one success+error UX.
struct FeedbackBugReportContext: Identifiable {
    /// `Identifiable` so `.sheet(item:)` can drive presentation —
    /// a stable per-instance UUID is enough because each press of
    /// the "Send Bug Report" button mints a fresh context (and
    /// dismissing nil's it out). No callers compare contexts.
    let id = UUID()
    /// Privacy-scrubbed log + app-details block. Default content
    /// of the pre-fill — the safe choice surfaced by the toggle's
    /// default state.
    let redactedFooter: String
    /// Original (unredacted) log + app-details block. Shown only
    /// when the user explicitly flips the in-sheet "Show original
    /// log" toggle, after seeing the redacted version first.
    let rawFooter: String
}

struct FeedbackSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, switches the sheet into bug-report mode:
    /// different title/subtitle, pre-filled message body, and an
    /// in-sheet redacted/original-log toggle.
    let bugReport: FeedbackBugReportContext?

    init(bugReport: FeedbackBugReportContext? = nil) {
        self.bugReport = bugReport
    }

    @State private var message: String = ""
    @State private var isSending: Bool = false
    @State private var didSend: Bool = false
    @State private var errorMessage: String?
    @State private var submittedID: Int?

    /// True when the user has flipped the bug-report toggle to
    /// "Show original log". Only meaningful when `bugReport` is
    /// non-nil — feedback mode never uses this.
    @State private var showRawLog: Bool = false

    @FocusState private var editorFocused: Bool

    /// Empty-space prefix the bug-report pre-fill leads with so
    /// the user has visible blank lines above the log footer to
    /// type their description into. Four newlines feels like
    /// "enough room" without making the editor scroll past the
    /// log section on first paint.
    private static let bugReportLeadingSpace = "\n\n\n\n"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 6)
            subtitle
                .padding(.bottom, 14)

            if didSend {
                successView
            } else {
                composerView
            }
        }
        .padding(20)
        .frame(
            // Bug-report mode pre-fills the editor with a log block —
            // larger frame so the user can see both their description
            // area and the log without forced scrolling.
            width: bugReport == nil ? 480 : 580,
            height: bugReport == nil ? 380 : 540
        )
        .onAppear {
            // Pre-fill the editor with empty space at the top + the
            // redacted log footer at the bottom when in bug-report
            // mode. Setting this in `onAppear` rather than `init`
            // keeps `message` a `@State` (resetting cleanly if the
            // sheet is dismissed and re-presented).
            if message.isEmpty, let bugReport {
                message = Self.bugReportLeadingSpace + bugReport.redactedFooter
            }

            // Defer focus a tick so the sheet's own
            // first-responder hand-off finishes before we steal it.
            DispatchQueue.main.async { editorFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: bugReport == nil ? "envelope.fill" : "ladybug.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(bugReport == nil ? "Send Feedback" : "Send Bug Report")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
    }

    private var subtitle: some View {
        Text(
            bugReport == nil
                ? "Thoughts, suggestions, or what's not working — it goes straight to the developer. No logs are attached."
                : "Describe what went wrong in the empty space at the top. The log and app details are pre-filled below — they're sent along with your description. Flip to the original log if a redaction obscured something important."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Bug-report-only row above the editor that toggles the
    /// embedded footer between the redacted and original log. Edits
    /// `message` in place by substring-replacing the old footer with
    /// the new one, which preserves whatever the user has typed in
    /// the description area above. If the user has manually edited
    /// the footer text the exact-match swap will no-op — acceptable
    /// edge case; they've already opted into hand-curating.
    @ViewBuilder
    private var redactedToggleRow: some View {
        if let bugReport {
            HStack(spacing: 8) {
                Image(systemName: showRawLog ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle(isOn: $showRawLog) {
                    Text("Show original log")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: showRawLog) { _, newValue in
                    swapFooter(showingRaw: newValue, context: bugReport)
                }
                Spacer()
                Text(showRawLog ? "Original — review before sending" : "Redacted")
                    .font(.system(size: 11))
                    .foregroundStyle(showRawLog ? .orange : .secondary)
            }
            .padding(.bottom, 8)
        }
    }

    private func swapFooter(showingRaw: Bool, context: FeedbackBugReportContext) {
        let oldFooter = showingRaw ? context.redactedFooter : context.rawFooter
        let newFooter = showingRaw ? context.rawFooter : context.redactedFooter
        if let range = message.range(of: oldFooter) {
            message.replaceSubrange(range, with: newFooter)
        }
    }

    // MARK: - Composer

    private var composerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            redactedToggleRow

            TextEditor(text: $message)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .focused($editorFocused)
                .disabled(isSending)
                .frame(maxHeight: .infinity)

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.top, 1)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Text("\(message.count) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSending)
                .keyboardShortcut(.cancelAction)

                Button {
                    submit()
                } label: {
                    if isSending {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Sending…")
                        }
                    } else {
                        Text("Send")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend)
            }
        }
    }

    private var canSend: Bool {
        !isSending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(bugReport == nil ? "Thanks for the feedback!" : "Bug report sent.")
                .font(.system(size: 16, weight: .semibold))
            Text(thanksSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var thanksSubtitle: String {
        if let id = submittedID {
            return "Received as #\(id). Every message is read."
        }
        return "Every message is read."
    }

    // MARK: - Submit

    private func submit() {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSending = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let id = try await FeedbackClient.send(message: trimmed)
                submittedID = id
                didSend = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }
}
