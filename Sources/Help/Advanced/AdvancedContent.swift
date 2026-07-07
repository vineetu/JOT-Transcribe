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
        recordingsLibrary,
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
        subtitle: "Pick who does Cleanup and Rewrite. Mix on-device, local, and cloud as you like.",
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
                    + "requests are scoped to Cleanup and Rewrite — the dictation path stays on-device."
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
                title: "Editable system prompts",
                badge: "power",
                body: "Tune the Cleanup and Rewrite shared system prompts. Reset available.",
                expansionProse:
                    "Jot has two separate system prompts. Cleanup's prompt (Settings → AI → Customize prompt) controls how dictation transcripts get tidied up — disfluencies, punctuation, grammar. Rewrite's Shared system prompt (Settings → AI → Shared system prompt) is the foundation of every rewrite, used by Default Rewrite, Rewrite with Voice, and every prompt picked from the library. Editing one does not affect the other. "
                    + "\n\nOn top of the Shared system prompt, Jot appends a short branch-specific tendency chosen automatically by the intent classifier — voice-preserving, shape change, translation, or code — based on your voice instruction. The appended tendency is not user-editable. "
                    + "\n\nThis is distinct from the prompt library itself (Settings → AI), which holds 30+ named instructions for specific outcomes (\"make this formal\", \"convert to Mermaid\", \"summarize\"). The shared system prompt sets ground rules every prompt inherits; library entries override the task. Every provider uses the same shared prompts, so edits here apply uniformly across Apple Intelligence, OpenAI, Anthropic, Gemini, and Ollama. Both editors ship with a Reset to default button."
            ),
            AdvancedCardData(
                id: "ai-prompt-library",
                title: "Prompt library",
                badge: "library",
                body: "30+ bundled prompts plus your own. Pin, search, and inspect at Settings → AI.",
                expansionProse:
                    "The prompt library is the catalog of named instructions you can apply to selected text via the Rewrite picker. Bundled prompts ship across six categories — Essentials, Convert, Email, Rewrite, Code, Translate — and are read-only; they update only on app release. Tap any bundled row to open a detail sheet with the full body, sample input/output, voice augment hint, provider compatibility list, and the pin toggle. "
                    + "\n\nAdd your own under My prompts. Title and body are required; sample input/output are optional. ✨ Generate sample asks your configured AI provider to fill the sample fields sequentially — first a plausible input for your prompt body, then the prompt run against that input to produce the output. Phase indicators show \"Generating input…\" then \"Generating output…\"; on failure the button becomes Try again with the error inline. User prompts are stored locally on this Mac via SwiftData, never synced, never sent to a provider unless the prompt is actually used at rewrite time. "
                    + "\n\nPin any prompt — bundled or yours — and it floats to the top of the rewrite picker and shows up in a Pinned section in Settings → AI. Each bundled prompt declares which providers it's been verified against; the picker may demote rows where your active provider is untested. Custom prompts default to \"works with all\"."
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
                id: "hide-from-dock",
                title: "Hide from Dock",
                badge: "on/off",
                body: "Run Jot as a menu-bar-only app. No Dock icon, no Cmd+Tab entry.",
                expansionProse:
                    "Toggle Settings → General → \"Show Jot in the Dock\" off and Jot becomes "
                    + "menu-bar-only on the next launch — no Dock icon, no Cmd+Tab entry, no app "
                    + "menu at the top of the screen. The menu-bar icon, global hotkeys, recording "
                    + "pill, and Force Quit (⌥⌘⎋) all keep working. The change applies on next launch, "
                    + "not live, to avoid documented edge cases with mid-session activation-policy "
                    + "switches (windows briefly hiding, app menu not reattaching cleanly). Turn the "
                    + "toggle back on and relaunch to restore the Dock icon."
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
                    + "state without looking at the pill. Toggle individually in Settings → General."
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

    private static let recordingsLibrary = AdvancedSection(
        id: "recordings-library",
        title: "Recordings & Library",
        subtitle: "Speaker labels, file import, export, search, and safety nets for everything Jot records.",
        cards: [
            AdvancedCardData(
                id: "recordings-diarization",
                title: "Detect speakers",
                badge: "on-device",
                body: "Labels who spoke when in a recording, right from its detail view.",
                expansionProse:
                    "Tap Detect speakers in a recording's detail to split the transcript into "
                    + "color-coded, per-speaker blocks, computed fully on-device. Speakers are "
                    + "labeled \u{201c}Speaker 1 / 2 / 3\u{2026}\u{201d} in the order they first appear — right-click "
                    + "any label \u{2192} Rename speaker\u{2026} to name them across every one of their turns. "
                    + "Best for clean meeting or call recordings where each person is on separate "
                    + "audio (Zoom/Meet, a video's own soundtrack) — not reliable when voices blur "
                    + "together acoustically through a single room mic. Single-speaker recordings "
                    + "are detected and skipped automatically; the result is computed once and saved."
            ),
            AdvancedCardData(
                id: "recordings-file-import",
                title: "Transcribe a file",
                badge: "drag & drop",
                body: "Drag an existing audio or video file onto Recents to transcribe it like a live recording.",
                expansionProse:
                    "Drop an audio or video file onto the dictate zone on Recents (or click browse "
                    + "to pick one), and Jot transcribes it on the same on-device pipeline as a live "
                    + "dictation. It lands as a normal recording — playable, searchable, diarizable. "
                    + "Format coverage is close to universal: AVFoundation covers the common set "
                    + "(mp3, m4a, wav, mp4, mov\u{2026}), and a bundled, network-free FFmpeg fallback "
                    + "extracts audio from the long tail (WebM, MKV, WMA, AVI, and more). A live "
                    + "dictation always takes priority over an in-flight import."
            ),
            AdvancedCardData(
                id: "recordings-webvtt-export",
                title: "Export as WebVTT",
                badge: "export",
                body: "Save any recording's transcript as a standard .vtt subtitle file.",
                expansionProse:
                    "The Export button in a recording's detail view saves its transcript as a "
                    + ".vtt file. If the recording has been through Detect speakers, each cue "
                    + "carries a <v Speaker N> voice tag; otherwise it's a single-cue transcript. "
                    + "Works in video players, subtitle tools, and other transcription apps — "
                    + "generated fully on-device."
            ),
            AdvancedCardData(
                id: "recordings-cli",
                title: "jot command line",
                badge: "terminal",
                body: "A bundled CLI transcribes a file to WebVTT from the terminal, with optional speaker labels.",
                expansionProse:
                    "Jot ships a standalone command-line tool at Jot.app/Contents/Helpers/jot. Add "
                    + "it to your PATH once with `sudo ln -s /Applications/Jot.app/Contents/Helpers/jot "
                    + "/usr/local/bin/jot`, then run `jot transcribe meeting.mp4 --diarize -o out.vtt`. "
                    + "It reuses the same on-device engine, bundled ffmpeg, and downloaded models as "
                    + "the app — nothing leaves your Mac, no network required."
            ),
            AdvancedCardData(
                id: "recordings-ai-search",
                title: "AI search",
                badge: "semantic",
                body: "Finds recordings by meaning, not just exact words — on by default.",
                expansionProse:
                    "Search over your recordings is augmented with on-device semantic recall: "
                    + "searching \u{201c}rent increase\u{201d} can surface a recording where you said \u{201c}the "
                    + "landlord is raising my payment.\u{201d} It runs a local embedding model, indexes "
                    + "transcripts in the background, and is on by default — exact-text search keeps "
                    + "working whether it's enabled or not. Toggle it off in Settings → General if "
                    + "you'd rather skip the one-time model download."
            ),
            AdvancedCardData(
                id: "recordings-progress",
                title: "Transcription progress",
                badge: "status",
                body: "See how far along an import is, not just a spinner.",
                expansionProse:
                    "Importing a file shows real progress on the standard transcription model — a "
                    + "percent-complete bar tied to the actual decode. On models that don't expose "
                    + "a progress signal (Nemotron, the streaming Parakeet variants), Jot shows an "
                    + "honest elapsed-time counter instead of a made-up estimate."
            ),
            AdvancedCardData(
                id: "recordings-never-lose-audio",
                title: "Never lose audio",
                badge: "safety net",
                body: "A recording's audio is saved even when transcription can't run.",
                expansionProse:
                    "If the transcriber is busy or errors out, your recording is still saved to "
                    + "Recents as a \u{201c}Needs transcription\u{201d} pending item — re-transcribe it with one "
                    + "click instead of losing it. A startup scan also recovers any orphaned audio "
                    + "left on disk from a crash or an older version, so nothing you recorded is "
                    + "ever silently discarded."
            ),
        ]
    )
}
