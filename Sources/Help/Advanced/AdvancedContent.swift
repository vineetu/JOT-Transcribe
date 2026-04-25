import SwiftUI

/// Canonical data model for Advanced-tab cards (spec v1 §6).
///
/// Every card has:
///   * `id` — slug matching the `Feature` registry entry (§14).
///   * `title` — bold card headline.
///   * `badge` — short monospaced category (e.g. "default", "cloud", "on/off").
///   * `body` — 2-line summary rendered under the title/badge row.
///   * `expansionProse` — 1-2 sentences shown when the card is expanded.
///
/// Search is performed via `HelpSearchable.searchableText` across title,
/// badge, body, and expansionProse. Keep prose authored under the same
/// 120-char / single-sentence sensibility the rest of the Help redesign
/// uses.
struct AdvancedCardData: Identifiable, Hashable, HelpSearchable {
    /// Slug — must match a `Feature.bySlug(_:)` entry on the Advanced tab.
    let id: String
    let title: String
    let badge: String
    let body: String
    /// Prose shown when the card is expanded. 1-2 sentences. Flagged with
    /// a TODO comment in-source where content-polish is still pending.
    let expansionProse: String

    /// `HelpSearchable` conformance — the slug used by `Feature.bySlug`.
    var slug: String { id }

    /// `HelpSearchable` conformance — every user-facing text field flattened
    /// so `HelpSearchState.matches(_:)` can substring-match any of them.
    var searchableText: [String] { [title, badge, body, expansionProse] }
}

/// A named section on the Advanced tab. Title + subtitle + a run of cards.
struct AdvancedSection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let cards: [AdvancedCardData]
}

// MARK: - Catalog

enum AdvancedContent {

    /// All Advanced sections in display order. Four total — AI providers,
    /// System, Input, Sounds. Card counts and slugs mirror spec §6 and §14.
    static let sections: [AdvancedSection] = [
        aiProviders,
        system,
        input,
        sounds,
    ]

    /// Every Advanced card, flattened from the sections. Used by tests that
    /// want to assert slug coverage against `Feature.all(on: .advanced)`.
    static var allCards: [AdvancedCardData] {
        sections.flatMap(\.cards)
    }

    // MARK: Sections

    private static let aiProviders = AdvancedSection(
        id: "ai-providers",
        title: "AI providers",
        subtitle: "Pick who does Cleanup and Articulate. Mix on-device, local, and cloud as you like.",
        cards: [
            AdvancedCardData(
                id: "ai-apple-intelligence",
                title: "Apple Intelligence",
                badge: "default",
                body: "On-device, private, free. Improving with each macOS release.",
                expansionProse:
                    "Runs entirely on your Mac via the on-device FoundationModels framework. "
                    + "No API key, no network, no data leaves your Mac. Quality for long-form "
                    + "Cleanup trails cloud models today — switch providers for paragraphs+."
            ),
            AdvancedCardData(
                id: "ai-cloud-providers",
                title: "OpenAI · Anthropic · Gemini",
                badge: "cloud",
                body: "Best quality today. Bring your own API key.",
                expansionProse:
                    "Three cloud providers are built in. Choose one in Settings → AI, paste your "
                    + "API key (stored in Keychain, never on disk), and pick a model. Cloud "
                    + "requests are scoped to Cleanup and Articulate — the dictation path stays on-device."
            ),
            AdvancedCardData(
                id: "ai-ollama",
                title: "Ollama",
                badge: "local",
                body: "Run any model locally. Bring your own hardware.",
                expansionProse:
                    "Jot talks to http://localhost:11434 by default. Install Ollama, pull a model "
                    + "(llama3.1, qwen2.5, etc.), and point Jot at it. No API key, no cloud traffic."
            ),
            AdvancedCardData(
                id: "ai-custom-base-url",
                title: "Custom base URL",
                badge: "byo",
                body: "Route through your own endpoint. OpenAI-compatible APIs work.",
                expansionProse:
                    "Override the base URL to point at a self-hosted gateway, a VPN-scoped "
                    + "endpoint, or any OpenAI-compatible API. Model name and auth header are "
                    + "configurable alongside the URL."
            ),
            AdvancedCardData(
                id: "ai-editable-prompts",
                title: "Editable prompts",
                badge: "power",
                body: "Tune the Cleanup and Articulate system prompts. Reset available.",
                expansionProse:
                    "Jot has two separate system prompts. Cleanup's prompt (Settings → AI → Customize prompt) controls how dictation transcripts get tidied up — disfluencies, punctuation, grammar. Articulate's Shared system prompt (Settings → AI → Shared system prompt) is the foundation of every rewrite, used by both Articulate (Fixed) and Articulate (Custom). Editing one does not affect the other. "
                    + "\n\nOn top of the Shared system prompt, Jot appends a short branch-specific tendency chosen automatically by the intent classifier — voice-preserving, shape change, translation, or code — based on your voice instruction. The appended tendency is not user-editable. "
                    + "\n\nEvery provider uses the same two prompts, so edits here apply uniformly across Apple Intelligence, OpenAI, Anthropic, Gemini, and Ollama. Both editors ship with a Reset to default button if Articulate or Cleanup starts producing odd results."
            ),
            AdvancedCardData(
                id: "ai-test-connection",
                title: "Test Connection",
                badge: "diag",
                body: "Verify a provider works before turning Cleanup on.",
                expansionProse:
                    "A one-shot diagnostic that sends a tiny request to the configured provider "
                    + "and reports the exact failure if it fails — DNS, auth, model-name, or "
                    + "timeout. It does not gate the Cleanup toggle."
            ),
        ]
    )

