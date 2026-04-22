# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud transcription providers, VAD / continuous listening, file upload, and analytics are intentionally excluded. Optional LLM-based features (transcript cleanup and voice-driven rewriting) are opt-in; on macOS 26+ they default to Apple Intelligence on-device, and Ollama remains available for users who want local-but-not-Apple.

---

## Recording & Dictation

- **Toggle recording** — press the hotkey (default `⌥Space`) to start, press again to stop and transcribe. Also triggerable from the tray menu and the Home recording button.
- **Push to talk** — hold a hotkey to record, release to stop. Unbound by default.
- **Cancel recording** — press the hotkey (default `Esc`) to discard without transcribing. Active only while recording so it doesn't steal `Esc` from other apps.
- **Any-length recordings** — no hard duration limit; long recordings work reliably.
- **Silent-capture detection** — if a recording returns zero-amplitude audio (often a Bluetooth mic that quietly re-routed at the OS level), Jot surfaces an actionable error pointing at the likely culprit instead of returning an empty transcript.

## Local Transcription

- **On-device only** — audio is transcribed locally on the Apple Neural Engine; it never leaves the Mac.
- **Parakeet TDT 0.6B v3** — ships as the transcription engine, running via FluidAudio on the ANE.
- **In-app model download** — the model is fetched from within Jot on first use with a progress bar.
- **Auto-transcribe** — transcription starts automatically when recording stops.
- **Re-transcribe** — run transcription again on any saved recording.

## Transcript Cleanup (optional)

Off by default. When enabled and an LLM provider is configured, Jot runs a lightweight "cleanup" pass on every transcript before delivery.

- **Remove filler words** (um, uh, like, you know) and false starts.
- **Fix grammar, punctuation, and capitalization.**
- **Preserve meaning, tone, and vocabulary** — no synonym swaps, no injected words.
- **Graceful fallback** — if the LLM call fails or times out (10 s budget), Jot delivers the raw transcript instead.
- **Cleaning-up indicator** — the status pill shows a "Cleaning up…" state during the transform.
- **Raw + cleaned are both stored** — the Recordings detail view offers a "Show original" toggle.
- **Provider options** — Apple Intelligence (on-device, default on macOS 26+), OpenAI, Anthropic, Gemini, or Ollama (fully local).
- **Editable prompt** — the default cleanup prompt (filler removal → grammar → numeric normalization → list detection → paragraph structure → "return only" contract) is shown under a "Customize prompt" chevron in the AI pane. Power users can rewrite it; a "Reset to default" restores the shipped prompt.
- **Inline "Set up AI →"** — if the Auto-correct toggle is disabled because AI isn't configured, the pane offers a direct jump to the AI pane instead of leaving the user to find it.

## Articulate (optional)

Transform selected text via a global shortcut. Two variants, both triggered by their own hotkey:

### Articulate (Custom) — voice-driven
- **Select text anywhere → press the shortcut → speak an instruction** ("make this more formal", "fix the grammar", "translate to Spanish", "convert to bulleted list"). The articulated text replaces the selection.
- **Intent-classified prompting** — a deterministic regex classifier routes each instruction into one of four branches (voice-preserving / structural / translation / code) and selects a specialized tendency for the LLM. The user's spoken instruction is always the primary signal; the branch just picks a minimal default tendency. Net effect: "make this a bulleted list" or "translate to Japanese" actually produce the requested shape, not a length-matched paraphrase.
- **Cancellable** — `Esc` cancels the capture, transcription, or articulation phase without committing.
- **Unbound by default** — the user assigns a shortcut in Settings → Shortcuts.

### Articulate (fixed) — no voice
- **Select text → press the shortcut.** No dictation step. Jot sends the selection to the configured LLM with the fixed instruction `"Articulate this"` and the result replaces the selection.
- **One-hand quick cleanup** — use when you just want the LLM to tidy a passage without speaking an instruction.
- **Unbound by default** — the user assigns a shortcut in Settings → Shortcuts.

