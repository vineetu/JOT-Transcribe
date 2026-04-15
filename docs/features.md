# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud providers, VAD, file upload, LLM transformations, and analytics are intentionally excluded; they are hidden in the current UI.

---

## Recording & Dictation

- **Toggle recording** — press the hotkey (default `⌥Space`) to start, press again to stop and transcribe. Also triggerable from the tray menu and the Home recording button.
- **Push to talk** — hold a hotkey to record, release to stop. Unbound by default.
- **Cancel recording** — press the hotkey (default `Esc`) to discard without transcribing. Active only while recording so it doesn't steal `Esc` from other apps.
- **Any-length recordings** — no hard duration limit; long recordings work reliably.

## Local Transcription

- **On-device only** — audio is transcribed locally; it never leaves the Mac.
- **Choice of engines** — Moonshine and Parakeet are the supported local engines. Today the UI exposes Moonshine; Parakeet is available internally.
- **Model selection** — pick among size/accuracy trade-offs (smallest/fastest → largest/most accurate).
- **In-app model download** — models are fetched from within Jot with a progress bar.
- **Auto-transcribe** — transcription starts automatically when recording stops.
- **Re-transcribe** — run transcription again on any saved recording.

## Output — Paste & Clipboard

- **Auto-paste at cursor** — transcription is pasted into the frontmost app.
- **Auto-press Enter** — optional; pastes and sends in one step (chat inputs, search boxes).
- **Clipboard preservation** — choose whether the transcript stays on the clipboard or the previous clipboard contents are restored after paste.
- **Copy last transcription** — from the Home card, Recordings detail, the tray menu, or a global shortcut.

## Global Shortcuts

Bindable system-wide commands:

- Toggle Recording
- Cancel Recording
- Paste Last Transcription
- Push to Talk

Conflicting bindings are handled gracefully (no two commands silently share a key).

## Menu Bar (Tray)

A native tray dropdown with:

- Toggle Recording (label updates to reflect state)
- Copy Last Transcription
- Show Window
- Settings…
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

## Settings

### General
- Input device (microphone)
- Launch at login
- Recording retention — Forever / Last 7 / 30 / 90 days
- Reset permissions (clears macOS privacy entries and restarts)
- Run setup wizard again (preloads current selections)

### Transcription
- Default model
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard

### Sound
- Recording start / stop / cancel chimes
- Transcription complete chime
- Error chime

### Shortcuts
- Read-only view of current bindings for the four global commands.

## Setup Wizard

Shown on first launch and on demand from Settings → General. Each step can be skipped; completing Done or Skip marks setup complete.

1. **Welcome**
2. **Permissions** — grant Microphone and Accessibility. A "Restart Jot" button is offered for Accessibility (which a running app can't detect until it relaunches).
3. **Model** — pick and download a local model. An already-downloaded model is preselected.
4. **Microphone** — pick the input device.
5. **Shortcuts** — preview of the default Toggle Recording shortcut.
6. **Test** — speak to verify the full pipeline end-to-end.

## System Integration

- **Launch at login** — auto-start with the Mac.
- **Hide to tray on close** — closing the window keeps Jot running.
- **`⌘,` opens Settings** from anywhere in the app.
- **Only one instance** — launching again focuses the running app.
- **Permissions handled gracefully** — microphone and accessibility are re-checked on mount and when returning from System Settings.

## Privacy & Data

- **100% local** — audio, transcripts, and settings stay on the device. No telemetry.
- **Retention controls** — configurable via Settings.
