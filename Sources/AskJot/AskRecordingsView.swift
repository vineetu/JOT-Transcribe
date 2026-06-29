import SwiftUI

/// Transcript-Q&A Ask Jot pane. Answers questions over the user's recordings
/// (and the app's help) in a calm reading surface that matches the recordings
/// detail view: a centered serif column, system semantic colors, a quiet
/// bottom composer. Citations render as tappable source pills under each
/// answer; tapping one calls `onOpenRecording`.
struct AskRecordingsView: View {
    @Bindable var store: AskRecordingsStore

    /// Navigate to a recording the answer cited. Wired to the Recents route.
    let onOpenRecording: (UUID) -> Void

    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool

    /// Comfortable reading width — mirrors `DetailMetrics.readingMeasure` so the
    /// answer column lines up with the rest of the app's reading surfaces.
    private let column: CGFloat = 700

    init(store: AskRecordingsStore, onOpenRecording: @escaping (UUID) -> Void) {
        self.store = store
        self.onOpenRecording = onOpenRecording
    }

    var body: some View {
        VStack(spacing: 0) {
            conversation
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Ask Jot")
        .toolbar {
            ToolbarItem {
                Button {
                    store.newChat()
                    draft = ""
                    composerFocused = true
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .help("New chat")
                .disabled(store.messages.isEmpty)
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if store.messages.isEmpty {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(store.messages) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                            if case .unavailable(let reason) = store.state {
                                notice(reason, icon: "sparkles.slash")
                            }
                            if case .error(let reason) = store.state {
                                notice(reason, icon: "exclamationmark.triangle")
                            }
                        }
                        .frame(maxWidth: column, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 28)
                    }
                }
            }
            .onChange(of: store.messages.last?.content) {
                guard let last = store.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .font(.system(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            assistantRow(message)
        }
    }

    @ViewBuilder
    private func assistantRow(_ message: ChatMessage) -> some View {
        let sources = store.sourcesByMessage[message.id] ?? []
        VStack(alignment: .leading, spacing: 14) {
            if message.isStreaming && message.content.isEmpty {
                thinking
            } else {
                Text(ChatMarkdown.render(
                    AskCitationParser.stripMarkers(from: message.content),
                    streaming: message.isStreaming
                ))
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !message.isStreaming, !sources.isEmpty {
                sourcesFooter(sources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sources

    private func sourcesFooter(_ sources: [AskCitationSource]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Sources")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(sources.enumerated()), id: \.offset) { offset, source in
                    Button { onOpenRecording(source.recordingID) } label: {
                        sourcePill(number: offset + 1, label: source.label)
                    }
                    .buttonStyle(.plain)
                    .help("Open recording")
                }
            }
        }
        .padding(.top, 2)
    }

    private func sourcePill(number: Int, label: String) -> some View {
        HStack(spacing: 6) {
            Text(String(number))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
            VStack(spacing: 6) {
                Text("Ask about your notes")
                    .font(.system(size: 20, weight: .semibold))
                Text("Search and summarize everything you've dictated — or ask how Jot works.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(Self.exampleQuestions, id: \.self) { example in
                    Button {
                        draft = example
                        composerFocused = true
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                            Text(example)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 28)
    }

    private static let exampleQuestions = [
        "Summarize what I recorded today",
        "What did I decide about the launch?",
        "Pull every note that mentions pricing",
    ]

    // MARK: - Thinking / notices

    private var thinking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Searching your notes…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func notice(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask about your notes or how Jot works…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .onSubmit(submit)
                    trailingButton
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            }
            .frame(maxWidth: column)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if case .streaming = store.state {
            Button(action: store.cancel) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            let disabled = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help("Send")
        }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .streaming = store.state { return }
        store.ask(trimmed)
        draft = ""
    }
}
