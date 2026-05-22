import Combine
import Foundation
import SwiftUI

/// Combined SwiftUI view for AI provider model selection. Owns the
/// probe orchestration, the model combobox, the endpoint disclosure,
/// the refresh affordance, and the "+ Show all models" toggle.
///
/// Used by both the wizard's AI provider step and Settings → AI.
/// Owns no AppStorage of its own — reads `LLMConfiguration` bindings
/// for `baseURL` and `model`, and reads keychain via the config's
/// `apiKey(for:)`. The cached `discoveredModels` per provider live in
/// AppStorage under `jot.llm.<provider>.discoveredModels`.
@MainActor
struct ProviderModelPicker: View {
    let provider: LLMProvider
    let urlSession: URLSession
    @ObservedObject var config: LLMConfiguration
    /// Bumped by the parent after a Test Connection run so the
    /// disclosure expands to show what got tested. Plumbed in
    /// rather than owned here because the parent is the one running
    /// the Test action.
    let justRanTestConnection: Bool

    @State private var probeState: ProbeState = .idle
    @State private var refreshTask: Task<Void, Never>?
    @State private var debounceTokens: [String: Task<Void, Never>] = [:]
    @State private var cachedModels: [DiscoveredModel] = []

    /// Provider-scoped persisted state. The view re-builds these
    /// `@AppStorage` properties when the provider changes by being
    /// re-instantiated from the parent (the parent keys this view on
    /// `provider`), so we can read the right bucket without runtime
    /// computed keys.
    private let cacheKey: String
    private let showAllKey: String

    init(
        provider: LLMProvider,
        urlSession: URLSession,
        config: LLMConfiguration,
        justRanTestConnection: Bool
    ) {
        self.provider = provider
        self.urlSession = urlSession
        self.config = config
        self.justRanTestConnection = justRanTestConnection
        self.cacheKey = "jot.llm.\(provider.rawValue).discoveredModels"
        self.showAllKey = "jot.llm.\(provider.rawValue).showAllModels"
    }