    private static let system = AdvancedSection(
        id: "system",
        title: "System",
        subtitle: "How Jot sits on your Mac — launch behavior, data retention, resets.",
        cards: [
            AdvancedCardData(
                id: "sys-launch-at-login",
                title: "Launch at login",
                badge: "on/off",
                body: "Start Jot automatically when you sign into your Mac.",
                expansionProse:
                    "Registers Jot as a login item via SMAppService. Toggle in Settings → General. "
                    + "macOS keeps a separate user-level switch in System Settings → General → Login Items."
            ),
            AdvancedCardData(
                id: "sys-retention",
                title: "Retention",
                badge: "7/30/90",
                body: "Auto-delete old recordings after N days. Or keep forever.",
                expansionProse:
                    "Choose 7, 30, 90 days, or Forever. Retention runs at launch and on a daily "
                    + "timer. Starred recordings are exempt — you can keep specific clips past the cutoff."
            ),
            AdvancedCardData(
                id: "sys-hide-to-tray",
                title: "Hide to tray",
                badge: "default",
                body: "Closing the window keeps Jot running in the menu bar.",
                expansionProse:
                    "Closing the main window hides Jot rather than quitting. The tray icon stays "
                    + "active and hotkeys keep working. Disable in Settings → General if you "
                    + "prefer clicking the dock icon to show the window."
            ),
            AdvancedCardData(
                id: "sys-reset-scopes",
                title: "Reset scopes",
                badge: "3 levels",
                body: "Settings only, all data, or permissions — tiered options.",
                expansionProse:
                    "Settings & Shortcuts clears preferences and hotkey bindings. Data & Recordings "
                    + "wipes the Library. Permissions re-runs the setup wizard. Each relaunches Jot on confirm."
            ),
        ]
    )

    private static let input = AdvancedSection(
        id: "input",
        title: "Input",
        subtitle: "Microphone selection, vocabulary boosting, and Bluetooth quirks.",
        cards: [
            AdvancedCardData(
                id: "input-device",
                title: "Input device",
                badge: "system",
                body: "Follows the macOS Sound default. Per-device selection coming soon.",
                expansionProse:
                    "Jot uses whatever input device macOS is currently routing to. Change the "
                    + "default in System Settings → Sound → Input. A per-app device picker is "
                    + "planned for a future release."
            ),
            AdvancedCardData(
                id: "input-vocabulary",
                title: "Custom vocabulary",
                badge: "boost",
                body: "Names, acronyms, jargon. Override behavior — keep it focused.",
                expansionProse:
                    "Add words Jot should prefer during transcription in Settings → Vocabulary. "
                    + "Runs on-device via an additional ~100 MB model. Keep the list under 100 "
                    + "entries and avoid common English words to prevent false replacements."
            ),
            AdvancedCardData(
                id: "input-bluetooth",
                title: "Bluetooth mic handling",
                badge: "auto",
                body: "Jot detects silent-capture redirects and surfaces a clear error.",
                expansionProse:
                    "Bluetooth headsets sometimes steal the mic route mid-session and silently "
                    + "send zero amplitude. Jot detects that and surfaces a specific error instead "
                    + "of saving an empty recording."
            ),
            AdvancedCardData(
                id: "input-silent-capture",
                title: "Silent-capture detection",
                badge: "safety",
                body: "Zero-amplitude audio triggers a specific error, not an empty result.",
                expansionProse:
                    "Every recording is scanned for a non-trivial amplitude floor. If the whole "
                    + "buffer is silent — misconfigured input, muted mic, BT redirect — Jot "
                    + "surfaces the silent-capture error instead of a confusing empty transcript."
            ),
        ]
    )

    private static let sounds = AdvancedSection(
        id: "sounds",
        title: "Sounds",
        subtitle: "Audible feedback for the pipeline — each chime is individually toggleable.",
        cards: [
            AdvancedCardData(
                id: "sound-recording-chimes",
                title: "Recording chimes",
                badge: "start/stop/cancel",
                body: "Three distinct sounds for recording state changes.",
                expansionProse:
                    "Start, stop, and cancel each play a distinct tone so you know the recorder's "
                    + "state without looking at the pill. Toggle individually in Settings → Sound."
            ),
            AdvancedCardData(
                id: "sound-transcription-complete",
                title: "Transcription complete",
                badge: "chime",
                body: "A brief tone when the transcript lands at your cursor.",
                expansionProse:
                    "A single chime fires when the transcript is pasted. Useful when you tab away "
                    + "mid-transcription — the sound tells you the paste landed."
            ),
            AdvancedCardData(
                id: "sound-error-chime",
                title: "Error chime",
                badge: "audible",
                body: "A distinct sound when something fails.",
                expansionProse:
                    "A separate tone for error states — silent capture, transcription failure, "
                    + "LLM timeout, permission revoked. Never shares the completion chime."
            ),
        ]
    )
}
