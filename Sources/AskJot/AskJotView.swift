import SwiftUI

/// Full-pane UI for the Ask Jot chatbot.
///
/// Structure:
///   1. Header: `sparkles` + "Ask Jot" + subtitle + optional New chat button.
///   2. Message area: centered 600pt reading column or the empty/unavailable state.
///   3. Input bar pinned to the bottom when Ask Jot is available.
///
/// State ownership:
///   * `HelpChatStore` is passed in from `JotAppWindow` so conversation survives sidebar navigation.
///   * `HelpNavigator` provides prefill / focus requests and handles Help-tab deep-links.
struct AskJotView: View {
    let store: HelpChatStore
    @ObservedObject var voiceInput: ChatbotVoiceInput

    @Environment(\.helpNavigator) private var navigator
    @Environment(\.setSidebarSelection) private var setSidebarSelection

    @State private var composer: String = ""
    @State private var showingNewChatConfirmation = false
    @FocusState private var inputFocused: Bool
    /// v1.13: first-open banner that appears once for users whose Ask Jot
    /// routing changed in v1.13 (legacy `allowCloud == true` + cloud
    /// provider). Computed on appear from `store.shouldShowCloudMigrationBanner()`
    /// so the SwiftUI body doesn't re-read UserDefaults every render.
    @State private var showCloudMigrationBanner: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider().opacity(0.5)

            if showCloudMigrationBanner {
                cloudMigrationBanner
            }