    private enum ProbeState: Equatable {
        case idle
        case loading
        case loaded(count: Int)
        case authFailed
        case unreachable
        case networkError(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelRow
            statusLine
            EndpointDisclosure(
                baseURL: config.baseURLBinding(for: provider),
                defaultBaseURL: provider.defaultBaseURL,
                justRanTestConnection: justRanTestConnection
            )
            showAllModelsRow
            if let catalogURL = provider.modelCatalogURL {
                Link("Browse models →", destination: catalogURL)
                    .font(.system(size: 11))
            }
        }
        .onAppear { loadCachedAndMaybeRefresh() }
        .onChange(of: config.baseURL(for: provider)) { _, _ in
            scheduleProbe(debounce: .milliseconds(1000), reason: "baseURL")
        }
        .onChange(of: config.apiKey(for: provider)) { _, _ in
            scheduleProbe(debounce: .milliseconds(500), reason: "apiKey")
        }
        .onDisappear {
            refreshTask?.cancel()
            for (_, task) in debounceTokens { task.cancel() }
            debounceTokens.removeAll()
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        HStack(spacing: 6) {
            ModelComboBox(
                selection: config.modelBinding(for: provider),
                suggestions: comboBoxSuggestions(),
                placeholder: placeholderText,
                isDisabled: probeState == .authFailed
            )
            .frame(maxWidth: .infinity)
            Button {
                refresh()
            } label: {
                if probeState == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(probeState == .loading)
            .help("Refresh the model list")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch probeState {
        case .idle:
            if !provider.requiresUserAPIKey || !config.apiKey(for: provider).isEmpty {
                Text(" ")
                    .font(.system(size: 11))
            } else {
                Text("Enter API key to see available models.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .loading:
            Text("Loading models…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .loaded(let count):
            if count == 0 && provider == .ollama {
                Text("No models found — run `ollama pull <name>` to add one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if count == 0 {
                Text("No models returned — type a model id to use a custom one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Auto-detected · \(count) model\(count == 1 ? "" : "s") available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .authFailed:
            Text("API key rejected — check the key and try again.")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        case .unreachable:
            Text("Couldn't list models — type one to use.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .networkError:
            Text(cachedModels.isEmpty
                ? "Offline — type a model id to use."
                : "Offline — using cached model list.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var showAllModelsRow: some View {
        // `+ Show all models` bypasses the latest-generation filter.
        // Survives across launches per-provider.
        let store = UserDefaults.standard
        let isOn = store.bool(forKey: showAllKey)
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                store.set(newValue, forKey: showAllKey)
                // Force redraw — `@AppStorage` would do this, but we
                // intentionally read straight from defaults here to
                // avoid declaring another wrapper that's specific to
                // a runtime-computed key.
                triggerRedraw.toggle()
            }
        )) {
            Text("Show all models (advanced)")
                .font(.system(size: 11))
        }
        .toggleStyle(.checkbox)
    }

    @State private var triggerRedraw: Bool = false

    private var placeholderText: String {
        if cachedModels.isEmpty {
            return provider.defaultModel.isEmpty ? "Model id" : provider.defaultModel
        }
        return provider.defaultModel
    }

    // MARK: - Suggestion list assembly

    /// The suggestions list shown in the combobox. Composed of:
    ///   1. The probed models, filtered by "+ Show all models".
    ///   2. The user's stored model if it isn't in the probed list
    ///      (so a custom proxy ID stays selectable).
    ///   3. The hardcoded `defaultModel` fallback when probe failed
    ///      and nothing's cached (optimistic-at-release-time).
    private func comboBoxSuggestions() -> [String] {
        let showAll = UserDefaults.standard.bool(forKey: showAllKey)
        let filtered = filtered(models: cachedModels, showAll: showAll)
        var ids = filtered.map { $0.id }

        // Add the currently-stored model if absent so it stays
        // selectable as a custom row.
        let stored = config.model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty && !ids.contains(stored) {
            ids.insert(stored, at: 0)
        }

        // If probe never succeeded AND there's no cache, fall back
        // to the optimistic default model so the picker isn't blank.
        if ids.isEmpty {
            let fallback = provider.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallback.isEmpty {
                ids.append(fallback)
            }
        }
        return ids
    }

    private func filtered(models: [DiscoveredModel], showAll: Bool) -> [DiscoveredModel] {
        if showAll {
            return models
        }
        // Default view: drop thinking models AND drop everything
        // that isn't on the latest detected generation. Falls back
        // to the unfiltered list if generation parsing fails for
        // every entry (Ollama, or a provider whose catalog shape
        // changed under us).
        guard let probe = ProbeRegistry.probe(for: provider) else { return models }
        let classifier = probe.classifier
        let nonThinking = models.filter { !$0.isThinking }
        guard let regex = classifier.latestGenRegex else {
            return nonThinking
        }
        let withKeys = nonThinking.compactMap { m -> (DiscoveredModel, String)? in
            guard let k = classifier.generationKey(for: m.id, regex: regex) else { return nil }
            return (m, k)
        }
        guard let maxKey = withKeys.map({ $0.1 }).max() else {
            return nonThinking
        }
        return withKeys.filter { $0.1 == maxKey }.map { $0.0 }
    }

    // MARK: - Probe orchestration

    private func loadCachedAndMaybeRefresh() {
        cachedModels = loadCachedModels()
        // If we have nothing cached and the provider can probe (key
        // present, or no key required), fire one. Otherwise stay
        // idle and rely on the user's first action to trigger a
        // probe (entering a key, hitting refresh, etc.).
        let needsKey = provider.requiresUserAPIKey
        let haveKey = !config.apiKey(for: provider).isEmpty
        if cachedModels.isEmpty {
            if !needsKey || haveKey {
                refresh()
            }
        } else {
            // Stale-while-revalidate: surface cache immediately,
            // refresh in background.
            probeState = .loaded(count: cachedModels.count)
            if !needsKey || haveKey {
                refresh(silent: true)
            }
        }
    }

    private func scheduleProbe(debounce: Duration, reason: String) {
        // Cancel any in-flight debounced probe for the same reason
        // so the last edit wins.
        debounceTokens[reason]?.cancel()
        let task = Task { [reason] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debounceTokens.removeValue(forKey: reason)
                refresh()
            }
        }
        debounceTokens[reason] = task
    }

    private func refresh(silent: Bool = false) {
        refreshTask?.cancel()
        guard let probe = ProbeRegistry.probe(for: provider) else {
            probeState = .unreachable
            return
        }
        let baseURL = config.effectiveBaseURL(for: provider)
        let apiKey = config.apiKey(for: provider)
        // No key + cloud provider = nothing to do. Keep the picker
        // in "enter key to see available models" idle state.
        if provider.requiresUserAPIKey && apiKey.isEmpty {
            probeState = .idle
            return
        }
        if !silent {
            probeState = .loading
        }
        let session = urlSession
        refreshTask = Task {
            let result = await probe.probe(
                baseURL: baseURL,
                apiKey: apiKey,
                session: session
            )
            await MainActor.run {
                applyProbeResult(result)
            }
        }
    }

    private func applyProbeResult(_ result: ProbeResult) {
        switch result {
        case .success(let models):
            cachedModels = models
            persistCachedModels(models)
            probeState = .loaded(count: models.count)
            adoptDefaultIfNeeded(models: models)
        case .authFailure:
            probeState = .authFailed
        case .unreachable:
            probeState = .unreachable
        case .networkError(let detail):
            probeState = .networkError(detail)
        }
    }

    /// If the user's stored model is empty (fresh install) OR matches
    /// the hardcoded `defaultModel` (still the optimistic value),
    /// adopt the discovered tier-hinted default. Don't trample a
    /// custom selection: anything the user actively typed survives.
    private func adoptDefaultIfNeeded(models: [DiscoveredModel]) {
        let stored = config.model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored.isEmpty || stored == provider.defaultModel else { return }
        guard let probe = ProbeRegistry.probe(for: provider) else { return }
        if let pick = probe.discoverDefault(probed: models) {
            config.setModel(pick, for: provider)
        }
    }

    // MARK: - Cache persistence

    private func loadCachedModels() -> [DiscoveredModel] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else {
            return []
        }
        return (try? JSONDecoder().decode([DiscoveredModel].self, from: data)) ?? []
    }

    private func persistCachedModels(_ models: [DiscoveredModel]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
