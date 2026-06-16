# Jot

> **Speak, and it's written.**

Free, on-device dictation for Mac and iPhone. Press a hotkey, talk, and your words appear at the cursor — in any app. Your voice never leaves your device.

<p>
  <a href="https://github.com/vineetu/JOT-Transcribe/releases/latest/download/Jot.dmg"><b>⬇ Download for Mac</b></a>
  &nbsp;·&nbsp;
  <a href="https://apps.apple.com/us/app/jot-transcribe/id6766447330"><b> Get it for iPhone</b></a>
  &nbsp;·&nbsp;
  <a href="https://jot-transcribe.com/">Website</a>
</p>

Apple Silicon · macOS 14+ · iPhone on the App Store · MIT-licensed · No account · No telemetry

---

## Why Jot

- **Private by default.** Transcription runs entirely on your Mac. No audio, no transcripts, nothing leaves the device — there's nothing to leak.
- **Free, with no catch.** No subscription, no usage limits, no account. The leading dictation apps charge ~$144/year for this.
- **Works everywhere.** One global hotkey types into Mail, Slack, your editor, a browser form — anywhere there's a cursor.
- **Open source.** Read every line. MIT-licensed.

## What it does

- **Dictation** — Press ⌥Space (or your own shortcut), speak, and the transcript is pasted at your cursor. Toggle or push-to-talk.
- **Rewrite by voice** — Select text, speak an instruction ("make this friendlier", "translate to Spanish"), and it's rewritten in place.
- **Optional cleanup** — Strip filler words and fix grammar while keeping how you actually talk. Off by default.
- **Custom vocabulary** — Teach it the names, acronyms, and jargon you use so they're transcribed right.
- **Searchable history** — Every dictation is saved on your Mac. Replay the audio, search everything you've said.
- **Ask Jot** — A built-in help chat, grounded in Jot's docs, that answers in plain language.
- **On iPhone, too** — A free dictation keyboard. Same rules: no account, no cloud, nothing leaves the device.

## Privacy

Core dictation is 100% on-device. The only network calls Jot ever makes are the one-time speech-model download and a daily check for app updates.

Optional AI features (cleanup, Rewrite, Ask Jot) default to **Apple Intelligence**, which also runs on-device. If you'd rather use a cloud provider (OpenAI, Anthropic, Gemini) or local Ollama, that's strictly opt-in and uses your own key — Jot never ships one.

## Install

**Mac** — [Download the DMG](https://github.com/vineetu/JOT-Transcribe/releases/latest/download/Jot.dmg), open it, drag Jot to Applications. A first-run wizard walks you through the macOS permissions (Microphone, Input Monitoring, Accessibility) and a one-time speech-model download (~1.2 GB).

**iPhone** — [Get Jot Transcribe on the App Store](https://apps.apple.com/us/app/jot-transcribe/id6766447330).

## Requirements

- **Mac:** Apple Silicon, macOS Sonoma 14.0 or later
- **iPhone:** see the App Store listing

## Building from source

Jot is a single Xcode project, one executable target — no package manager step.

```bash
git clone https://github.com/vineetu/JOT-Transcribe.git
cd JOT-Transcribe
open Jot.xcodeproj   # build & run the "Jot" scheme (⌘R)
```

Code lives under `Sources/`, organized by layer (Recording, Transcription, Delivery, LLM, Settings, …). `Resources/` holds assets and the bundled help content. Start with [`CLAUDE.md`](CLAUDE.md) for the architecture map and [`docs/`](docs/) for the product requirements and feature inventory.

## Built with

- [FluidAudio](https://github.com/FluidInference/FluidAudio) running **Parakeet TDT 0.6B v3** on the Apple Neural Engine for transcription
- Swift · SwiftUI + AppKit · CoreAudio · SwiftData · [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
- Apple Intelligence (`FoundationModels`) for on-device AI

## Support

Jot is free and always will be. If you'd like to give back, **every donation goes to charity via Every.org** — [jot-transcribe.com/donations](https://jot-transcribe.com/donations). To support the creator directly, [buy me a coffee ☕](https://ko-fi.com/vineetsriram).

## License

MIT — see [LICENSE](LICENSE).
