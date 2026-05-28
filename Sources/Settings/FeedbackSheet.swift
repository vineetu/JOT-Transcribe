import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
/// Inputs the sheet uses to pre-fill the editor: empty space at
/// the top (where the user types their description) followed by
/// the redacted log + app-details footer at the bottom. The
/// in-sheet "Show original log" toggle swaps between redacted and
/// original views of the same data; both are sent inline as part
/// of the message body, never as a separate field.
struct FeedbackContext: Identifiable {
    /// `Identifiable` so `.sheet(item:)` can drive presentation —
    /// a stable per-instance UUID is enough because each press of
    /// "Send Feedback" mints a fresh context (and dismissing nil's
    /// it out). No callers compare contexts.
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

    /// Log + app-details payload pre-filled into the editor. Always
    /// present — the previous "no-logs" feedback path was removed
    /// when the two feedback buttons collapsed into one.
    let context: FeedbackContext

    init(context: FeedbackContext) {
        self.context = context
    }

    @State private var message: String = ""
    @State private var isSending: Bool = false
    @State private var didSend: Bool = false
    @State private var errorMessage: String?
    @State private var submittedID: Int?

    /// True when the user has flipped the in-sheet toggle to
    /// "Show original log". Default false — the redacted version
    /// is the safe surface, the original is opt-in for review.
    @State private var showRawLog: Bool = false

    /// Source-file URLs picked via NSOpenPanel. Authoritative
    /// selection — `processedDataURIs` is a derived cache that
    /// follows this array through `FeedbackImageEncoder`. Capped
    /// at 3 by the picker handler.
    @State private var selectedURLs: [URL] = []

    /// Index-aligned with `selectedURLs` on a successful encode,
    /// empty while a fresh encode is mid-flight or after a
    /// failure. Submit is gated on this matching `selectedURLs`
    /// count so we never silently send the user's text without
    /// the screenshots they thought they attached.
    @State private var processedDataURIs: [String] = []

    /// Combined base64-encoded length of `processedDataURIs`,
    /// shown in the counter so the user sees the real upload
    /// size — not the original file size, which is misleading
    /// (a 12 MB ProRAW screenshot becomes ~700 KB JPEG).
    @State private var totalEncodedBytes: Int = 0

    /// True while `FeedbackImageEncoder.encode(...)` is mid-run.
    /// Submit stays disabled during this window so the POST
    /// never lands without the images the user expected.
    @State private var isProcessingImages: Bool = false

    /// Image-pipeline errors (too large / unreadable). Shown
    /// inline below the attachments row. Kept separate from
    /// `errorMessage` so a stale "too large" warning doesn't
    /// imply the network send itself failed.
    @State private var imageError: String?

    /// Holds the in-flight encode task. On a fresh selection
    /// change we cancel this before starting the next encode —
    /// otherwise a slow earlier encode (e.g. 3 huge images) can
    /// land after a fast later one and clobber state the user
    /// thought they had updated.
    @State private var encodeTask: Task<Void, Never>?

    @FocusState private var editorFocused: Bool

    /// Empty-space prefix the pre-fill leads with so the user has
    /// visible blank lines above the log footer to type their
    /// description into. Four newlines feels like "enough room"
    /// without making the editor scroll past the log section on
    /// first paint.
    private static let leadingSpace = "\n\n\n\n"

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
        // Sheet always pre-fills the editor with a log block, so it
        // needs room for the description area + log + attachments
        // row (picker button + 56pt thumbnails + counter) without
        // forced scrolling.
        .frame(width: 580, height: 620)
        .onChange(of: selectedURLs) { _, newURLs in
            scheduleEncode(for: newURLs)
        }
        .onDisappear {
            // Sheet is going away — abandon any in-flight encode so
            // it doesn't keep burning CPU off-screen.
            encodeTask?.cancel()
        }
        .onAppear {
            // Pre-fill the editor with empty space at the top + the
            // redacted log footer at the bottom. Setting this in
            // `onAppear` rather than `init` keeps `message` a
            // `@State` (resetting cleanly if the sheet is dismissed
            // and re-presented).
            if message.isEmpty {
                message = Self.leadingSpace + context.redactedFooter
            }

            // Defer focus a tick so the sheet's own
            // first-responder hand-off finishes before we steal it.
            DispatchQueue.main.async { editorFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text("Send Feedback")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
        }
    }

