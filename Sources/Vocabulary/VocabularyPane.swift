import SwiftUI

/// Boost-model download state, surfaced to the pane so the user can see
/// what's happening. Pre-installed state lives in `CtcModelCache.shared`
/// — this enum captures the UI-visible transitions around it.
enum BoostModelStatus: Equatable {
    case notDownloaded
    case downloading
    case ready
    case failed(String)
}

/// Settings pane that holds the user's custom vocabulary list.
///
/// Product intent (see docs/research/ctc-vocabulary-boosting.md §7): a
/// short list of terms Jot should prefer — product names, proper nouns,
/// jargon. 80% of entries are just the term; 20% carry a "sounds like"
/// alias list. Row design follows Things / Linear — collapsed rows show
/// just the term, clicking unfolds the row to reveal the aliases field
/// in place. No text editor, no pipe-separated syntax in the primary path.
///
/// MVP scope: UI + file-based persistence only. The actual CTC rescoring
/// pipeline (downloading the 97.5 MB CTC encoder bundle, wiring
/// `VocabularyRescorer.ctcTokenRescore` into `Transcriber`) is Phase B;
/// today the list is persisted and visible so the user can validate the
/// UI shape before we pay the model-download engineering cost.
struct VocabularyPane: View {
    @StateObject private var store = VocabularyStore.shared
    @State private var expandedID: VocabTerm.ID?
    @FocusState private var focusedID: VocabTerm.ID?
    @State private var boostModelStatus: BoostModelStatus = .notDownloaded

    var body: some View {
        Form {
            headerSection
            boostModelSection
            Section {
                if store.terms.isEmpty {
                    emptyStateView
                } else {
                    ForEach(store.terms) { term in
                        VocabRow(
                            term: binding(for: term.id),
                            isExpanded: expandedID == term.id,
                            focused: $focusedID,
                            onToggle: { toggle(term.id) },
                            onDelete: { delete(term.id) }
                        )
                    }
                }
                addTermButton
            }
            if !store.terms.isEmpty { statusFooter }
        }
        .formStyle(.grouped)
        .onAppear {
            // Reload from disk in case the user edited the vocabulary
            // file externally (vi, VS Code, etc.) since the last time
            // the pane was opened. `VocabularyStore.shared` is a
            // process-lifetime singleton and only loads once at init
            // without this — which otherwise means external edits are
            // invisible until the app relaunches.
            store.load()
            refreshBoostModelStatus()
        }
        .onChange(of: store.isEnabled) { _, enabled in
            if enabled { Task { await prepareRescorerIfPossible() } }
            else { Task { await VocabularyRescorerHolder.shared.unload() } }
        }
    }

    // MARK: - Boost-model section

