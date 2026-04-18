# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud transcription providers, VAD / continuous listening, file upload, and analytics are intentionally excluded. Optional LLM-based features (transcript cleanup and voice-driven rewriting) are opt-in and can be configured to run locally via Ollama.

---

## Recording & Dictation

- **Toggle recording** — press the hotkey (default `⌥Space`) to start, press again to stop and transcribe. Also triggerable from the tray menu and the Home recording button.
- **Push to talk** — hold a hotkey to record, release to stop. Unbound by default.
- **Cancel recording** — press the hotkey (default `Esc`) to discard without transcribing. Active only while recording so it doesn't steal `Esc` from other apps.
- **Any-length recordings** — no hard duration limit; long recordings work reliably.
- **Reliable capture across device changes** — the input device is pinned at the CoreAudio layer when recording starts, so a Bluetooth headset that quietly re-routes mid-session doesn't silently break the stream. If zero-amplitude audio is detected, Jot surfaces an actionable error pointing at the likely BT-redirect culprit instead of returning an empty transcript.

## Local Transcription

- **On-device only** — audio is transcribed locally on the Apple Neural Engine; it never leaves the Mac.
- **Parakeet TDT 0.6B v3** — ships as the transcription engine, running via FluidAudio on the ANE.
- **In-app model download** — the model is fetched from within Jot on first use with a progress bar.
- **Auto-transcribe** — transcription starts automatically when recording stops.
- **Re-transcribe** — run transcription again on any saved recording.

## Transcript Cleanup (optional)

Off by default. When enabled and a verified LLM endpoint is configured, Jot runs a lightweight "cleanup" pass on every transcript before delivery.

- **Remove filler words** (um, uh, like, you know) and false starts.
- **Fix grammar, punctuation, and capitalization.**
- **Preserve meaning, tone, and vocabulary** — no synonym swaps, no injected words.
- **Graceful fallback** — if the LLM call fails or times out (10 s budget), Jot delivers the raw transcript instead.
- **Cleaning-up indicator** — the status pill shows a "Cleaning up…" state during the transform.
- **Raw + cleaned are both stored** — the Recordings detail view offers a "Show original" toggle.
- **Provider options** — OpenAI, Anthropic, Gemini, Vertex Gemini, or Ollama (fully local).
- **Editable prompt** — the default cleanup prompt (filler removal → grammar → numeric normalization → list detection → paragraph structure → "return only" contract) is shown under a "Customize prompt" chevron in the AI pane. Power users can rewrite it; a "Reset to default" restores the shipped prompt.
- **Inline "Set up AI →"** — if the Auto-correct toggle is disabled because AI isn't configured, the pane offers a direct jump to the AI pane instead of leaving the user to find it.

## AI Rewrite (optional)

Voice-driven rewriting of selected text, triggered by a global shortcut.

- **Select text anywhere → press the shortcut → speak an instruction** ("make this more formal", "fix the grammar", "translate to Spanish"). The rewritten text replaces the selection.
- **Same provider options** — OpenAI, Anthropic, Gemini, Vertex Gemini, or Ollama.
- **Cancellable** — `Esc` cancels the capture, transcription, or rewrite phase without committing.
- **Unbound by default** — the user assigns a shortcut in Settings → AI.
- **Editable prompt** — like Transform, the default rewrite prompt is revealed under a "Customize prompt" chevron with a "Reset to default" escape hatch.

## Output — Paste & Clipboard

- **Auto-paste at cursor** — transcription is pasted into the frontmost app.
- **Auto-press Enter** — optional; pastes and sends in one step (chat inputs, search boxes).
- **Clipboard preservation** — choose whether the transcript stays on the clipboard or the previous clipboard contents are restored after paste.
- **Copy last transcription** — from the Home card, Recordings detail, the tray menu, or a global shortcut.

## Global Shortcuts

All shortcuts are bindable in the Shortcuts pane. Defaults and bindings:

- **Toggle Recording** — default `⌥Space`.
- **Cancel Recording** — default `Esc`, active only while recording, transforming, or rewriting so it doesn't steal `Esc` from other apps when idle.
- **Paste Last Transcription** — default `⌥⇧V`.
- **Push to Talk** — unbound by default.
- **Rewrite Selection** — unbound by default; user assigns one in the AI pane.

Shortcut bindings require a modifier (⌘, ⌥, ⌃, ⇧) — macOS does not permit global hotkeys bound to a bare key. The Shortcuts pane and the Help tab both surface this. Conflicting bindings are handled gracefully (no two commands silently share a key).

## Menu Bar (Tray)

A native tray dropdown with:

- Toggle Recording (label updates to reflect state)
- Copy Last Transcription
- Open Jot… (opens the main window)
- Settings… (`⌘,` — opens the main window directly in Settings)
- Quit Jot