### Shared configuration
- **Provider options** — Apple Intelligence (on-device, default on macOS 26+), OpenAI, Anthropic, Gemini, or Ollama.
- **Editable shared invariants** — the shared-invariants block (selection-is-text-not-instruction, return-only-the-rewrite, don't-refuse-on-quality) is revealed under a "Customize prompt" chevron in Settings → Articulate with a "Reset to default" escape hatch. The per-branch tendencies are compile-time constants and not user-editable.

## Output — Paste & Clipboard

- **Auto-paste at cursor** — transcription is pasted into the frontmost app.
- **Auto-press Enter** — optional; pastes and sends in one step (chat inputs, search boxes).
- **Clipboard preservation** — choose whether the transcript stays on the clipboard or the previous clipboard contents are restored after paste.
- **Copy last transcription** — from the Home card, Recordings detail, the tray menu, or a global shortcut.
- **Quick copy from any row** — an inline copy button on every Library row and every Home "Recent" entry copies that recording's transcript to the clipboard without opening detail.

## Global Shortcuts

All shortcuts are bindable in the Shortcuts pane. Defaults and bindings:

- **Toggle Recording** — default `⌥Space`.
- **Cancel Recording** — default `Esc`, active only while recording, transforming, or rewriting so it doesn't steal `Esc` from other apps when idle.
- **Paste Last Transcription** — default `⌥⇧V`.
- **Push to Talk** — unbound by default.
- **Articulate (Custom)** — voice-driven rewrite of selected text; unbound by default.
- **Articulate** — applies a fixed `"Articulate this"` prompt to the selected text (no voice step); unbound by default.

Shortcut bindings require a modifier (⌘, ⌥, ⌃, ⇧) — macOS does not permit global hotkeys bound to a bare key. The Shortcuts pane and the Help tab both surface this. Conflicting bindings are handled gracefully (no two commands silently share a key).

## Menu Bar (Tray)

A native tray dropdown with:

- Toggle Recording (label updates to reflect state)
- Copy Last Transcription
- Recent Transcriptions submenu (last 10, click to copy)
- Open Jot… (opens the main window)
- Check for Updates…
- Quit Jot

Closing the main window hides to the tray; Quit fully exits.

## Status Indicator

A small floating overlay near the menu bar — a Dynamic Island-style pill — that reflects pipeline state without stealing focus.

- **Live amplitude waveform** during recording — renders the actual audio level as a sine-wave-style animation inside the pill so the user can see Jot is hearing them. No static gif / fake animation.
- **States:** Recording (with elapsed time + live waveform), Transcribing, Cleaning up (when transcript cleanup is on), Articulating (during Articulate), Success (with a short preview and Copy), Error (with the message).

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
- **Settings** — grouped children: General, Transcription, Vocabulary, Sound, AI, Shortcuts.
- **Help** — Basics, Advanced, Troubleshooting.
- **About** — app identity, privacy pledge, donation link, and the Troubleshooting log-sharing flow.

The main window is the single destination for all five sections — there is no separate Settings window and no global `⌘,` binding (the default SwiftUI `appSettings` command group is intentionally removed).

## Settings

Fields throughout Settings carry per-field `info.circle` popovers for inline help. Each popover's "Learn more →" link deep-links into the matching section of the Help tab.

### General
- Input device (microphone) — currently fixed to the macOS Sound settings default; per-device selection is temporarily disabled in this release (known bug, flagged inline in the pane)
- Launch at login
- Recording retention — Forever / Last 7 / 30 / 90 days (default: 7 days)
- Run setup wizard again (preloads current selections)
- **Restart Jot** — a Troubleshooting row that quits and relaunches the app after a confirmation prompt, re-registering global shortcuts from scratch. Use when a hotkey suddenly produces a Unicode character (≤, ÷, …) instead of triggering its action, which happens when another app grabs the same shortcut while Jot is off.
- **Reset group** — a dedicated section at the bottom of General with three tiered actions:
  - **Reset settings** — clears preferences, API keys, and shortcut bindings; keeps recordings and the downloaded model. Relaunches Jot.
  - **Erase all data** — destructive; wipes recordings, the transcription model (≈600 MB), and all settings. macOS permissions are untouched. Relaunches Jot.
  - **Reset permissions** — runs `tccutil reset All` for Jot so macOS re-asks for Microphone, Input Monitoring, and Accessibility. Relaunches Jot.
  All three require a confirmation alert. Only "Erase all data" is tinted red — the other two are styled as normal interactive rows so they don't read as disabled.

### Transcription
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard
- Clean up transcript with AI (hidden until an LLM provider is configured in Settings → AI; reach the AI pane via the sidebar to set one up)
- "Customize prompt" disclosure for the transcript-cleanup prompt, with "Reset to default"

### Vocabulary
- **Custom vocabulary list** — a short list of user-supplied terms (product names, proper nouns, jargon) that Jot should prefer when transcribing, so names and domain words don't get misheard as their common-word neighbors.
- Inline add / rename / delete of terms; the list is persisted to disk and reloaded on pane open so external edits are picked up.
- Boost-model status row shows download state (not downloaded / downloading / ready / failed) for the small CTC encoder that powers rescoring.

### AI
- Provider (Apple Intelligence / OpenAI / Anthropic / Gemini / Ollama)
- Base URL (left-aligned) and model — override per-provider defaults
- API key (hidden for Ollama — local, no key required)
- Articulate (Custom) shortcut — voice-driven rewrite
- Articulate shortcut — applies a fixed `"Articulate this"` prompt (no voice)
- Test Connection button — always enabled, prominent accent-tinted; shows an inline spinner during the call and a success chip afterward. Must succeed before the cleanup toggle unlocks.
- "Customize prompt" disclosure for the Articulate shared invariants, with "Reset to default" (per-branch tendencies are not editable)

### Sound
- Recording start / stop / cancel chimes
- Transcription complete chime
- Error chime

### Shortcuts
- Editable bindings for Toggle Recording, Push to Talk, Paste Last Transcription, Articulate, Articulate (Custom). Cancel Recording (Esc) is hardcoded, not configurable, and not shown in the Shortcuts list — a footnote tells the user that Esc is the cancel key and that macOS global hotkeys must include at least one modifier.

## About

A top-level sidebar pane (not a Settings child) for identity, giving back, privacy, and diagnostics.

- App identity (icon, tagline, version / build) and the project vision statement.
- **Support Jot** — donation link that routes 100% of contributions to the author's every.org charity fund (opens in the user's browser; no payment flows inside Jot).
- **Privacy pledge** — inline reminder that transcription is local-only and the only automatic network calls are the one-time model download and the daily appcast check.
- **Troubleshooting** — a dedicated section for error reporting:
  - **View log** — opens the local error log in a sheet with a Done button.
  - **Copy log / Reveal in Finder / Send via email** — each goes through a privacy-scan sheet that checks the log for API keys, credential URLs, absolute paths, and your last 90 days of transcripts before handing over the file. Every flow offers an "Auto-redact and …" option when anything sensitive is found. Emails are pre-addressed to `jottranscribe@gmail.com` with app diagnostics pre-filled; the log itself is placed on the clipboard so the user can review before pasting.

