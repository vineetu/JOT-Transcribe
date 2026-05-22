import Foundation

/// One model entry returned by a provider's `/models` (or equivalent)
/// endpoint, normalized across the four providers Jot speaks to.
///
/// The free-form `id` is the value that flows into
/// `LLMConfiguration.modelBinding(for:)` and is what the user sees in
/// the picker. `displayName` is an optional human-friendly label (used
/// by Anthropic, which returns `display_name` next to the canonical
/// `id`); falls back to `id` when the provider doesn't expose one.
///
/// `tier` is `nil` when the provider's tier-classifier doesn't have a
/// pattern for this id (or when no classifier applies, e.g. Ollama).
struct DiscoveredModel: Codable, Hashable, Sendable {
    enum Tier: String, Codable, Sendable {
        case small
        case medium
        case large
    }

    let id: String
    let displayName: String?
    /// Whether this id contains a reasoning/thinking marker we'd like
    /// to hide from the latest-generation default-selection logic.
    /// Still kept in the discovered list (with `+ Show all models` the
    /// user can opt in), but excluded from the auto-default candidate
    /// pool.
    let isThinking: Bool
    /// Provider-specific tier hint computed at probe time. Used by
    /// the default-selection logic, never persisted.
    let tier: Tier?

    init(
        id: String,
        displayName: String? = nil,
        isThinking: Bool = false,
        tier: Tier? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isThinking = isThinking
        self.tier = tier
    }
}

/// Outcome of a single probe run. Distinguishes the failure modes the
/// UI cares about (and that the plan's status-line table enumerates):
///
///   - `success([])` — probe completed, zero usable models. Ollama-
///     specific: the daemon is reachable but nothing's pulled.
///   - `authFailure` — provider returned 401/403. Bad key or missing
///     scope. Combobox disables; status line goes red.
///   - `unreachable` — DNS / connection refused / 404. Custom endpoint
///     that doesn't speak the provider's `/models` shape, or daemon
///     not running. UI degrades to free-form typing.
///   - `networkError` — offline / transient. UI falls back to the
///     cached list if it has one.
enum ProbeResult: Sendable {
    case success([DiscoveredModel])
    case authFailure
    case unreachable
    case networkError(String)
}

/// Per-provider behaviour for model discovery. The four concrete
/// implementations live in this folder; the factory in
/// `ProbeRegistry` maps `LLMProvider` → instance.
///
/// `probe(...)` runs the network call. `discoverDefault(...)` walks
/// the returned list and picks the id that should pre-fill the
/// combobox (the "tier-hint" default-selection logic).
protocol AIProviderProbe: Sendable {
    /// Provider this probe handles. Matches the enum case in
    /// `LLMProvider`; the registry uses this to dispatch.
    var provider: LLMProvider { get }

    /// Tier classifier exposed publicly so the picker view can compute
    /// "is the stored model a custom entry or a discovered tier?"
    /// without re-implementing the regex.
    var classifier: TierClassifier { get }

    /// Run a single probe against `baseURL` with `apiKey`. The session
    /// is injected so harness tests can install `StubURLProtocol`.
    func probe(
        baseURL: String,
        apiKey: String,
        session: URLSession
    ) async -> ProbeResult

    /// Pick the model id that should pre-fill the combobox given a
    /// successful probe. The default implementation runs
    /// "latest-generation → small-tier-first" via the classifier;
    /// providers can override (Ollama doesn't have versions, so it
    /// just returns the first pulled model).
    func discoverDefault(probed: [DiscoveredModel]) -> String?
}

extension AIProviderProbe {
    func discoverDefault(probed: [DiscoveredModel]) -> String? {
        classifier.defaultPick(among: probed)
    }
}
