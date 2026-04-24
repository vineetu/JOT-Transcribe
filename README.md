# Jot

> Speak, and it's written.

Native macOS dictation utility. Press a hotkey, speak, and text appears at your cursor. Core transcription stays on-device; optional AI features can use Apple Intelligence, local Ollama, or configured cloud providers. No Jot account, no telemetry.

## Basic features

**Dictation** — Hit ⌥Space (or your custom shortcut), speak, and the transcript is pasted wherever your cursor is. Works in any app. Push-to-talk mode available too — hold the key, release to transcribe.

**Transcript cleanup (optional)** — Opt in and every dictation gets a quick LLM pass to strip filler words ("um", "you know", false starts), fix grammar, and fix context-unambiguous homophones (brake/break, peace/piece) while preserving your tone and meaning. Off by default; falls back to the raw transcript on any failure; runs against your configured provider (including local Ollama and on-device Apple Intelligence).

**Ask Jot** — A dedicated in-app chatbot for Jot help. Streaming, grounded in Jot's docs, on-device via Apple Intelligence by default, with optional OpenAI / Anthropic / Gemini / Ollama routing when you enable it. Includes voice input and clickable in-app feature links.

## Advanced features

**Articulate** — Select text, trigger the articulate shortcut, and speak an instruction ("make this more formal", "fix the grammar", "translate to Spanish"). Jot sends the selected text + your voice instruction to an LLM, and the articulated text replaces your selection. A fixed-prompt variant works without a voice instruction — select text, press the shortcut, done. Supports Apple Intelligence, OpenAI, Anthropic, Gemini, and Ollama. The Articulate shared system prompt and the Cleanup prompt are both editable for power users, with a one-click reset.

**Custom vocabulary** — Add proper nouns, acronyms, and domain-specific terms you use often. Jot biases the speech model toward them so product names and jargon get transcribed correctly instead of being guessed at. Edit in Settings → Transcription → Vocabulary.

## Setup

On first launch, a setup wizard walks you through granting three macOS permissions (Microphone, Input Monitoring, Accessibility), downloading the Parakeet speech model (~1.2 GB, one-time), and configuring shortcuts.

If permissions get into a bad state, go to **Settings → General → Reset Permissions** or **Run Setup Wizard** to redo the flow.

To configure Articulate or transcript cleanup, go to **Settings → AI**, pick your provider, and enter your API key (not needed for Ollama or Apple Intelligence). The cleanup toggle and prompt editor live in **Settings → AI** alongside the provider configuration. Ask Jot uses Apple Intelligence by default; if you switch to a non-Apple provider, you can opt that provider into Ask Jot from the same pane. Press **Test Connection** any time you want to verify reachability — it's a manual diagnostic, not a gate.

## Stack

Swift · SwiftUI + AppKit · FluidAudio (Parakeet TDT 0.6B v3 on Apple Neural Engine) · AVAudioEngine · SwiftData · KeyboardShortcuts

## Requirements

- Apple Silicon Mac
- macOS Sonoma 14.0+

## References

- `docs/design-requirements.md` — product requirements
- `docs/features.md` — feature inventory

## Support

Jot is MIT-licensed and free. No ads, no account, no tracking.

If you'd like to give back, **every donation goes directly to charity via Every.org** — pick from a curated list of causes the project supports at [jot.ideaflow.page/donations](https://jot.ideaflow.page/donations). If you'd rather send something directly to the creator, you can also [buy me a coffee ☕](https://ko-fi.com/vineetsriram).

## License

MIT — see [LICENSE](LICENSE).