Closing the main window hides to the tray; Quit fully exits.

## Status Indicator

A small floating overlay near the menu bar that reflects pipeline state without stealing focus. States: Recording (with elapsed time), Transcribing, Success (with a short preview and Copy), Error (with the message).

## Recordings Library

- **Browse** by date group (Today, Yesterday, Last 7 days, …).
- **Search** across title, subtitle, and transcript text.
- **Detail view** — waveform, playback with scrubbing, full transcript.
- **Rename** recordings inline.
- **Per-recording actions** — Re-transcribe, Reveal in Finder, Delete.
- **Home "Last transcription" card** — quick access to the most recent result with Copy and Open in Recordings.

## Main Window

Jot runs as a menu-bar app with a single main window opened from the tray (Open Jot… or Settings…). The window uses a left source-list sidebar for navigation — no separate Settings window.

Sidebar entries:

- **Home** — landing pane: current hotkey glance, a "Recent" row of the last 5 recordings, and a dismissible "New to Jot? See the Basics →" banner for first-run discovery.
- **Library** — the recordings browser (see below).
- **Settings** — grouped children: General, Transcription, Sound, AI, Shortcuts.
- **Help** — Basics, Advanced, Troubleshooting.

`⌘,` from anywhere opens the window directly on the Settings section.

## Settings

Fields throughout Settings carry per-field `info.circle` popovers for inline help. Each popover's "Learn more →" link deep-links into the matching section of the Help tab.

### General
- Input device (microphone)
- Launch at login
- Recording retention — Forever / Last 7 / 30 / 90 days (default: 7 days)
- Reset permissions (clears macOS privacy entries and restarts)
- Run setup wizard again (preloads current selections)

### Transcription
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard
- Clean up transcript with AI (disabled until a provider is configured and verified; offers an inline "Set up AI →" jump to the AI pane when disabled)
- "Customize prompt" disclosure for the transcript-cleanup prompt, with "Reset to default"

### AI
- Provider (OpenAI / Anthropic / Gemini / Vertex Gemini / Ollama)
- Base URL (left-aligned) and model — override per-provider defaults
- API key (hidden for Ollama — local, no key required)
- Rewrite Selection shortcut
- Test Connection button — always enabled, prominent accent-tinted; shows an inline spinner during the call and a success chip afterward. Must succeed before the cleanup toggle unlocks.
- "Customize prompt" disclosure for the AI-rewrite prompt, with "Reset to default"

### Sound
- Recording start / stop / cancel chimes
- Transcription complete chime
- Error chime

### Shortcuts
- Editable bindings for Toggle Recording, Push to Talk, Paste Last Transcription, Rewrite Selection. Cancel Recording (Esc) is shown alongside the others but hardcoded — not configurable. A footnote reminds the user that macOS global hotkeys must include a modifier.

## Help

In-app prose walkthrough, split across three tabs:

- **Basics** — Dictation, Auto-correct (transcript cleanup), AI Rewrite, copying the last transcription, the status pill.
- **Advanced** — LLM provider setup across OpenAI, Anthropic, Gemini, Vertex Gemini, and Ollama; editable prompts; Sparkle auto-update.
- **Troubleshooting** — permissions (Microphone / Input Monitoring / Accessibility), the macOS "modifier required" hotkey constraint, Bluetooth-redirect capture failures, resetting state.

Info popovers across Settings deep-link into the matching Help section so the user can jump from a field to its explanation without context-switching.

## Setup Wizard

Shown on first launch and on demand from Settings → General. Each step can be skipped; completing Done or Skip marks setup complete.

1. **Welcome**
2. **Permissions** — grant Microphone, Input Monitoring, and Accessibility. A "Restart Jot" button is offered after granting Input Monitoring or Accessibility (a running app can't detect those until it relaunches).
3. **Model** — downloads Parakeet on first run; already-downloaded models skip straight through.
4. **Microphone** — pick the input device.
5. **Shortcuts** — preview of the default Toggle Recording shortcut.
6. **Test** — speak to verify the full pipeline end-to-end.

## System Integration

- **Launch at login** — auto-start with the Mac.
- **Hide to tray on close** — closing the window keeps Jot running.
- **`⌘,` opens Settings** from anywhere in the app.
- **Only one instance** — launching again focuses the running app.
- **Permissions handled gracefully** — microphone, input monitoring, and accessibility are re-checked on mount and when returning from System Settings.
- **Auto-update via Sparkle** — Jot checks for updates daily against the GitHub-hosted appcast and prompts to install verified releases.

## Privacy & Data

- **100% local** — audio, transcripts, and settings stay on the device. No telemetry.
- **Retention controls** — configurable via Settings.
