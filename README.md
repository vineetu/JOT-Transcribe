# Jot

> Speak, and it's written.

Native macOS dictation utility. Press a hotkey, speak, and text appears at your cursor — entirely on-device. No cloud, no accounts, no telemetry.

## Features

**Dictation** — Hit ⌥Space (or your custom shortcut), speak, and the transcript is pasted wherever your cursor is. Works in any app. Push-to-talk mode available too — hold the key, release to transcribe.

**AI Rewrite** — Select text, trigger the rewrite shortcut, and speak an instruction ("make this more formal", "fix the grammar", "translate to Spanish"). Jot sends the selected text + your voice instruction to an LLM, and the rewritten text replaces your selection. Supports OpenAI, Anthropic, and Gemini — configure the provider, endpoint, and API key in Settings.

**Dynamic Island overlay** — A pill-shaped indicator appears under the notch showing recording state, transcription progress, and a preview of the result.

**Recordings library** — Every transcription is saved with its audio. Browse by date, search transcripts, re-transcribe with a different model, or play back the original recording.

**Menu bar** — Start/stop recording, copy last transcript, and access settings from the menu bar icon.

**Sound cues** — Subtle chimes for recording start, stop, cancel, transcription complete, and errors. Configurable in Settings.

## Setup

On first launch, a setup wizard walks you through granting three macOS permissions (Microphone, Input Monitoring, Accessibility), downloading the Parakeet speech model (~1.2 GB, one-time), and configuring shortcuts.

If permissions get into a bad state, go to **Settings → General → Reset Permissions** or **Run Setup Wizard** to redo the flow.

To configure AI Rewrite, go to **Settings → AI Rewrite**, pick your provider, enter your API key, and optionally customize the base URL and model.

## Stack

Swift · SwiftUI + AppKit · FluidAudio (Parakeet TDT 0.6B v3 on Apple Neural Engine) · AVAudioEngine · SwiftData · KeyboardShortcuts

## Requirements

- Apple Silicon Mac
- macOS Sonoma 14.0+

## References

- `docs/design-requirements.md` — product requirements
- `docs/features.md` — feature inventory

## License

MIT — see [LICENSE](LICENSE).