            messageRegion
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !store.isUnavailable {
                Divider().opacity(0.5)

                inputBar
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AskJotPalette.paperColor)
        .environment(\.openURL, OpenURLAction { url in
            handleOpenURL(url)
        })
        .confirmationDialog(
            "Start a new chat?",
            isPresented: $showingNewChatConfirmation,
            titleVisibility: .visible
        ) {
            Button("New chat", role: .destructive) {
                clearConversation()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current Ask Jot conversation.")
        }
        .onAppear {
            store.refreshAvailability()
            store.prewarmIfNeeded()
            consumePendingPrefillIfNeeded()
            consumeFocusRequestIfNeeded()
            // v1.13: surface the cloud-migration banner once per upgrading
            // user. `shouldShowCloudMigrationBanner()` is a one-time gate;
            // dismissal writes the sentinel and the banner never re-appears.
            if showCloudMigrationBanner == false {
                showCloudMigrationBanner = store.shouldShowCloudMigrationBanner()
            }
        }
        .onChange(of: navigator.pendingPrefill) { _, _ in
            consumePendingPrefillIfNeeded()
        }
        .onChange(of: navigator.focusChatInput) { _, _ in
            consumeFocusRequestIfNeeded()
        }
        .onKeyPress(.escape, phases: .down) { _ in
            guard inputFocused else { return .ignored }
            switch voiceInput.state {
            case .recording, .transcribing, .condensing:
                Task { await voiceInput.cancel() }
                return .handled
            default:
                break
            }
            if case .streaming = store.state {
                store.cancelStream()
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask Jot")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(store.isUnavailable
                                     ? AskJotPalette.inkMutedColor
                                     : AskJotPalette.inkColor)

                Text("On-device help, grounded in Jot's docs")
                    .font(.system(size: 11, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AskJotPalette.inkMutedColor)
            }

            Spacer()

            if !store.messages.isEmpty {
                Button("New chat") {
                    handleNewChatAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("n", modifiers: [.command])
                .accessibilityHint("Clears the conversation and starts fresh.")

                Button("Clear chat") {
                    handleNewChatAction()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: - v1.13 cloud-migration banner

    /// One-time dismissible banner for users whose Ask Jot routing
    /// changed in v1.13 (legacy `allowCloud == true` + non-Apple
    /// provider). Dismissal is persisted in `UserDefaults` so it
    /// never re-appears.
    private var cloudMigrationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 2) {
                Text("Ask Jot now uses your configured AI provider directly.")
                    .font(.system(size: 12, weight: .medium))
                Text("To keep Ask Jot on Apple Intelligence, switch Settings → AI → Provider.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

            Spacer(minLength: 6)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    showCloudMigrationBanner = false
                }
                store.markCloudMigrationBannerDismissed()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    // MARK: - Message region

    @ViewBuilder
    private var messageRegion: some View {
        if case .unavailable(let reason) = store.state {
            unavailableView(reason: reason)
        } else if store.messages.isEmpty {
            emptyStatePrompts
        } else {
            messageScroll
        }
    }

    private var messageScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AskJotLayout.conversationSpacing) {
                    ForEach(store.messages) { message in
                        MessageBubble(message: message, onOpenURL: handleAssistantLink)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: AskJotLayout.readingColumnWidth, alignment: .leading)
                .padding(.horizontal, 56)
                .padding(.vertical, AskJotLayout.conversationVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: store.messages.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
            .onChange(of: store.messages.last?.content) { _, _ in
                guard let lastId = store.messages.last?.id else { return }
                proxy.scrollTo(lastId, anchor: .bottom)
            }
        }
    }

    // MARK: - Empty state

    private var emptyStatePrompts: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 20) {
                // 2pt blue rule + headline, magazine masthead style.
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Rectangle()
                        .fill(AskJotPalette.inkAccentColor)
                        .frame(width: 2, height: 28)
                        .offset(y: 6)

                    Text("What can I help with?")
                        .font(.system(size: 24, weight: .regular, design: .serif))
                        .foregroundStyle(AskJotPalette.inkColor)
                }

                Text("On-device via Apple Intelligence")
                    .font(.system(size: 12, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AskJotPalette.inkMutedColor)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.starterPrompts, id: \.self) { prompt in
                        StarterPromptRow(prompt: prompt) {
                            composer = prompt
                            sendIfPossible()
                            inputFocused = true
                        }
                    }
                }
                .padding(.top, 12)

                Text("Tip — press the mic to ask with your voice.")
                    .font(.system(size: 11, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(AskJotPalette.inkMutedColor)
                    .padding(.top, 16)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 56)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let starterPrompts: [String] = [
        "How do I change my dictation shortcut?",
        "What's the difference between Cleanup and Rewrite?",
        "Why won't a single key work as my hotkey?"
    ]

    // MARK: - Unavailable state

    @ViewBuilder
    private func unavailableView(reason: UnavailableReason) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .opacity(0.3)

            Text(Self.unavailableHeadline(for: reason))
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(Self.unavailableBody(for: reason))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                if reason == .appleIntelligenceNotEnabled {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.ai") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Browse the Help tab \u{2192}") {
                    setSidebarSelection(.help)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private static func unavailableHeadline(for reason: UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Ask Jot needs Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off"
        case .modelNotReady:
            return "Apple Intelligence is getting ready"
        case .osTooOld:
            return "Ask Jot needs macOS 26.4 or later"
        case .other:
            return "Ask Jot isn't available right now"
        }
    }

    private static func unavailableBody(for reason: UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Ask Jot runs on-device via Apple Intelligence, which needs an Apple Silicon Mac with Apple Intelligence support."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use Ask Jot, or browse the Help tab for answers."
        case .modelNotReady:
            return "Apple Intelligence is still preparing. Meanwhile, browse the Help tab."
        case .osTooOld:
            return "Update your Mac to macOS 26.4 or later to use Ask Jot."
        case .other:
            return "Ask Jot can't reach Apple Intelligence right now. Try again, or browse the Help tab."
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            composerField
            sendButton
        }
    }

    private var composerField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(
                "Ask about any feature…",
                text: $composer,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...6)
            .focused($inputFocused)
            .padding(.leading, 14)
            .padding(.vertical, 10)
            .onSubmit {
                sendIfPossible()
            }

            micButton
                .padding(.trailing, 8)
                .padding(.bottom, 6)
        }
        .background(composerBackground)
        .disabled(!isInputEnabled)
    }

