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
/// jargon. Each row is one visible term input; the v1.5 expandable
/// "sounds-like" alias field was removed for MVP and will return later
/// (the `VocabTerm.aliases` array persists unchanged so no migration is
/// needed when we add it back).
///
/// MVP scope: UI + file-based persistence only. The actual CTC rescoring
/// pipeline (downloading the 97.5 MB CTC encoder bundle, wiring
/// `VocabularyRescorer.ctcTokenRescore` into `Transcriber`) is Phase B;
/// today the list is persisted and visible so the user can validate the
/// UI shape before we pay the model-download engineering cost.
struct VocabularyPane: View {
    @StateObject private var store = VocabularyStore.shared
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @FocusState private var focusedID: VocabTerm.ID?
    @Environment(\.helpNavigator) private var navigator
    @State private var boostModelStatus: BoostModelStatus = .notDownloaded
    /// v1.16: when Advanced is on, each term row exposes an inline
    /// "sounds-like" alias editor (the heard → term mapping). Off keeps the
    /// baseline single-field rows. Gating happens in `VocabRow`; the pane
    /// only adds an explanatory line above the list.
    @AppStorage(AdvancedFlag.storageKey) private var advancedEnabled: Bool = false

    /// True when JA is the active primary. JA is no longer locked
    /// (v1.12 ships alias-based substitution via
    /// `JapaneseVocabularySubstituter`), but the pane still surfaces a
    /// JA-specific note so users know the experience differs from the
    /// acoustic CTC path: aliases drive the substitution, and aliases
    /// must be written via the file directly until the inline alias
    /// UI returns.
    private var isJAPrimary: Bool {
        transcriberHolder.primaryModelID == .tdt_0_6b_ja
    }

    /// True when one of the experimental Qwen3 languages (Mandarin / Cantonese
    /// / Vietnamese) is active. Custom vocabulary is OFF for this engine — the
    /// CTC-110M acoustic spotter is Latin/English-oriented, so the gate does
    /// not run and `Qwen3Transcriber` returns no corrections. The pane surfaces
    /// a note so the user isn't surprised that their list is inert.
    private var isQwen3Primary: Bool {
        transcriberHolder.primaryModelID == .qwen3_multilingual
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                headerSection
                    .id("custom-vocabulary")
                boostModelSection
                Section {
                    if store.terms.isEmpty {
                        emptyStateView
                    } else {
                        if advancedEnabled && !isJAPrimary {
                            Text("Under each term, add the ways Jot mis-hears it (\u{201c}sounds-like\u{201d}) so it maps them back to your spelling.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 2)
                        }
                        ForEach(store.terms) { term in
                            VocabRow(
                                term: binding(for: term.id),
                                focused: $focusedID,
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
                consumePendingSettingsFieldAnchor(with: proxy)
            }
            .onChange(of: store.isEnabled) { _, enabled in
                if enabled { Task { await prepareRescorerIfPossible() } }
                else { Task { await VocabularyRescorerHolder.shared.unload() } }
            }
            .onChange(of: navigator.pendingSettingsFieldAnchor) { _, _ in
                consumePendingSettingsFieldAnchor(with: proxy)
            }
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Toggle("Enable vocabulary boosting", isOn: $store.isEnabled)
                                .toggleStyle(.switch)
                                .font(.system(size: 13))
                            ExperimentalBadge()
                        }
                        Text(headerSubtext)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    InfoPopoverButton(
                        title: "Custom vocabulary",
                        body: "A short list of words Jot should prefer — product names, company names, technical jargon. When on, Jot scans each recording for these terms and replaces common misfires (\"you jet\" → \"UJET\") with your canonical spelling. Entirely on-device. Keep the list small (under 100 terms) for best results.\n\nExperimental — two paths depending on your primary model:\n\n• Parakeet v3, v2, and Nemotron (English): acoustic CTC matching. Catches phonetic neighbors automatically.\n\n• Japanese: alias-based text substitution. Write your canonical spelling as a term, then add the writing systems the model might output as aliases (hiragana / katakana / romaji). Aliases drive the substitution. The inline alias UI was removed for MVP; for now, add aliases by editing the vocabulary file directly (one line per term: `Term: alias1, alias2`).",
                        helpAnchor: "custom-vocabulary"
                    )
                }
                if isJAPrimary {
                    revealVocabularyFileButton
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// JA-only affordance: open the vocabulary file in Finder. Aliases
    /// drive the JA substitution path and the inline alias UI is
    /// dormant; users edit the file directly until the UI returns.
    private var revealVocabularyFileButton: some View {
        Button {
            if let url = VocabularyStore.shared.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } label: {
            Label("Reveal vocabulary file in Finder", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 12))
        }
        .controlSize(.small)
    }

    private var headerSubtext: String {
        if isQwen3Primary {
            return "Custom vocabulary isn’t available for Mandarin, Cantonese, or Vietnamese yet — the boosting engine is English/Latin-oriented. Your terms are kept but won’t affect these transcripts. Switch to an English or European language to use boosting."
        }
        if isJAPrimary {
            return store.isEnabled
                ? "Japanese support uses alias substitution. Write your canonical spelling as a term, then add the writing systems the model might output (hiragana, katakana, romaji) as aliases by editing the vocabulary file."
                : "When on, Jot substitutes alias spellings for the canonical term in Japanese transcripts. Add your canonical spelling as a term, then add aliases (hiragana, katakana, romaji variants) by editing the vocabulary file."
        }
        return store.isEnabled
            ? "Jot will prefer the terms below when transcribing. Add product names, proper nouns, and jargon you want spelled a specific way."
            : "When on, Jot prefers these terms during transcription. Edit the list anytime; boosting applies on your next recording."
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
        // Focus lands inside the row's term field after the ForEach
        // rebuilds — a short runloop hop is enough for SwiftUI to
        // install the focus proxy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedID = new.id
        }
    }

    private func consumePendingSettingsFieldAnchor(with proxy: ScrollViewProxy) {
        guard navigator.pendingSettingsFieldAnchor == "custom-vocabulary" else { return }
        withAnimation {
            proxy.scrollTo("custom-vocabulary", anchor: .top)
        }
        navigator.clearPendingSettingsFieldAnchor()
    }

    private func delete(_ id: VocabTerm.ID) {
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