    private var subtitle: some View {
        Text("Type your message in the empty space at the top. Your app details and recent log are pre-filled below and sent along with your description — flip to the original log if a redaction obscured something important.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Row above the editor that toggles the embedded footer between
    /// the redacted and original log. Edits `message` in place by
    /// substring-replacing the old footer with the new one, which
    /// preserves whatever the user has typed in the description area
    /// above. If the user has manually edited the footer text the
    /// exact-match swap will no-op — acceptable edge case; they've
    /// already opted into hand-curating.
    private var redactedToggleRow: some View {
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
                swapFooter(showingRaw: newValue)
            }
            Spacer()
            Text(showRawLog ? "Original — review before sending" : "Redacted")
                .font(.system(size: 11))
                .foregroundStyle(showRawLog ? .orange : .secondary)
        }
        .padding(.bottom, 8)
    }

    private func swapFooter(showingRaw: Bool) {
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

            attachmentsRow

            if let imageError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .padding(.top, 1)
                    Text(imageError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

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
        // `processedDataURIs.count == selectedURLs.count` is the
        // defensive guard: if encoding errored or is mid-flight,
        // the arrays diverge and submit is blocked. Without this,
        // a "too large" error could leave the user able to send
        // their text with the screenshots silently dropped.
        !isSending
            && !isProcessingImages
            && imageError == nil
            && processedDataURIs.count == selectedURLs.count
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Thanks for the feedback!")
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
        // Snapshot the wire payload at submit time so a thumbnail
        // remove during the network round-trip can't desync the
        // POSTed images from what the user saw when they clicked.
        let imagesSnapshot = processedDataURIs

        Task { @MainActor in
            do {
                let id = try await FeedbackClient.send(
                    message: trimmed,
                    images: imagesSnapshot
                )
                submittedID = id
                didSend = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    // MARK: - Attachments

    @ViewBuilder
    private var attachmentsRow: some View {
        HStack(spacing: 10) {
            Button {
                openImagePicker()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperclip")
                    Text(selectedURLs.isEmpty ? "Add screenshots" : "Add more")
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSending || isProcessingImages || selectedURLs.count >= 3)
            .help(selectedURLs.count >= 3 ? "Maximum 3 screenshots." : "Attach up to 3 screenshots (5 MB total).")

            if !selectedURLs.isEmpty || isProcessingImages {
                Divider().frame(height: 20)

                HStack(spacing: 8) {
                    ForEach(selectedURLs, id: \.self) { url in
                        thumbnailView(for: url)
                    }
                    if isProcessingImages {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Processing…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()

            if !selectedURLs.isEmpty {
                Text(counterText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }

    private func thumbnailView(for url: URL) -> some View {
        // NSImage is loaded synchronously on MainActor for display
        // — fine because we cap selection at 3 and SwiftUI caches
        // the rendered output. The encoder already validated the
        // file is readable; the `if let` fallback only triggers
        // if the source moves out from under us after selection.
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            Button {
                remove(url: url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.65))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .disabled(isSending)
            .help("Remove this screenshot")
        }
    }

    private var counterText: String {
        let sizeString: String
        if isProcessingImages || totalEncodedBytes == 0 {
            sizeString = "—"
        } else {
            sizeString = ByteCountFormatter.string(
                fromByteCount: Int64(totalEncodedBytes),
                countStyle: .file
            )
        }
        return "\(selectedURLs.count)/3 · \(sizeString)"
    }

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = "Attach Screenshots"
        panel.message = "Select up to 3 images to attach to your feedback."
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else { return }

        // NSOpenPanel doesn't have a max-selection property, so the
        // cap is enforced here. Take only as many fresh URLs as the
        // remaining slot count allows.
        let remaining = max(0, 3 - selectedURLs.count)
        if remaining > 0 {
            selectedURLs.append(contentsOf: panel.urls.prefix(remaining))
        }
    }

    private func remove(url: URL) {
        selectedURLs.removeAll { $0 == url }
    }

    private func scheduleEncode(for urls: [URL]) {
        // Cancel any in-flight encode before kicking off the new
        // one. Cancellation is task-local: the encoder checks
        // `Task.checkCancellation()` between images and between
        // quality passes, so an older 3-huge-image encode bails
        // before clobbering state the user has since updated.
        encodeTask?.cancel()
        imageError = nil

        guard !urls.isEmpty else {
            processedDataURIs = []
            totalEncodedBytes = 0
            isProcessingImages = false
            return
        }

        isProcessingImages = true
        processedDataURIs = []
        totalEncodedBytes = 0

        let snapshot = urls
        encodeTask = Task { @MainActor in
            do {
                let uris = try await FeedbackImageEncoder.encode(urls: snapshot)
                try Task.checkCancellation()
                processedDataURIs = uris
                totalEncodedBytes = uris.reduce(0) { $0 + $1.utf8.count }
                isProcessingImages = false
            } catch is CancellationError {
                // A newer encode is in flight (or the sheet is
                // dismissing) — don't touch state; the newer
                // task owns it now.
            } catch {
                processedDataURIs = []
                totalEncodedBytes = 0
                imageError = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't process the selected screenshots."
                isProcessingImages = false
            }
        }
    }
}