    private var boostModelSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(boostModelHeadline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(boostModelHeadlineColor)
                    Text(boostModelSubtext)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                boostModelAction
            }
            .padding(.vertical, 2)
        }
    }

    private var boostModelHeadline: String {
        switch boostModelStatus {
        case .ready:          return "Boost model ready"
        case .downloading:    return "Downloading boost model…"
        case .notDownloaded:  return "Boost model not downloaded"
        // Intentionally "Boost unavailable" (not "Download failed") — a
        // .failed state can come from a download error OR from a later
        // tokenizer/rescorer build error once the bundle is already on
        // disk. The raw message carries the specific reason.
        case .failed(let m):  return "Boost unavailable — \(m)"
        }
    }

    private var boostModelHeadlineColor: Color {
        switch boostModelStatus {
        case .ready:     return .primary
        case .failed:    return .red
        default:         return .primary
        }
    }

    private var boostModelSubtext: String {
        switch boostModelStatus {
        case .ready:
            return "Parakeet CTC 110M on disk. Boosting runs locally on the Neural Engine; no audio leaves your Mac."
        case .downloading:
            return "≈100 MB from Hugging Face over HTTPS. You can keep using Jot while it finishes — boosting activates once it's ready."
        case .notDownloaded:
            return "One-time ≈100 MB download. Required for vocabulary boosting to take effect on transcriptions."
        case .failed:
            return "The rest of Jot keeps working — only vocabulary boosting needs this bundle. Retry below; if it still fails, check your internet or remove the cached model (~/Library/Application Support/Jot/Models/)."
        }
    }

    @ViewBuilder
    private var boostModelAction: some View {
        switch boostModelStatus {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .accessibilityLabel("Ready")
        case .downloading:
            ProgressView().controlSize(.small)
        case .notDownloaded, .failed:
            Button("Download") {
                Task { await downloadBoostModel() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func refreshBoostModelStatus() {
        // Guard against drift: if the cache was deleted externally
        // while the pane was open, reflect that so the user can re-
        // download instead of the UI claiming .ready and silently
        // failing on every record.
        boostModelStatus = CtcModelCache.shared.isCached ? .ready : .notDownloaded
    }

    private func downloadBoostModel() async {
        boostModelStatus = .downloading
        do {
            _ = try await CtcModelCache.shared.ensureLoaded()
            boostModelStatus = .ready
            if store.isEnabled {
                await prepareRescorerIfPossible()
            }
        } catch {
            boostModelStatus = .failed(error.localizedDescription)
        }
    }

    private func prepareRescorerIfPossible() async {
        // Re-check the cache: `CtcModelCache.shared` may have been
        // invalidated by a concurrent path (e.g. prior load failure
        // cleared the cache). Refresh the UI state before attempting
        // to prepare, so a failed prepare leaves the user on a
        // correct "not downloaded" row instead of a stale "ready".
        guard let url = store.fileURL else { return }
        guard CtcModelCache.shared.isCached else {
            boostModelStatus = .notDownloaded
            return
        }
        do {
            try await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: url)
        } catch {
            // Holder has already logged the specific failure. Surface
            // it on the pane so the user sees a clear signal — without
            // this, a failed prepare leaves the master toggle "on" but
            // silently does nothing on every recording.
            boostModelStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Enable vocabulary boosting", isOn: $store.isEnabled)
                        .toggleStyle(.switch)
                        .font(.system(size: 13))
                    Text(store.isEnabled
                         ? "Jot will prefer the terms below when transcribing. Add product names, proper nouns, and jargon you want spelled a specific way."
                         : "When on, Jot prefers these terms during transcription. Edit the list anytime; boosting applies on your next recording.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                InfoPopoverButton(
                    title: "Custom vocabulary",
                    body: "A short list of words Jot should prefer — product names, company names, technical jargon. When on, Jot scans each recording for these terms and replaces common misfires (\"you jet\" → \"UJET\") with your canonical spelling. Entirely on-device. Keep the list small (under 100 terms) for best results.",
                    helpAnchor: "help.dictation.vocabulary"
                )
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
            Text("No vocabulary yet.")
                .font(.system(size: 14, weight: .medium))
            Text("Add names and acronyms Jot should get right.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var addTermButton: some View {
        Button {
            addTerm()
        } label: {
            Label("Add Term", systemImage: "plus")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var statusFooter: some View {
        Section {
            HStack {
                Text("\(store.terms.count) term\(store.terms.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func addTerm() {
        let new = store.addBlankTerm()
        expandedID = new.id
        // Focus lands inside the row's term field after the ForEach
        // rebuilds — a short runloop hop is enough for SwiftUI to
        // install the focus proxy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedID = new.id
        }
    }

    private func toggle(_ id: VocabTerm.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedID = (expandedID == id) ? nil : id
        }
    }

    private func delete(_ id: VocabTerm.ID) {
        if expandedID == id { expandedID = nil }
        withAnimation(.easeInOut(duration: 0.15)) {
            store.delete(id: id)
        }
    }

    /// Returns a binding that reads from the store and writes through
    /// `update(id:text:aliases:)` so every keystroke is persisted
    /// without the row having to know about the store.
    private func binding(for id: VocabTerm.ID) -> Binding<VocabTerm> {
        Binding(
            get: { store.terms.first(where: { $0.id == id }) ?? VocabTerm(text: "") },
            set: { newValue in
                store.update(id: id, text: newValue.text, aliases: newValue.aliases)
            }
        )
    }
}
