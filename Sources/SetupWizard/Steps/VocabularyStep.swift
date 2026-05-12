import SwiftUI

/// Step 8 — Optional custom-vocabulary primer. Sits between the
/// terminal `.done` basics card and `.aiProvider` so users who opt
/// into the advanced flow can drop in product names, proper nouns,
/// and jargon they want Jot to prefer before any AI setup.
///
/// UX contract:
///   • Always Skippable — vocabulary is opt-in and never blocks the
///     rest of the wizard. Continue advances regardless of term count
///     or boost-model state.
///   • Reuses `VocabularyStore.shared` so terms entered here show up
///     unchanged in Settings → Vocabulary post-wizard.
///   • Auto-enables `store.isEnabled` the first time the user adds a
///     term, so a user who walks away from the wizard with their list
///     populated doesn't also have to remember to toggle the master
///     switch later.
///   • Surfaces the boost-model download state inline — vocabulary
///     boosting can't run until the CTC 110M bundle is on disk.
///   • Warns when the primary model is Japanese (vocabulary boosting
///     doesn't apply to the JA path); does not block the step.
struct VocabularyStep: View {
    @EnvironmentObject private var coordinator: SetupWizardCoordinator
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @StateObject private var store = VocabularyStore.shared
    @FocusState private var focusedID: VocabTerm.ID?
    @State private var boostStatus: BoostModelStatus = .notDownloaded

    private var lockedForJAPrimary: Bool {
        transcriberHolder.primaryModelID == .tdt_0_6b_ja
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add custom vocabulary")
                    .font(.system(size: 22, weight: .semibold))
                Text("Words Jot should prefer when transcribing — product names, proper nouns, jargon. Boosting runs entirely on-device. Skip if you don't need this; you can edit the list any time in Settings → Vocabulary.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)

            if lockedForJAPrimary {
                japaneseWarning
            }

            boostModelCard

            termsCard

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Pick up any terms the user edited externally between
            // wizard runs (matches the pane's behaviour).
            store.load()
            refreshBoostStatus()
            coordinator.setChrome(
                WizardStepChrome(
                    primaryTitle: "Continue",
                    canAdvance: true,
                    isPrimaryBusy: false,
                    showsSkip: true
                )
            )
        }
    }

    // MARK: - Boost model card

    @ViewBuilder
    private var boostModelCard: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(boostHeadline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(boostHeadlineColor)
                Text(boostSubtext)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            boostAction
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private var boostHeadline: String {
        switch boostStatus {
        case .ready:          return "Boost model ready"
        case .downloading:    return "Downloading boost model…"
        case .notDownloaded:  return "Boost model not downloaded"
        case .failed(let m):  return "Boost unavailable — \(m)"
        }
    }

    private var boostHeadlineColor: Color {
        switch boostStatus {
        case .failed: return .red
        default:      return .primary
        }
    }

    private var boostSubtext: String {
        switch boostStatus {
        case .ready:
            return "Vocabulary boosting will run locally on your next recording."
        case .downloading:
            return "≈100 MB from Hugging Face. You can keep using the wizard while it finishes."
        case .notDownloaded:
            return "One-time ≈100 MB download. Required for vocabulary terms to take effect."
        case .failed:
            return "Retry below; if it still fails, check your internet connection."
        }
    }

    @ViewBuilder
    private var boostAction: some View {
        switch boostStatus {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .accessibilityLabel("Ready")
        case .downloading:
            ProgressView().controlSize(.small)
        case .notDownloaded, .failed:
            Button("Download") {
                Task { await downloadBoost() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Terms card

    @ViewBuilder
    private var termsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.terms.isEmpty {
                emptyState
            } else {
                ForEach(store.terms) { term in
                    VocabRow(
                        term: binding(for: term.id),
                        focused: $focusedID,
                        onDelete: { delete(term.id) }
                    )
                }
            }

            HStack {
                Button {
                    addTerm()
                } label: {
                    Label("Add Term", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if !store.terms.isEmpty {
                    Text("\(store.terms.count) term\(store.terms.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Text("No terms yet.")
                .font(.system(size: 12, weight: .medium))
            Text("Add names and acronyms Jot should get right.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - JA warning

    private var japaneseWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Custom vocabulary isn't supported when the primary transcription model is Japanese. You can still enter terms — they'll apply once you switch to a European model.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    // MARK: - Actions

    private func refreshBoostStatus() {
        boostStatus = CtcModelCache.shared.isCached ? .ready : .notDownloaded
    }

    private func downloadBoost() async {
        boostStatus = .downloading
        do {
            _ = try await CtcModelCache.shared.ensureLoaded()
            boostStatus = .ready
            // If boosting is already enabled (either the user just
            // enabled it via addTerm, or a returning user already had
            // it on), prepare the live rescorer now so it actually
            // applies on the next recording. VocabularyPane wires the
            // same hook after its download.
            if store.isEnabled {
                await prepareRescorerIfPossible()
            }
        } catch {
            await ErrorLog.shared.error(
                component: "SetupWizard",
                message: "Vocabulary boost model download failed (wizard)",
                context: ["error": ErrorLog.redactedAppleError(error)]
            )
            boostStatus = .failed(error.localizedDescription)
        }
    }

    /// Mirrors `VocabularyPane.prepareRescorerIfPossible()`. Required
    /// so terms entered in the wizard actually affect the next
    /// recording — `VocabularyStore.save()` only rebuilds the
    /// rescorer when one has been prepared, and prepare is the only
    /// path that loads the CTC model into memory. Without this call
    /// the wizard would leave the store enabled but the live
    /// rescorer inert until the user happened to open Settings →
    /// Vocabulary or restart Jot.
    private func prepareRescorerIfPossible() async {
        guard let url = store.fileURL else { return }
        guard CtcModelCache.shared.isCached else {
            boostStatus = .notDownloaded
            return
        }
        do {
            try await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: url)
        } catch {
            // Holder has already logged the specific failure. Surface
            // it on the wizard step so the user sees a clear signal
            // instead of a stale "ready" pill.
            boostStatus = .failed(error.localizedDescription)
        }
    }

    private func addTerm() {
        let new = store.addBlankTerm()
        // Auto-flip the master toggle on first add — but only during
        // the initial setup wizard, and never when the JA model is
        // primary (Settings disables the toggle in that state, so we
        // would otherwise create an enabled-but-locked configuration
        // the pane would refuse to expose). The FirstRunState guard
        // mirrors AIProviderStep — returning users who deliberately
        // turned vocabulary OFF must toggle it themselves in
        // Settings → Vocabulary.
        if !store.isEnabled,
           !FirstRunState.shared.setupComplete,
           !lockedForJAPrimary {
            store.isEnabled = true
            // If the boost model is already cached, prepare the
            // rescorer now so the very first term applies on the next
            // recording. If not cached, the user-driven Download
            // button will trigger prepareRescorerIfPossible() once
            // it completes.
            if CtcModelCache.shared.isCached {
                Task { await prepareRescorerIfPossible() }
            }
        }
        // Focus lands inside the row's term field after the ForEach
        // rebuilds — a short runloop hop is enough for SwiftUI to
        // install the focus proxy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedID = new.id
        }
    }

    private func delete(_ id: VocabTerm.ID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            store.delete(id: id)
        }
    }

    private func binding(for id: VocabTerm.ID) -> Binding<VocabTerm> {
        Binding(
            get: { store.terms.first(where: { $0.id == id }) ?? VocabTerm(text: "") },
            set: { newValue in
                store.update(id: id, text: newValue.text, aliases: newValue.aliases)
            }
        )
    }
}
