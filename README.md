# Jot

> Speak, and it's written.

Native macOS dictation utility. Press a hotkey, speak, and text appears at your cursor — entirely on-device. No cloud, no accounts, no telemetry.

## Features

**Dictation** — Hit ⌥Space (or your custom shortcut), speak, and the transcript is pasted wherever your cursor is. Works in any app. Push-to-talk mode available too — hold the key, release to transcribe.

**AI Rewrite** — Select text, trigger the rewrite shortcut, and speak an instruction ("make this more formal", "fix the grammar", "translate to Spanish"). Jot sends the selected text + your voice instruction to an LLM, and the rewritten text replaces your selection. Supports OpenAI, Anthropic, Gemini, and Ollama (fully local) — configure the provider, endpoint, and API key in Settings. The prompts for both cleanup and rewrite are editable for power users, with a one-click reset.

**Transcript cleanup (optional)** — Opt in and every dictation gets a quick LLM pass to strip filler words ("um", "you know", false starts) and fix grammar while preserving your tone and meaning. Off by default; falls back to the raw transcript on any failure; runs against your configured provider (including local Ollama).

**Dynamic Island overlay** — A pill-shaped indicator appears under the notch showing recording state, transcription progress, and a preview of the result.

**Recordings library** — Every transcription is saved with its audio. Browse by date, search transcripts, re-transcribe with a different model, or play back the original recording.

**Menu bar** — Start/stop recording, copy last transcript, and open the main window from the menu bar icon. Jot ships as a single window with a sidebar for Home, Library, Settings, and an in-app Help tab — no separate Settings window.

**In-app discoverability** — Every Settings field carries an info popover with a "Learn more →" link that deep-jumps into the matching Help section, so you never have to leave the app to figure out what a toggle does.

**Sound cues** — Subtle chimes for recording start, stop, cancel, transcription complete, and errors. Configurable in Settings.

**Auto-update** — Jot checks for new releases daily via Sparkle and prompts to install signed updates.

## Setup

On first launch, a setup wizard walks you through granting three macOS permissions (Microphone, Input Monitoring, Accessibility), downloading the Parakeet speech model (~1.2 GB, one-time), and configuring shortcuts.

If permissions get into a bad state, go to **Settings → General → Reset Permissions** or **Run Setup Wizard** to redo the flow.

To configure AI Rewrite or transcript cleanup, go to **Settings → AI**, pick your provider, and enter your API key (not needed for Ollama). The cleanup toggle in **Settings → Transcription** appears as soon as a provider is configured. Press **Test Connection** any time you want to verify reachability — it's a manual diagnostic, not a gate.

## Stack

Swift · SwiftUI + AppKit · FluidAudio (Parakeet TDT 0.6B v3 on Apple Neural Engine) · AVAudioEngine · SwiftData · KeyboardShortcuts

## Requirements

- Apple Silicon Mac
- macOS Sonoma 14.0+

## References

- `docs/design-requirements.md` — product requirements
- `docs/features.md` — feature inventory

## Support

If Jot saves you time, you can [buy me a coffee ☕](https://ko-fi.com/vineetsriram).

## License

MIT — see [LICENSE](LICENSE).