    @ViewBuilder
    private var composerBackground: some View {
        if inputFocused {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
    }

    private var micButton: some View {
        Button {
            handleMicTap()
        } label: {
            Image(systemName: micGlyph)
                .font(.title2)
                .foregroundStyle(micTint)
                .symbolEffect(.pulse, options: .repeating, isActive: micIsAnimating)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(micTooltip)
        .accessibilityLabel("Voice input")
        .accessibilityHint(micAccessibilityHint)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!micIsInteractive)
    }

    // MARK: - Mic state → UI

    private var micGlyph: String {
        switch voiceInput.state {
        case .idle, .disabled: return "mic.circle"
        case .recording: return "waveform.circle.fill"
        case .transcribing, .condensing: return "ellipsis.circle"
        case .error: return "exclamationmark.circle"
        }
    }

    private var micTint: Color {
        switch voiceInput.state {
        case .recording, .transcribing, .condensing: return Color.accentColor
        case .error: return Color.red
        default: return Color.secondary
        }
    }

    private var micIsAnimating: Bool {
        switch voiceInput.state {
        case .recording, .transcribing, .condensing: return true
        default: return false
        }
    }

    private var micIsInteractive: Bool {
        guard isInputEnabled else { return false }
        switch voiceInput.state {
        case .disabled: return false
        case .idle, .recording: return true
        case .transcribing, .condensing, .error: return false
        }
    }

    private var micTooltip: String {
        switch voiceInput.state {
        case .idle: return "Speak your question"
        case .recording: return "Tap to stop"
        case .transcribing: return "Transcribing…"
        case .condensing: return "Condensing…"
        case .disabled(let reason):
            switch reason {
            case .globalRecordingActive: return "Finish your current recording first"
            case .micPermissionDenied: return "Microphone permission denied"
            case .appleIntelligenceUnavailable: return "Apple Intelligence unavailable"
            }
        case .error: return "Voice input error — tap to retry"
        }
    }

    private var micAccessibilityHint: String {
        switch voiceInput.state {
        case .recording: return "Tap to stop recording"
        default: return "Tap to speak your question"
        }
    }

    private func handleMicTap() {
        switch voiceInput.state {
        case .idle, .error:
            Task {
                do {
                    let text = try await voiceInput.capture()
                    composer = text
                    inputFocused = true
                } catch is CancellationError {
                    // User cancelled; no UI feedback needed.
                } catch {
                    // Mic state already reflects the pipeline failure.
                }
            }
        case .recording:
            voiceInput.stop()
        default:
            break
        }
    }

    private var sendButton: some View {
        Button {
            sendIfPossible()
        } label: {
            Image(systemName: "arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(canSend ? Color.accentColor : Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [])
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityHint("Sends the message.")
    }

    // MARK: - Send helpers

    private var isInputEnabled: Bool {
        switch store.state {
        case .idle, .error:
            return true
        case .streaming, .unavailable:
            return false
        }
    }

    private var canSend: Bool {
        guard isInputEnabled else { return false }
        return !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendIfPossible() {
        guard canSend else { return }
        let text = composer
        composer = ""
        store.send(text)
    }

    // MARK: - Navigation helpers

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == FeatureReference.urlScheme else { return .systemAction(url) }
        guard
            let slug = FeatureReference.slug(from: url),
            let reference = FeatureReference.bySlug(slug)
        else {
            return .discarded
        }

        handleSlugTap(reference)
        return .handled
    }

    private func handleAssistantLink(_ url: URL) -> Bool {
        guard url.scheme == FeatureReference.urlScheme else { return false }
        guard
            let slug = FeatureReference.slug(from: url),
            let reference = FeatureReference.bySlug(slug)
        else {
            return false
        }

        handleSlugTap(reference)
        return true
    }

    private func handleSlugTap(_ reference: FeatureReference) {
        guard reference.isDeepLinkable, let feature = Feature.bySlug(reference.slug) else { return }
        navigator.show(feature: feature)
        navigator.sidebarSelection = .help
    }

    private func handleNewChatAction() {
        guard !store.messages.isEmpty else { return }
        if NSEvent.modifierFlags.contains(.option) {
            clearConversation()
        } else {
            showingNewChatConfirmation = true
        }
    }

    private func clearConversation() {
        store.clear()
        composer = ""
    }

    // MARK: - Navigator prefill / focus consumption

    private func consumePendingPrefillIfNeeded() {
        guard let prefill = navigator.pendingPrefill, !prefill.isEmpty else { return }
        composer = prefill
        navigator.pendingPrefill = nil
        store.pendingPrefill = nil
        inputFocused = true
    }

    private func consumeFocusRequestIfNeeded() {
        guard navigator.focusChatInput else { return }
        inputFocused = true
        navigator.focusChatInput = false
    }
}

// MARK: - Starter prompt row

private struct StarterPromptRow: View {
    let prompt: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2014}")
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(AskJotPalette.inkAccentColor)

                Text(prompt)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(isHovered
                                     ? AskJotPalette.inkAccentColor
                                     : AskJotPalette.inkColor)
                    .multilineTextAlignment(.leading)
                    .underline(isHovered, pattern: .dot)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .accessibilityHint("Starts a new Ask Jot conversation with this question.")
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: ChatMessage
    let onOpenURL: (URL) -> Bool

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userBubble
            case .assistant:
                assistantBlock
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var userBubble: some View {
        // Editorial margin-note: right-aligned SF Pro text with a subtle
        // paper wash and the existing left rule. It reads as one bounded
        // query without becoming a glossy chat bubble.
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: AskJotLayout.userTurnInset)

            Text(userAttributedContent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: AskJotLayout.userTurnMaxWidth, alignment: .leading)
                .padding(.leading, 18)
                .padding(.trailing, 18)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: AskJotLayout.turnCornerRadius, style: .continuous)
                        .fill(AskJotPalette.userTurnTintColor)
                )
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(AskJotPalette.userMarkColor)
                        .frame(width: 1)
                        .padding(.leading, 12)
                        .padding(.vertical, 12)
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantBlock: some View {
        // Editorial column: byline in New York small caps above, then a
        // 2pt blue pull-quote rule + serif prose, all on a faint paper
        // wash so one answer reads as one bounded turn.
        VStack(alignment: .leading, spacing: AskJotLayout.assistantBlockSpacing) {
            HStack(spacing: 10) {
                Text("ASK JOT")
                    .font(AskJotType.byline)
                    .tracking(AskJotType.bylineTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(AskJotPalette.inkMutedColor)

                Spacer(minLength: 12)

                if message.isStreaming && message.content.isEmpty {
                    StreamingIndicator()
                        .transition(.opacity)
                }
            }

            if !message.content.isEmpty {
                HStack(alignment: .top, spacing: AskJotLayout.assistantRuleSpacing) {
                    Rectangle()
                        .fill(AskJotPalette.inkAccentColor)
                        .frame(width: 2, height: AskJotLayout.assistantRuleHeight)

                    AssistantMessageText(content: assistantAttributedContent, onOpenURL: onOpenURL)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, AskJotLayout.turnHorizontalPadding)
        .padding(.vertical, AskJotLayout.turnVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AskJotLayout.turnCornerRadius, style: .continuous)
                .fill(AskJotPalette.assistantTurnTintColor)
        )
        .animation(.easeOut(duration: 0.22), value: message.content.isEmpty)
    }

    private var userAttributedContent: AttributedString {
        var content = AttributedString(message.content)
        content.font = .system(size: 14, weight: .regular)
        content.foregroundColor = AskJotPalette.inkColor
        return content
    }

    private var assistantAttributedContent: AttributedString {
        let rendered = ChatMarkdown.render(message.content, streaming: message.isStreaming)
        return applyFeatureReferences(to: rendered)
    }

    private func applyFeatureReferences(to input: AttributedString) -> AttributedString {
        let pattern = #"\[([a-z0-9][a-z0-9-]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }

        let raw = String(input.characters)
        let rawNS = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        var output = input

        for match in matches.reversed() {
            guard
                let slugRange = Range(match.range(at: 1), in: raw),
                let replacementRange = Range(match.range, in: output)
            else {
                continue
            }

            let slug = String(raw[slugRange])
            guard let reference = FeatureReference.bySlug(slug) else {
                // Unresolved slug — strip the marker silently so glossary-
                // only terms like `[shortcuts]` (present in the grounding
                // doc but with no matching Feature) don't leak as literal
                // bracketed text. Eat one leading space if present so
                // mid-sentence strips don't produce "Settings . Here's
                // how".
                let loc = match.range.location
                var stripRange = replacementRange
                if loc > 0 {
                    let prevChar = rawNS.substring(with: NSRange(location: loc - 1, length: 1))
                    if prevChar == " ",
                       let extended = Range(
                            NSRange(location: loc - 1, length: match.range.length + 1),
                            in: output
                       ) {
                        stripRange = extended
                    }
                }
                output.replaceSubrange(stripRange, with: AttributedString(""))
                continue
            }

            var replacement = AttributedString(reference.title)
            if reference.isDeepLinkable {
                // Feature citations render as New York italic in blue.
                // The italic + color shift carries the link affordance —
                // no underline at rest (underline appears on hover via
                // linkTextAttributes, per editorial convention).
                replacement.font = .system(size: AskJotType.bodySize, weight: .regular, design: .serif).italic()
                replacement.foregroundColor = AskJotPalette.inkAccentColor
                replacement.link = reference.url
            } else {
                replacement.font = .system(size: AskJotType.bodySize, weight: .semibold, design: .serif)
                replacement.foregroundColor = AskJotPalette.inkColor
            }

            output.replaceSubrange(replacementRange, with: replacement)
        }

        return output
    }

    private var accessibilityLabel: String {
        switch message.role {
        case .user:
            return "You asked: \(message.content)"
        case .assistant:
            if message.isStreaming && message.content.isEmpty {
                return "Ask Jot is responding."
            }
            return "Ask Jot said: \(message.content)"
        }
    }
}

// MARK: - Streaming indicator

private struct AssistantMessageText: NSViewRepresentable {
    let content: AttributedString
    let onOpenURL: (URL) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> LinkInterceptingTextView {
        let textView = LinkInterceptingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.linkTextAttributes = [
            .foregroundColor: AskJotPalette.inkAccent,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        ]
        textView.textStorage?.setAttributedString(Self.styled(content))
        return textView
    }

    func updateNSView(_ nsView: LinkInterceptingTextView, context: Context) {
        context.coordinator.onOpenURL = onOpenURL
        nsView.textStorage?.setAttributedString(Self.styled(content))
        nsView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: LinkInterceptingTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              width.isFinite,
              width > 0,
              width < 10_000
        else { return nil }
        return nsView.measuredSize(fittingWidth: width)
    }

    private static func styled(_ content: AttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(content))
        let paragraph = NSMutableParagraphStyle()
        // Keep the column dense enough to feel printed, not note-like.
        paragraph.lineSpacing = AskJotType.bodyLineSpacing
        paragraph.paragraphSpacing = AskJotType.bodyParagraphSpacing
        paragraph.hyphenationFactor = 0.25
        mutable.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: mutable.length)
        )
        // Apply ink color as a BASE — walk ranges that have no
        // foregroundColor attribute set and stamp them with ink. Skips
        // link runs (blue) and other explicitly-colored ranges so they
        // keep their editorial treatment.
        let full = NSRange(location: 0, length: mutable.length)
        mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: AskJotPalette.ink, range: range)
            }
        }
        return mutable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: (URL) -> Bool

        init(onOpenURL: @escaping (URL) -> Bool) {
            self.onOpenURL = onOpenURL
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if onOpenURL(url) {
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

private final class LinkInterceptingTextView: NSTextView {
    func measuredSize(fittingWidth width: CGFloat) -> CGSize {
        let constrainedWidth = max(width, 1)
        guard let textContainer, let layoutManager else { return .zero }

        textContainer.containerSize = NSSize(
            width: constrainedWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        return CGSize(width: constrainedWidth, height: ceil(usedRect.height))
    }

    override var intrinsicContentSize: NSSize {
        measuredSize(fittingWidth: bounds.width > 0 ? bounds.width : 1)
    }
}

private struct StreamingIndicator: View {
    // Editorial streaming: a single em-dash in blue, pulsing slowly.
    // Telegraph, not three-dot chat loader. No app on Earth uses this.
    @State private var pulse = false

    var body: some View {
        Text("\u{2014}")
            .font(.system(size: 14, weight: .regular, design: .serif))
            .foregroundStyle(AskJotPalette.inkAccentColor)
            .opacity(pulse ? 1.0 : 0.3)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityHidden(true)
    }
}
