# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud transcription providers, VAD / continuous listening, pre-recorded file upload, and analytics are intentionally excluded. Core transcription stays local; optional AI features can use Apple Intelligence on-device, local Ollama, or user-configured cloud providers.

---

## Recording & Dictation

- **Toggle recording** — press the hotkey (default `⌥Space`) to start, press again to stop and transcribe. Also triggerable from the tray menu and the Home recording button.
- **Push to talk** — hold a hotkey to record, release to stop. Unbound by default.
- **Cancel recording** — press the hotkey (default `Esc`) to discard without transcribing. Active only while recording so it doesn't steal `Esc` from other apps.
- **Any-length recordings** — no hard duration limit; long recordings work reliably.
- **Live mic input only** — Jot does not transcribe pre-recorded audio files.
- **Silent-capture detection** — if a recording returns zero-amplitude audio (often a Bluetooth mic that quietly re-routed at the OS level), Jot surfaces an actionable error pointing at the likely culprit instead of returning an empty transcript.
- **Per-device microphone selection** — pick any connected input device in Settings or the Setup Wizard. Jot remembers your selection across sessions, and the picker keeps a disconnected device visible as "Last used (not connected)" so you don't lose track of it.
- **Graceful mic disconnect handling** — if your preferred input device disappears, Jot reacts based on what you're doing. **Idle**: silently falls back to the system default for your next recording and surfaces a small notice in the status pill ("Recorded with system default — AirPods Pro was unavailable"). **Mid-dictation**: salvages the audio captured so far rather than dropping the whole take, with a notice noting how many seconds were saved. **Mid-voice-command** (Rewrite, Ask Jot voice input): cleanly errors out with a "Mic disconnected — try again" pill, since a partial instruction is worse than none. A 250 ms debounce absorbs Bluetooth flicker.

## Local Transcription

- **On-device only** — audio is transcribed locally on the Apple Neural Engine; it never leaves the Mac.
- **Multiple model options** — pick the transcription engine in Settings → Transcription or the Setup Wizard. All run via FluidAudio on the ANE; switching is non-destructive (other models stay installed unless you delete them):
  - **Parakeet TDT 0.6B v3 (multilingual)** — default; broad language coverage. ≈1.25 GB.
  - **Parakeet 0.6B Japanese** — single-language alternative tuned for Japanese-first users. ≈1.25 GB.
  - **Parakeet 0.6B v2 (English, live preview)** — *Experimental.* Pairs the English-only TDT v2 batch transcriber with the Parakeet EOU 120M streaming engine so partial words appear in the recording pill as you speak. The batch transcript remains the authoritative output; streaming text is informational. ≈0.72 GB total across both bundles.
- **In-app model download** — each model is fetched from within Jot on first use with a progress bar.

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

## Rewrite (optional)

Transform selected text via a global shortcut. Two variants, both triggered by their own hotkey:

### Rewrite with Voice — voice-driven
- **Select text anywhere → press the shortcut → speak an instruction** ("make this more formal", "fix the grammar", "translate to Spanish", "convert to bulleted list"). The rewritten text replaces the selection.
- **Intent-classified prompting** — a deterministic regex classifier routes each instruction into one of four branches (voice-preserving / structural / translation / code) and selects a specialized tendency for the LLM. The user's spoken instruction is always the primary signal; the branch just picks a minimal default tendency. Net effect: "make this a bulleted list" or "translate to Japanese" actually produce the requested shape, not a length-matched paraphrase.
- **Cancellable** — `Esc` cancels the capture, transcription, or rewriting phase without committing.
- **Default `⌥.`** — rebindable in Settings → Shortcuts.

### Rewrite — no voice
- **Select text → press the shortcut.** No dictation step. Jot sends the selection to the configured LLM and the result replaces the selection. The shared system prompt's no-instruction fallback ("if no instruction is given, improve clarity / flow / articulation while preserving every piece of information, voice, register, language, and length") governs how the LLM behaves — the LLM itself never sees a literal "Rewrite this" placeholder, which keeps safety-tuned providers (Apple Intelligence, Anthropic Haiku) from refusing.
- **One-hand quick cleanup** — use when you just want the LLM to tidy a passage without speaking an instruction.
- **Default `⌥/`** — rebindable in Settings → Shortcuts.

