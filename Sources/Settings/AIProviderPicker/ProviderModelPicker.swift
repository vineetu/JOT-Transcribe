import Combine
import Foundation
import SwiftUI

/// AI provider model picker. Read-only catalog for OpenAI / Anthropic /
/// Gemini (their `/v1/models` endpoints are auth-gated, so an unauthed
/// probe isn't possible); live local probe for Ollama
/// (`localhost:11434/api/tags`, no auth). One "Advanced" disclosure hides
/// the custom endpoint field and the vendor docs link.
///
/// **Selection is write-once.** The picker reads `config.model(for:)` for
/// the current selection and falls back to `ModelCatalog.defaultOption`
/// when nothing is stored — *without* persisting the fallback. The user's
/// stored pick is never overwritten by catalog updates, refresh, or page
/// re-mounts. (The old probe path called `adoptDefaultIfNeeded` on every
/// refresh, which stomped user selections — that's deleted.)
@MainActor
struct ProviderModelPicker: View {
    let provider: LLMProvider
    let urlSession: URLSession
    @ObservedObject var config: LLMConfiguration
    /// Bumped by the parent after a Test Connection run so the Advanced
    /// disclosure auto-expands to show the endpoint that got tested.
    let justRanTestConnection: Bool

    @State private var ollamaModels: [String] = []
    @State private var ollamaError: String? = nil
    @State private var isProbingOllama: Bool = false
    @State private var probeTask: Task<Void, Never>? = nil
    @State private var userExpandedAdvanced: Bool = false

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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelRow
            statusLine
            advancedDisclosure
        }
        .onAppear {
            if provider == .ollama { probeOllama() }
        }
        .onDisappear {
            probeTask?.cancel()
        }
    }

    // MARK: - Model picker row

    @ViewBuilder
    private var modelRow: some View {
        HStack(spacing: 8) {
            if availableModels.isEmpty && provider == .ollama {
                Text(isProbingOllama
                     ? "Loading models from Ollama…"
                     : "No models found — run `ollama pull <name>` to add one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Model", selection: pickerBinding) {
                    ForEach(availableModels, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if provider == .ollama {
                Button {
                    probeOllama(force: true)
                } label: {
                    if isProbingOllama {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProbingOllama)
                .help("Refresh the list of installed Ollama models")
            }
        }
    }

    /// The list of model IDs the picker presents.
    /// - For cloud vendors: the hard-coded `ModelCatalog`, plus the user's
    ///   stored model if it's not in the catalog (so legacy/custom picks
    ///   stay selectable).
    /// - For Ollama: whatever the local `/api/tags` probe returned,
    ///   plus the user's stored model (if any) prepended so it stays
    ///   selectable across refreshes.
    private var availableModels: [String] {
        var ids: [String]
        switch provider {
        case .ollama:
            ids = ollamaModels
        default:
            ids = ModelCatalog.options(for: provider)
        }
        let stored = config.model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty && !ids.contains(stored) {
            ids.insert(stored, at: 0)
        }
        return ids
    }

    /// Binding that surfaces the stored model when present and the catalog
    /// default otherwise. The default is *never written through* — only the
    /// `set` side ever touches AppStorage, and only on real user action.
    private var pickerBinding: Binding<String> {
        Binding(
            get: {
                let stored = config.model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stored.isEmpty { return stored }
                return ModelCatalog.defaultOption(for: provider)
            },
            set: { newValue in
                config.setModel(newValue, for: provider)
            }
        )
    }

    // MARK: - Status line

    @ViewBuilder
    private var statusLine: some View {
        switch provider {
        case .ollama:
            if let ollamaError {
                Text(ollamaError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if !ollamaModels.isEmpty {
                Text("\(ollamaModels.count) model\(ollamaModels.count == 1 ? "" : "s") installed locally")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(" ").font(.system(size: 11))  // reserve space
            }
        case .openai, .anthropic, .gemini:
            if !config.apiKey(for: provider).isEmpty {
                Text(" ").font(.system(size: 11))  // reserve space
            } else {
                Text("Enter your API key below to start using \(provider.displayName).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .appleIntelligence:
            EmptyView()
        #if JOT_FLAVOR_1
        case .flavor1:
            EmptyView()
        #endif
        }
    }

    // MARK: - Advanced disclosure

    @ViewBuilder
    private var advancedDisclosure: some View {
        let hasCustomEndpoint: Bool = {
            let url = config.baseURL(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
            return !url.isEmpty && url != provider.defaultBaseURL
        }()
        let showsCustomModel = provider != .ollama && provider != .appleIntelligence
        #if JOT_FLAVOR_1
        let cloudProvider = showsCustomModel && provider != .flavor1
        #else
        let cloudProvider = showsCustomModel
        #endif

        VStack(alignment: .leading, spacing: 8) {
            // Full-row clickable header. The whole HStack — chevron +
            // "Advanced" text + trailing whitespace — toggles the
            // disclosure. SwiftUI's `DisclosureGroup` only makes the
            // chevron a tap target on macOS, which is a tiny click target
            // and feels broken. Rolling our own button gives the entire
            // row a hit area. The expanded state is owned solely by
            // `userExpandedAdvanced` — no auto-open on stored custom
            // values — so clicking always toggles open/closed predictably.
            Button {
                userExpandedAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: userExpandedAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Advanced")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if userExpandedAdvanced {
                VStack(alignment: .leading, spacing: 12) {
                    if cloudProvider {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom model ID")
                                .font(.system(size: 11, weight: .medium))
                            TextField(
                                "e.g. gpt-5-turbo-2024-04-09 or a proxy-specific name",
                                text: config.modelBinding(for: provider)
                            )
                            .textFieldStyle(.roundedBorder)
                            Text("Type any model id your provider exposes. Overrides the picker selection above.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom endpoint")
                            .font(.system(size: 11, weight: .medium))
                        TextField(
                            "Base URL (leave empty for default)",
                            text: config.baseURLBinding(for: provider)
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("Route requests through a company gateway or self-hosted OpenAI-compatible API. Default: \(provider.defaultBaseURL)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if hasCustomEndpoint {
                            Button("Reset to default") {
                                config.setBaseURL("", for: provider)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                    if let catalogURL = provider.modelCatalogURL {
                        Link("Browse \(provider.displayName) models →", destination: catalogURL)
                            .font(.system(size: 11))
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    // MARK: - Ollama probe

    private func probeOllama(force: Bool = false) {
        guard provider == .ollama, !isProbingOllama || force else { return }
        probeTask?.cancel()
        isProbingOllama = true
        ollamaError = nil
        let session = urlSession
        let baseURL = config.effectiveBaseURL(for: .ollama)
        let probe = OllamaProbe()
        probeTask = Task { @MainActor in
            let result = await probe.probe(baseURL: baseURL, apiKey: "", session: session)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let models):
                ollamaModels = models.map { $0.id }.sorted()
                ollamaError = nil
            case .authFailure:
                ollamaError = "Ollama refused the request — check your local config."
            case .unreachable:
                ollamaError = "Ollama isn't running on \(baseURL) — start it with `ollama serve`."
            case .networkError:
                ollamaError = "Couldn't reach Ollama locally."
            }
            isProbingOllama = false
        }
    }
}