## Help

In-app prose walkthrough split across three tabs, each using a shared component library (HelpSection / HelpSubsection / Callout / ExpandableRow / ShortcutChip / AnchorRail) and hand-drawn flow diagrams so concepts are discoverable at a glance, not buried in wall-of-text.

- **Basics** — Dictation, Auto-correct (transcript cleanup), Articulate (both variants), copying the last transcription, the status pill. Includes visual diagrams of the end-to-end recording → transcription → paste flow.
- **Advanced** — LLM provider setup (Apple Intelligence default on macOS 26+; OpenAI, Anthropic, Gemini, Ollama available as alternates); editable prompts; Sparkle auto-update.
- **Troubleshooting** — permissions (Microphone / Input Monitoring / Accessibility), the macOS "modifier required" hotkey constraint, Bluetooth-redirect capture failures, resetting state, and pointers to the About tab's log-sharing flow for reporting bugs.

Info popovers across Settings deep-link into the matching Help section so the user can jump from a field to its explanation without context-switching. The deep-link contract is two-phase: an anchor may live inside an `ExpandableRow` that needs to auto-open before the scroll lands, so the page expands the target row first and then scrolls to it.

## Setup Wizard

Shown on first launch and on demand from Settings → General. Nine steps, in order; each can be skipped. Done is the "you're set up for the basics" checkpoint — most first-run users stop there, and Continue reveals the advanced steps (Cleanup, Articulate intro) for power users who want to configure them inline.

1. **Welcome**
2. **Permissions** — grant Microphone, Input Monitoring, and Accessibility. A "Restart Jot" button is offered after granting Input Monitoring or Accessibility (a running app can't detect those until it relaunches).
3. **Model** — downloads Parakeet on first run; already-downloaded models skip straight through.
4. **Microphone** — review the input device (currently fixed to the macOS Sound settings default; per-device selection is temporarily disabled).
5. **Shortcuts** — preview of the default Toggle Recording shortcut.
6. **Test dictation** — speak to verify the full pipeline end-to-end. The user controls the capture window (no hard 3-second cap) and can re-test as many times as they like.
7. **Done** — terminal "you're set up for the basics" card shown right after Test succeeds. Skip here to start using Jot; Continue advances into the advanced steps below.
8. **Cleanup** — introduces Auto-correct (LLM transcript cleanup). When the Test step produced a transcript, a "Preview cleanup" button runs the user's current provider (Apple Intelligence on macOS 26+, or whichever cloud / Ollama provider is configured) against that transcript so the user sees the before/after inline. No toggle here — actually enabling Auto-correct still happens in Settings → AI.
9. **Articulate intro** — brief voice-driven-rewrite walkthrough: select → speak instruction → replace. Surfaced after the user has successfully dictated so they know what "Articulate" means before they're asked to think about binding a shortcut.

## System Integration

- **Launch at login** — auto-start with the Mac.
- **Hide to tray on close** — closing the window keeps Jot running.
- **Only one instance** — launching again focuses the running app.
- **Permissions handled gracefully** — microphone, input monitoring, and accessibility are re-checked on mount and when returning from System Settings.
- **Auto-update via Sparkle** — Jot checks for updates daily against the GitHub-hosted appcast and prompts to install verified releases.

## Privacy & Data

- **100% local** — audio, transcripts, and settings stay on the device. No telemetry.
- **Retention controls** — configurable via Settings.