### Shared configuration
- **Provider options** — Apple Intelligence (on-device, default on macOS 26+), OpenAI, Anthropic, Gemini, or Ollama.
- **Editable shared invariants** — the shared-invariants block (selection-is-text-not-instruction; return-only-the-rewrite; don't-refuse-on-quality; if the user provides an instruction follow it, otherwise improve clarity / flow / articulation while preserving content, voice, register, language, and length) is revealed under a "Customize prompt" chevron in Settings → AI → Rewrite with a "Reset to default" escape hatch. The per-branch tendencies are compile-time constants and not user-editable.

## Ask Jot

- **Dedicated sidebar pane** — a top-level "Ask Jot" entry sits between Home and Settings and opens a full-pane conversational help experience.
- **Grounded answers** — responses are grounded in Jot's bundled help documentation and stream into the chat UI without navigating away from Ask Jot. Apple Intelligence via `FoundationModels` is the default Ask Jot provider, with a 300-token response cap.
- **Cloud provider opt-in** — if the selected AI provider is OpenAI, Anthropic, Gemini, or Ollama, Settings → AI exposes an "Allow Ask Jot to use this provider" toggle. When enabled, Ask Jot can use that provider; otherwise it stays on Apple Intelligence.
- **Voice input in chat** — the input bar includes a mic button that reuses Parakeet ASR plus Rewrite-style Apple Intelligence condensation, with the same pill states as dictation: Recording → Transcribing → Condensing. Condensation has a 10-second budget and silently falls back to the raw transcript if it times out.
- **Fast recovery** — if a turn fails or is interrupted, Ask Jot preserves conversation context and prefills the last question so the user can retry without retyping.
- **In-app feature links** — answers render markdown, surface clickable feature citations inline, and open the matching Help card inside Jot instead of launching a browser.
- **Polished chat controls** — assistant messages use full-width answer blocks with an `ASK JOT` role label and accent rule; the header subtitle reads "On-device help, grounded in Jot's docs"; the input keeps the mic inside the text field; a three-dot typing indicator shows while streaming; the empty state offers three starter prompts; "New chat" is available from the header and `⌘N`.
- **Ask Jot shortcuts** — `⌘K` clears the current conversation, `⌘⇧M` starts voice input, and `Esc` cancels the in-flight response or voice capture.
- **Loop protection** — Ask Jot cancels runaway streams if it detects repeated 6-grams in the recent output.

## Output — Paste & Clipboard

- **Auto-paste at cursor** — transcription is pasted into the frontmost app.
- **Auto-press Enter** — optional; pastes and sends in one step (chat inputs, search boxes).
- **Clipboard preservation** — choose whether the transcript stays on the clipboard or the previous clipboard contents are restored after paste.
- **Copy last transcription** — from the Home card, Recordings detail, the tray menu, or a global shortcut.
- **Quick copy from any row** — an inline copy button on every Home recordings row copies that recording's transcript to the clipboard without opening detail.

## Global Shortcuts

All shortcuts are bindable in the Shortcuts pane. Defaults and bindings:

- **Toggle Recording** — default `⌥Space`.
- **Cancel Recording** — default `Esc`, active only while recording, transforming, or rewriting so it doesn't steal `Esc` from other apps when idle.
- **Paste Last Transcription** — default `⌥,`.
- **Push to Talk** — unbound by default.
- **Rewrite with Voice** — voice-driven rewrite of selected text; default `⌥.`.
- **Rewrite** — applies a fixed `"Rewrite this"` prompt to the selected text (no voice step); default `⌥/`.

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
- **Live preview text** during recording when the streaming option is the active primary — partial transcript appears in the pill alongside the amplitude trail as you speak. Tap the pill to expand into a multi-line scrollable view of the running transcript (latest sentence highlighted, older sentences dimmed); tap again to collapse. Non-streaming primaries leave the pill click-through so taps near the notch pass to the underlying app.
- **States:** Recording (with elapsed time + live waveform; live preview when streaming is active), Transcribing, Cleaning up (when transcript cleanup is on), Rewriting (during Rewrite), Success (with a short preview and Copy), Error (with the message).

## Home & Library

- **Single library surface** — Home now hosts the full library experience: dictation recordings and Rewrite sessions interleave chronologically. There is no separate Library sidebar destination.
- **Hotkey glance + discovery banner** — the Home header keeps the current shortcut summary and the dismissible first-run basics banner.
- **Merged library list** — browse by date group (Today, Yesterday, Last 7 days, …), search across title, transcript, and Rewrite fields (selection / instruction / output / model). A leading icon distinguishes kinds (`waveform` for dictation, `wand.and.stars` for Rewrite).
- **Recording detail** — every dictation recording opens into the waveform/detail view with playback, scrubbing, and the full transcript. Recording row actions: Re-transcribe, Reveal in Finder, Copy, Delete.
- **Rewrite session detail** — every Rewrite run opens into a three-pane view (Selected text → Instruction → Rewritten output) with the model label and flavor in the header. Rewrite row actions: Copy Output, Delete (no playback, no Re-transcribe, no Reveal — Rewrite sessions don't persist audio).
- **Inline management** — rename items inline; retention applies uniformly to both kinds via Settings → General → Keep library items.

## Main Window

Jot runs as a menu-bar app with a single main window opened from the tray and app commands. The window uses a left source-list sidebar for navigation — no separate Settings window.

Sidebar entries:

- **Home** — landing pane plus the full recordings browser.
- **Ask Jot** — conversational help assistant grounded in the in-app docs.
- **Settings** — grouped children: General, Transcription, Vocabulary, Sound, AI, Shortcuts.
- **Help** — Basics, Advanced, Troubleshooting.
- **About** — app identity, privacy pledge, donation link, and the Troubleshooting log-sharing flow.

The main window is the single destination for all five sections — there is no separate Settings window and no global `⌘,` binding (the default SwiftUI `appSettings` command group is intentionally removed).

## Navigation

- **Sidebar history** — every sidebar selection is pushed onto a back/forward stack.
- **Back / forward shortcuts** — `⌘[` moves backward through sidebar history and `⌘]` moves forward. Menu items are disabled when the corresponding stack is empty.

## Settings

Fields throughout Settings carry per-field `info.circle` popovers for inline help. Each popover's "Learn more →" link deep-links into the matching section of the Help tab.

### General
- Input device (microphone) — pick any connected input device; selection is remembered across sessions and the meter restarts so the bars track the newly-bound device. A disconnected preferred device stays visible in the picker as "Last used (not connected)".
- Launch at login
- Library retention — Forever / Last 7 / 30 / 90 days (default: 7 days). Applies to both dictation recordings and rewrite sessions.
- Run setup wizard again (preloads current selections)
- **Restart Jot** — a Troubleshooting row that quits and relaunches the app after a confirmation prompt, re-registering global shortcuts from scratch. Use when a hotkey suddenly produces a Unicode character (≤, ÷, …) instead of triggering its action, which happens when another app grabs the same shortcut while Jot is off.
- **Reset group** — a dedicated section at the bottom of General with three tiered actions:
  - **Reset settings** — clears preferences, API keys, and shortcut bindings; keeps recordings and the downloaded model. Relaunches Jot.
  - **Erase all data** — destructive; wipes recordings, the transcription model (≈600 MB), and all settings. macOS permissions are untouched. Relaunches Jot.
  - **Reset permissions** — runs `tccutil reset All` for Jot so macOS re-asks for Microphone, Input Monitoring, and Accessibility. Relaunches Jot.
  All three require a confirmation alert. Only "Erase all data" is tinted red — the other two are styled as normal interactive rows so they don't read as disabled.

### Transcription
- Transcription model picker — choose between v3 (multilingual, default), Japanese, and v2 + EOU live-preview (experimental). Each row shows install state, footprint, primary radio, and (for the streaming option) an "Experimental" badge. Per-row download / delete affordances; the active primary is preserved across soft resets so a settings reset doesn't surprise the user with a fresh first-run model picker.
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard
- Navigation row to Settings → AI for Cleanup, Rewrite, and other AI transcription features
- Footer note clarifying that AI-powered transcription features are configured in Settings → AI

### Vocabulary
- **Custom vocabulary list** — a short list of user-supplied terms (product names, proper nouns, jargon) that Jot should prefer when transcribing, so names and domain words don't get misheard as their common-word neighbors.
- Inline add / rename / delete of terms; the list is persisted to disk and reloaded on pane open so external edits are picked up.
- Boost-model status row shows download state (not downloaded / downloading / ready / failed) for the small CTC encoder that powers rescoring.

### AI
- Provider (Apple Intelligence / OpenAI / Anthropic / Gemini / Ollama)
- Allow Ask Jot to use this provider (shown when the selected provider is not Apple Intelligence)
- Base URL (left-aligned) and model — override per-provider defaults
- API key (hidden for Ollama — local, no key required)
- Clean up transcript with AI toggle (always visible; disabled until the provider is minimally configured)
- "Customize prompt" disclosure for the transcript-cleanup prompt, with "Reset to default"
- Rewrite section: "Open Shortcuts →" link button that jumps the sidebar to the Shortcuts pane (no hotkey recorders shown here; hotkey binding lives in one place — Settings → Shortcuts)
- "Customize prompt" disclosure for the Rewrite shared invariants, with "Reset to default" (per-branch tendencies are not editable)
- Test Connection button — always enabled, prominent accent-tinted; shows an inline spinner during the call and a success chip afterward. Must succeed before the cleanup toggle unlocks.

### Sound
- Recording start / stop / cancel chimes
- Transcription complete chime
- Error chime

### Shortcuts
- Editable bindings for Toggle Recording, Push to Talk, Paste Last Transcription, Rewrite, Rewrite with Voice. Cancel Recording (Esc) is hardcoded, not configurable, and not shown in the Shortcuts list — a footnote tells the user that Esc is the cancel key and that macOS global hotkeys must include at least one modifier.

## About

A top-level sidebar pane (not a Settings child) for identity, giving back, privacy, and diagnostics.

- App identity (icon, tagline, version / build) and the project vision statement.
- **Check for Updates…** — manual Sparkle update check from the About pane, alongside the current version.
- **Ask Jot entry point** — a dedicated row with a sparkles icon jumps straight into the chatbot.
- **Support Jot** — donation link that routes 100% of contributions to the author's every.org charity fund (opens in the user's browser; no payment flows inside Jot).
- **Privacy pledge** — inline reminder that transcription is local-only and the only automatic network calls are the one-time model download and the daily appcast check.
- **Troubleshooting** — a dedicated section for error reporting:
  - **View log** — opens the local error log in a sheet with a Done button.
  - **Copy log / Reveal in Finder / Send via email** — each goes through a privacy-scan sheet that checks the log for API keys, credential URLs, absolute paths, and your last 90 days of transcripts before handing over the file. Every flow offers an "Auto-redact and …" option when anything sensitive is found. Emails are pre-addressed to `jottranscribe@gmail.com` with app diagnostics pre-filled; the log itself is placed on the clipboard so the user can review before pasting.

## Help

In-app prose walkthrough split across three tabs, each using a shared component library (HelpSection / HelpSubsection / Callout / ExpandableRow / ShortcutChip / AnchorRail) and hand-drawn flow diagrams so concepts are discoverable at a glance, not buried in wall-of-text.

- **Basics** — Dictation, Auto-correct (transcript cleanup), Rewrite (both variants), copying the last transcription, the status pill. Includes visual diagrams of the end-to-end recording → transcription → paste flow.
- **Ask Jot shortcuts from Help** — the three Basics hero cards (Dictation, Cleanup, Rewrite) include a sparkles affordance and right-click "Ask Jot about this" action that opens Ask Jot with a contextual starter prompt.
- **Advanced** — LLM provider setup (Apple Intelligence default on macOS 26+; OpenAI, Anthropic, Gemini, Ollama available as alternates); editable prompts; Sparkle auto-update.
- **Troubleshooting** — permissions (Microphone / Input Monitoring / Accessibility), the macOS "modifier required" hotkey constraint, Bluetooth-redirect capture failures, resetting state, and pointers to the About tab's log-sharing flow for reporting bugs. High-impact cards offer inline action buttons (Open Privacy & Security, Restart Jot, Open AI settings, View log, Copy log) so common recoveries don't require leaving the Help tab.
- **Open in Settings →** — supported Basics rows can jump directly into the matching Settings field and auto-scroll it into view. Deep-linkable targets include toggle recording, push to talk, custom vocabulary, cleanup providers, cleanup prompt, rewrite with voice, and rewrite (the Settings anchor IDs themselves still resolve via the preserved `articulate-custom` / `articulate-fixed` slug strings).

Info popovers across Settings deep-link into the matching Help section so the user can jump from a field to its explanation without context-switching. The deep-link contract is two-phase: an anchor may live inside an `ExpandableRow` that needs to auto-open before the scroll lands, so the page expands the target row first and then scrolls to it.

## Setup Wizard

Shown on first launch and on demand from Settings → General. Eleven steps, in order; each can be skipped. Done is the "you're set up for the basics" checkpoint — most first-run users stop there, and Continue reveals the advanced steps (Vocabulary, AI Provider, Cleanup, Rewrite intro) for power users who want to configure them inline.

1. **Welcome**
2. **Permissions** — grant Microphone, Input Monitoring, and Accessibility. A "Restart Jot" button is offered after granting Input Monitoring or Accessibility (a running app can't detect those until it relaunches). The Input Monitoring row carries an inline instruction: if Jot doesn't auto-populate in the System Settings list, click + → Applications → Jot.
3. **Model** — pick the transcription engine and download it on first run. Three options: Parakeet TDT 0.6B v3 (multilingual), Parakeet 0.6B Japanese, and Parakeet 0.6B v2 + EOU streaming bundle (English live preview) — badged **Recommended** *and* Experimental for new installs. Each row shows an inline Download button next to the size; cached rows show a green "Downloaded" chip. Already-downloaded models skip straight through.
4. **Microphone** — pick the input device for recording. A live input-level meter under the picker confirms the mic is hot before you continue. A disconnected preferred device stays visible as "Last used (not connected)".
5. **Shortcuts** — preview of the default Toggle Recording shortcut.
6. **Test dictation** — speak to verify the full pipeline end-to-end. The user controls the capture window (no hard 3-second cap) and can re-test as many times as they like.
7. **Done** — terminal "you're set up for the basics" card shown right after Test succeeds. Skip here to start using Jot; Continue advances into the advanced steps below.
8. **Vocabulary** (optional) — add custom terms Jot should prefer when transcribing (product names, proper nouns, jargon). Inline Add/Delete with hover affordances, a 100 MB boost-model download row, and a Japanese-primary warning. On a fresh install, adding the first term auto-enables vocabulary boosting and prepares the live rescorer; returning users keep whatever isEnabled state they had.
9. **AI Provider** (optional) — picker for Cleanup / Rewrite provider. Starts at "Choose…" with **no default pre-selected** so users actively pick. Options: Apple Intelligence, OpenAI, Anthropic, Gemini, Ollama. Provider-specific fields (base URL, model, API key) plus Test Connection appear only after a pick. Hides the API-key field for providers that don't use one (Apple Intelligence, Ollama, Flavor-1 JWT). The picker remembers the user's choice across Back/Continue and subsequent wizard reruns.
10. **Cleanup** — introduces Auto-correct (LLM transcript cleanup). When the Test step produced a transcript, a "Preview cleanup" button runs the user's current provider against that transcript so the user sees the before/after inline. The Apple-Intelligence-specific quality disclaimer is only shown when the user actually picked Apple Intelligence — otherwise hidden. No toggle here — actually enabling Auto-correct still happens in Settings → AI.
11. **Rewrite intro** — brief voice-driven-rewrite walkthrough: select → speak instruction → replace. Surfaced after the user has successfully dictated so they know what "Rewrite" means before they're asked to think about binding a shortcut.

## System Integration

- **Launch at login** — auto-start with the Mac.
- **Hide to tray on close** — closing the window keeps Jot running.
- **Only one instance** — launching again focuses the running app.
- **Permissions handled gracefully** — microphone, input monitoring, and accessibility are re-checked on mount and when returning from System Settings.
- **Manual update checks** — "Check for Updates…" is available from the main app menu, the menu-bar extra, and the About pane.
- **Auto-update via Sparkle** — Jot checks for updates daily against the GitHub-hosted appcast and prompts to install verified releases.

## Privacy & Data

- **Core transcription stays local** — audio and transcription never leave the device through the speech-to-text path.
- **Optional AI can be local or cloud** — cleanup, Rewrite, and Ask Jot can run on Apple Intelligence, local Ollama, or a user-configured cloud provider. Jot never sends data to a cloud provider unless the user explicitly enables and configures one.
- **No telemetry** — Jot does not send analytics or crash pings.
- **Retention controls** — configurable via Settings.
