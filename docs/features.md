# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud transcription providers, VAD / continuous listening, pre-recorded file upload, and analytics are intentionally excluded. Core transcription stays local; optional AI features can use Apple Intelligence on-device, local Ollama, or user-configured cloud providers.

> **For agents updating this file:** most major sections end with a `**Related:**` footer that lists the other sections touched by the same feature. When you change a feature, walk the Related links from its section and audit each one for drift — that's the blast radius. Cross-link new features from at least two existing sections in both directions so future agents can find them. Anchor format is GitHub-flavored slugs (lowercased, spaces → `-`, parens / `&` stripped).

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

**Related:** [Local Transcription](#local-transcription), [Settings → General](#general), [Status Indicator](#status-indicator), [Global Shortcuts](#global-shortcuts), [Setup Wizard](#setup-wizard).

## Local Transcription

- **On-device only** — audio is transcribed locally on the Apple Neural Engine; it never leaves the Mac.
- **Multiple model options** — pick the transcription engine in Settings → Transcription or the Setup Wizard. All run via FluidAudio on the ANE; switching is non-destructive (other models stay installed unless you delete them):
  - **Parakeet v3 (multilingual) + Nemotron live preview** — default; multilingual batch transcript with English live preview in the recording pill. Best general-purpose option. ≈1.85 GB.
  - **Parakeet 0.6B Japanese** — single-language alternative tuned for Japanese-first users. ≈1.25 GB.
  - **Parakeet v2 + EOU live preview (deprecated)** — legacy option. Available for existing users; will be removed in a future release. ≈720 MB.
  - **Nemotron (English, lighter)** — English-only. A single model handles both the final transcript and the live preview in the pill. Smaller and faster than option 1; best on read-style English; v2/v3 batch is more accurate on noisy/conversational audio. ≈600 MB.
- **Post-processing (Parakeet v2 only)** — v2 transcripts run through a deterministic cleanup chain before delivery, since v2 emits rawer text than v3 / Nemotron:
  - **Filler-word removal** — regex strip of `um/uh/er/uhm/erm` + recapitalization, no LLM.
  - **Number normalization** — deterministic spoken-number → digit conversion (handles money, percent, year, time-of-day, address, cardinals; preserves idioms and phone-shaped sequences).
  - **Paragraph segmentation** — pause-based `\n\n` breaks when FluidAudio returns token timings.
  - v3 (default + int4 + Nemotron-paired), Japanese, and Nemotron-only deliberately skip this chain — they already emit clean, cased, punctuated text natively, and running the regex pass on top can regress correct casing.
- **In-app model download** — each model is fetched from within Jot on first use with a progress bar.

**Related:** [Recording & Dictation](#recording--dictation), [Settings → Transcription](#transcription), [Settings → Vocabulary](#vocabulary), [Setup Wizard](#setup-wizard), [Status Indicator](#status-indicator).

## Transcript Cleanup (optional)

Off by default. When enabled and an LLM provider is configured, Jot runs a lightweight "cleanup" pass on every transcript before delivery.

- **Remove filler words** (um, uh, like, you know) and false starts.
- **Fix grammar, punctuation, and capitalization.**
- **Preserve meaning, tone, and vocabulary** — no synonym swaps, no injected words.
- **Graceful fallback** — if the LLM call fails or times out (10 s budget), Jot delivers the raw transcript instead.
- **Cleaning-up indicator** — the status pill shows a "Cleaning up…" state during the transform.
- **Raw + cleaned are both stored** — the Recordings detail view offers a "Show original" toggle.
- **Provider options** — Apple Intelligence (on-device, default on macOS 26+; today's on-device model is capacity-limited and Settings → AI shows a quality-caveat banner recommending OpenAI / Anthropic / Gemini / Ollama for stronger results until Apple ships an upgrade), OpenAI, Anthropic, Gemini, or Ollama (fully local).
- **Editable prompt** — the default cleanup prompt (filler removal → grammar → numeric normalization → list detection → paragraph structure → "return only" contract) is shown under a "Customize prompt" chevron in the AI pane. Power users can rewrite it; a "Reset to default" restores the shipped prompt.
- **Prompt safety framing** — LLM cleanup prepends an immutable safety preamble before the editable prompt, treating the transcript as data and preventing embedded transcript instructions from overriding cleanup behavior.
- **Inline "Set up AI →"** — if the Auto-correct toggle is disabled because AI isn't configured, the pane offers a direct jump to the AI pane instead of leaving the user to find it.

**Related:** [Rewrite](#rewrite-optional), [Settings → AI](#ai), [Status Indicator](#status-indicator), [Privacy & Data](#privacy--data).

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

### Prompt picker
- **Catalog overlay** — during Rewrite, a searchable picker can surface curated bundled prompts plus any custom prompts you've authored. Pinned prompts and recently used ones float to the top; the rest are searchable by title or category.
- **Where prompts come from** — the catalog (bundled JSON + your user-added entries) is managed under Settings → Prompts. See [Prompt Library](#prompt-library) for the authoring and browsing surface; this section covers only what the picker shows at rewrite time.
- **Picker invocation** — opens via the rewrite hotkeys depending on the active picker mode; selecting a row applies that prompt to the selected text instead of the default Rewrite behavior.

**Related:** [Prompt Library](#prompt-library), [Settings → Prompts](#prompts), [Settings → AI](#ai), [Settings → Shortcuts](#shortcuts), [Global Shortcuts](#global-shortcuts), [Status Indicator](#status-indicator).

## Prompt Library

A first-class home for the catalog of LLM instructions that drive Rewrite. Visible via Settings → Prompts (sidebar) and indirectly via the rewrite [prompt picker](#prompt-picker). Bundled prompts ship with Jot and are read-only; users can add, edit, delete, and pin their own.

- **30+ bundled prompts** across categories — **Essentials** (improve writing, fix spelling & grammar, make formal / casual / shorter / longer, summarize, extract key points, convert to AI prompt), **Convert** (to Jira ticket, action items, outline, markdown documentation, Mermaid diagram, FAQ, checklist, slide bullets, pros and cons), **Email** (respond, BLUF rewrite, status update, polite decline), **Rewrite** (tighten and clarify, make assertive, plain English, friendly / confident tone, polish for publication, trim AI fluff), **Code** (add comments), **Translate**. Bundled prompts stay read-only and update only via app releases.
- **Custom prompts** — author your own under Settings → Prompts → "My prompts". Title and body are required; sample input/output are optional. Custom prompts are stored locally on this Mac (SwiftData), never synced, never sent over the network unless your configured provider sees them when a prompt is actually used.
- **AI-assisted authoring** — when adding or editing a custom prompt, click **✨ Generate sample** in the editor sheet. Jot calls your configured AI provider to (1) generate a plausible sample input for your prompt body, then (2) run the prompt body against that input to produce the sample output. Both fields fill sequentially with phase indicators ("Generating input…" → "Generating output…"); on failure the button becomes "Try again" with the error message inline.
- **Pin to picker** — pin any prompt (bundled or user-authored) and it floats to the top of the rewrite picker and shows up in a "Pinned" section in Settings → Prompts. Pin/unpin is available on every row and inside the read-only detail sheet.
- **Search** — single search field filters across title, body, and category. Sections with no matches hide entirely so the surface stays compact during search.
- **Inspect any prompt** — tap a bundled prompt row to open a read-only detail sheet with the full body, sample input/output, voice augment hint, provider compatibility list, and tier/category badge. Tap a user prompt row to open the editor.
- **Provider compatibility metadata** — each bundled prompt declares which providers it has been verified against (Apple Intelligence, OpenAI, Anthropic, Gemini, Ollama). The picker may demote rows where the active provider is untested. Custom prompts default to "works with all".

**Related:** [Rewrite](#rewrite-optional), [Prompt picker](#prompt-picker), [Settings → Prompts](#prompts), [Settings → AI](#ai), [Privacy & Data](#privacy--data).

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

**Related:** [Settings → AI](#ai), [Help](#help), [Recording & Dictation](#recording--dictation), [Status Indicator](#status-indicator), [Privacy & Data](#privacy--data).

## Output — Paste & Clipboard

- **Auto-paste at cursor** — transcription is pasted into the frontmost app.
- **Auto-press Enter** — optional; pastes and sends in one step (chat inputs, search boxes).
- **Clipboard preservation** — choose whether the transcript stays on the clipboard or the previous clipboard contents are restored after paste.
- **Copy last transcription** — from the Home card, Recordings detail, the tray menu, or a global shortcut.
- **Quick copy from any row** — an inline copy button on every Home recordings row copies that recording's transcript to the clipboard without opening detail.

**Related:** [Recording & Dictation](#recording--dictation), [Global Shortcuts](#global-shortcuts), [Settings → Transcription](#transcription), [Home & Library](#home--library).

## Global Shortcuts

All shortcuts are bindable in the Shortcuts pane. Defaults and bindings:

- **Toggle Recording** — default `⌥Space`.
- **Cancel Recording** — default `Esc`, active only while recording, transforming, or rewriting so it doesn't steal `Esc` from other apps when idle.
- **Paste Last Transcription** — default `⌥,`.
- **Push to Talk** — unbound by default.
- **Rewrite with Voice** — voice-driven rewrite of selected text; default `⌥.`.
- **Rewrite** — applies a fixed `"Rewrite this"` prompt to the selected text (no voice step); default `⌥/`.

Shortcut bindings require a modifier (⌘, ⌥, ⌃, ⇧) — macOS does not permit global hotkeys bound to a bare key. The Shortcuts pane and the Help tab both surface this. Conflicting bindings are handled gracefully (no two commands silently share a key).

**Related:** [Recording & Dictation](#recording--dictation), [Rewrite](#rewrite-optional), [Output — Paste & Clipboard](#output--paste--clipboard), [Settings → Shortcuts](#shortcuts), [Help](#help).

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

**Related:** [Recording & Dictation](#recording--dictation), [Local Transcription](#local-transcription), [Transcript Cleanup](#transcript-cleanup-optional), [Rewrite](#rewrite-optional), [Ask Jot](#ask-jot).

## Home & Library

- **Single library surface** — Home now hosts the full library experience: dictation recordings and Rewrite sessions interleave chronologically. There is no separate Library sidebar destination.
- **Hotkey glance + discovery banner** — the Home header keeps the current shortcut summary and the dismissible first-run basics banner.
- **Merged library list** — browse by date group (Today, Yesterday, Last 7 days, …), search across title, transcript, and Rewrite fields (selection / instruction / output / model). A leading icon distinguishes kinds (`waveform` for dictation, `wand.and.stars` for Rewrite).
- **Recording detail** — every dictation recording opens into the waveform/detail view with playback, scrubbing, and the full transcript. Recording row actions: Re-transcribe, Reveal in Finder, Copy, Delete.
- **Rewrite session detail** — every Rewrite run opens into a three-pane view (Selected text → Instruction → Rewritten output) with the model label and flavor in the header. Rewrite row actions: Copy Output, Delete (no playback, no Re-transcribe, no Reveal — Rewrite sessions don't persist audio).
- **Inline management** — rename items inline; retention applies uniformly to both kinds via Settings → General → Keep library items.

**Related:** [Recording & Dictation](#recording--dictation), [Rewrite](#rewrite-optional), [Settings → General](#general) (retention), [Output — Paste & Clipboard](#output--paste--clipboard).

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
  - **Reset settings** — clears preferences, API keys, and shortcut bindings; keeps recordings and downloaded models. Relaunches Jot.
  - **Erase all data** — destructive; wipes recordings, downloaded transcription models, and all settings. macOS permissions are untouched. Relaunches Jot.
  - **Reset permissions** — runs `tccutil reset All` for Jot so macOS re-asks for Microphone, Input Monitoring, and Accessibility. Relaunches Jot.
  All three require a confirmation alert. Only "Erase all data" is tinted red — the other two are styled as normal interactive rows so they don't read as disabled.

### Transcription
- Transcription model picker — choose between four local options: Parakeet v3 (multilingual) + Nemotron live preview (default), Parakeet 0.6B Japanese, Parakeet v2 + EOU live preview (deprecated), and Nemotron (English, lighter). Each row shows install state, footprint, primary radio, and relevant badges. Per-row download / delete affordances; the active primary is preserved across soft resets so a settings reset doesn't surprise the user with a fresh first-run model picker.
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard
- Navigation row to Settings → AI for Cleanup, Rewrite, and other AI transcription features
- Footer note clarifying that AI-powered transcription features are configured in Settings → AI

### Vocabulary
**Experimental.** Marked with an inline "Experimental" badge in the Settings pane. The CTC rescoring pipeline is a best-effort boost layered on top of the primary transcription model — it never gates correctness, and the underlying FluidAudio API surface that exposes per-token timings is only available on a subset of models.

- **Custom vocabulary list** — a short list of user-supplied terms (product names, proper nouns, jargon) that Jot should prefer when transcribing, so names and domain words don't get misheard as their common-word neighbors.
- Inline add / rename / delete of terms; the list is persisted to disk and reloaded on pane open so external edits are picked up.
- Boost-model status row shows download state (not downloaded / downloading / ready / failed) for the small CTC encoder that powers rescoring.
- **Model compatibility** — boost applies only when the primary transcription model exposes token timings to the rescorer: v3, v3 int4, v3 + Nemotron preview (the v3 batch run is what's rescored), and v2+EOU. It does NOT apply when the primary is the **Nemotron-only English** model — the streaming Nemotron pipeline returns text without per-token timings, and the rescorer strictly requires `[TokenTiming]` to align keyword spotter hits to word boundaries. Nor does it apply when primary is Japanese. In both unsupported cases the master toggle is disabled in Settings → Vocabulary, your saved terms persist, and boost re-engages automatically when you switch primary to a vocab-capable model.

**Related:** [Local Transcription](#local-transcription), [Setup Wizard](#setup-wizard).

### Prompts
A browser + editor for the prompt catalog used by Rewrite. See [Prompt Library](#prompt-library) for the full feature surface; this row only documents the Settings pane shape.

- **Search bar** — filters across Pinned, the built-in category sections, and My prompts in one keystroke. Sections with zero matches hide.
- **Pinned section** — appears whenever at least one prompt (bundled or user) is pinned. Uniform read-only rows with pin toggle + chevron to detail.
- **Built-in catalog** — per-category sections (Essentials, Convert, Email, Rewrite, Code, Translate, …) listing every shipped prompt. Tap any row to open the read-only detail sheet (full body, sample I/O, voice hint, provider compatibility, pin toggle).
- **My prompts** — user-authored prompts with edit, delete-on-hover, and pin affordances. "Add Prompt" opens the editor sheet.
- **Editor sheet** — title and body (required), sample input and sample output (optional). The ✨ Generate sample button uses your configured AI provider to fill the sample fields sequentially.

**Related:** [Prompt Library](#prompt-library), [Rewrite](#rewrite-optional), [Prompt picker](#prompt-picker), [Settings → AI](#ai).

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

**Related:** [Transcript Cleanup](#transcript-cleanup-optional), [Rewrite](#rewrite-optional), [Ask Jot](#ask-jot), [Prompt Library](#prompt-library), [Settings → Prompts](#prompts), [Setup Wizard](#setup-wizard).

### Sound
- Recording start / stop / cancel chimes
- Transcription complete chime
- Error chime

### Shortcuts
- Editable bindings for Toggle Recording, Push to Talk, Paste Last Transcription, Rewrite, Rewrite with Voice. Cancel Recording (Esc) is hardcoded, not configurable, and not shown in the Shortcuts list — a footnote tells the user that Esc is the cancel key and that macOS global hotkeys must include at least one modifier.

**Related:** [Global Shortcuts](#global-shortcuts), [Recording & Dictation](#recording--dictation), [Rewrite](#rewrite-optional), [Output — Paste & Clipboard](#output--paste--clipboard).

## About

A top-level sidebar pane (not a Settings child) for identity, giving back, privacy, and diagnostics.

- App identity (icon, tagline, version / build) and the project vision statement.
- **Check for Updates…** — manual Sparkle update check from the About pane, alongside the current version.
- **Ask Jot entry point** — a dedicated row with a sparkles icon jumps straight into the chatbot.
- **Support Jot** — a single **Donate to charity** button that opens the in-app donations browser; donations route 100% to the author's every.org charity fund (the actual donate step opens every.org in the user's browser; no payment flows inside Jot). Beneath the button, an inline **"$X raised across N donations"** caption hydrates from the cached `/summary` payload immediately on appear, then refreshes from the donations server in the background. The caption is omitted on a fresh install (no cache and no successful fetch yet) and when the server reports zero donations.
- **Privacy pledge** — inline reminder that transcription is local-only. About-pane network calls are limited to the one-time model download, the daily Sparkle appcast check, and the donations `/summary` GET that hydrates the "raised so far" caption on appear.
- **Troubleshooting** — a dedicated section for error reporting:
  - **View log** — opens the local error log in a sheet with a Done button.
  - **Copy log / Reveal in Finder / Send via email** — each goes through a privacy-scan sheet that checks the log for API keys, credential URLs, absolute paths, and your last 90 days of transcripts before handing over the file. Every flow offers an "Auto-redact and …" option when anything sensitive is found. Emails are pre-addressed to `jottranscribe@gmail.com` with app diagnostics pre-filled; the log itself is placed on the clipboard so the user can review before pasting.

**Related:** [System Integration](#system-integration) (Sparkle), [Ask Jot](#ask-jot), [Privacy & Data](#privacy--data), [Help](#help).

## Help

In-app prose walkthrough split across three tabs, each using a shared component library (HelpSection / HelpSubsection / Callout / ExpandableRow / ShortcutChip / AnchorRail) and hand-drawn flow diagrams so concepts are discoverable at a glance, not buried in wall-of-text.

- **Basics** — Dictation, Cleanup (transcript cleanup), **Prompts** (the hero — covers the 30+ bundled library, the rewrite picker, authoring your own prompts with ✨ Generate sample, pin-to-picker, plus the two Rewrite hotkeys framed as ways to invoke a prompt: Default Rewrite ⌥/ applies the fixed "Rewrite this" prompt, Rewrite with Voice ⌥. speaks a one-off instruction routed through the intent classifier). Includes visual diagrams of the end-to-end recording → transcription → paste flow.
- **Ask Jot shortcuts from Help** — the three Basics hero cards (Dictation, Cleanup, Prompts) include a sparkles affordance and right-click "Ask Jot about this" action that opens Ask Jot with a contextual starter prompt.
- **Advanced** — LLM provider setup (Apple Intelligence default on macOS 26+; OpenAI, Anthropic, Gemini, Ollama available as alternates); editable shared system prompts (Cleanup + Rewrite); the prompt library card (30+ bundled, custom prompts, AI-assisted authoring, pinning, provider compatibility); Sparkle auto-update.
- **Troubleshooting** — permissions (Microphone / Input Monitoring / Accessibility), the macOS "modifier required" hotkey constraint, Bluetooth-redirect capture failures, resetting state, and pointers to the About tab's log-sharing flow for reporting bugs. High-impact cards offer inline action buttons (Open Privacy & Security, Restart Jot, Open AI settings, View log, Copy log) so common recoveries don't require leaving the Help tab.
- **Open in Settings →** — supported Basics rows can jump directly into the matching Settings field and auto-scroll it into view. Deep-linkable targets include toggle recording, push to talk, custom vocabulary, cleanup providers, cleanup prompt, rewrite with voice, and rewrite (the Settings anchor IDs themselves still resolve via the preserved `articulate-custom` / `articulate-fixed` slug strings).

Info popovers across Settings deep-link into the matching Help section so the user can jump from a field to its explanation without context-switching. The deep-link contract is two-phase: an anchor may live inside an `ExpandableRow` that needs to auto-open before the scroll lands, so the page expands the target row first and then scrolls to it.

**Related:** every feature surfaces here. If you change a hotkey, a Settings field, or a pipeline state, audit the Help tab for the matching card. Direct dependencies: [Recording & Dictation](#recording--dictation), [Transcript Cleanup](#transcript-cleanup-optional), [Rewrite](#rewrite-optional), [Ask Jot](#ask-jot), [Global Shortcuts](#global-shortcuts), [Settings](#settings), [About](#about).

## Setup Wizard

Shown on first launch and on demand from Settings → General. Ten steps, in order; each can be skipped. Done is the "you're set up for the basics" checkpoint — most first-run users stop there, and Continue reveals the advanced steps (AI Provider, Cleanup, Rewrite intro) for power users who want to configure them inline. Vocabulary used to live here as an eighth step; it was moved out of the wizard once the rescoring pipeline was marked experimental, and now lives only in Settings → Vocabulary.

1. **Welcome**
2. **Permissions** — grant Microphone, Input Monitoring, and Accessibility. A "Restart Jot" button is offered after granting Input Monitoring or Accessibility (a running app can't detect those until it relaunches). The Input Monitoring row carries an inline instruction: if Jot doesn't auto-populate in the System Settings list, click + → Applications → Jot.
3. **Model** — pick the transcription engine and download it on first run. Four options: Parakeet v3 (multilingual) + Nemotron live preview (default), Parakeet 0.6B Japanese, Parakeet v2 + EOU live preview (deprecated), and Nemotron (English, lighter). Each row shows an inline Download button next to the size; cached rows show a green "Downloaded" chip. Already-downloaded models skip straight through.
4. **Microphone** — pick the input device for recording. A live input-level meter under the picker confirms the mic is hot before you continue. A disconnected preferred device stays visible as "Last used (not connected)".
5. **Shortcuts** — preview of the default Toggle Recording shortcut.
6. **Test dictation** — speak to verify the full pipeline end-to-end. The user controls the capture window (no hard 3-second cap) and can re-test as many times as they like.
7. **Done** — terminal "you're set up for the basics" card shown right after Test succeeds. Skip here to start using Jot; Continue advances into the advanced steps below.
8. **AI Provider** (optional) — picker for Cleanup / Rewrite provider. Starts at "Choose…" with **no default pre-selected** so users actively pick. Options: Apple Intelligence, OpenAI, Anthropic, Gemini, Ollama. Provider-specific fields (base URL, model, API key) plus Test Connection appear only after a pick. Hides the API-key field for providers that don't use one (Apple Intelligence, Ollama, Flavor-1 JWT). The picker remembers the user's choice across Back/Continue and subsequent wizard reruns.
9. **Cleanup** — introduces Auto-correct (LLM transcript cleanup). When the Test step produced a transcript, a "Preview cleanup" button runs the user's current provider against that transcript so the user sees the before/after inline. The Apple-Intelligence-specific quality disclaimer is only shown when the user actually picked Apple Intelligence — otherwise hidden. No toggle here — actually enabling Auto-correct still happens in Settings → AI.
10. **Rewrite intro** — brief voice-driven-rewrite walkthrough: select → speak instruction → replace. Surfaced after the user has successfully dictated so they know what "Rewrite" means before they're asked to think about binding a shortcut.

**Related:** [Recording & Dictation](#recording--dictation), [Local Transcription](#local-transcription), [Settings → AI](#ai), [Settings → Vocabulary](#vocabulary), [Transcript Cleanup](#transcript-cleanup-optional), [Rewrite](#rewrite-optional), [Help](#help).

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
- **Custom prompts stay local** — user-authored prompts in [Settings → Prompts](#prompts) are persisted to SwiftData on this Mac only. They cross the network only when *used* (sent to the configured provider as a system prompt at rewrite time) — same as any other prompt.
- **Retention controls** — configurable via Settings.
- **Automatic network calls (full enumeration)** — first-run transcription model download, daily Sparkle appcast check, About-pane donations `/summary` GET on appear. Every other network call requires explicit user configuration (an LLM provider with an API key, the rewrite/cleanup/Ask Jot flows that talk to it).

**Related:** [Local Transcription](#local-transcription), [Transcript Cleanup](#transcript-cleanup-optional), [Rewrite](#rewrite-optional), [Ask Jot](#ask-jot), [Prompt Library](#prompt-library), [About](#about), [Settings → AI](#ai), [Settings → General](#general) (retention + reset).

---

## Backlog · Planned improvements

Items queued for upcoming releases — UX gaps, bug-shaped product issues, and feature ideas with a clear scope. Each entry links to a plan doc (under `docs/plans/`, internal-only during design) when one exists. This is the user-visible roadmap; for the full design rationale on any item, open the linked plan.

**Convention:** all design / plan docs live under `docs/plans/`. Build a new plan when an entry needs more than a paragraph of detail; the plan path goes into the bullet here.

### UX & polish

- **Shortcuts pane redesign** *(targets v1.13)* — the current Settings → Shortcuts pane shows three rows per action (a trigger-type picker, a recorder, and a footer description) for each of five user-bindable actions. ~16+ control rows of vertical scroll; almost no comparable app uses this multi-row pattern. The redesign collapses to a single binding per action with the trigger type inferred from input, groups actions by purpose (Recording / Rewrite / Capture), adds visible "when this fires" badges, and introduces a search field that scales as shortcuts grow. Internal plan: `docs/plans/shortcuts-pane-redesign.md`. HTML mockup comparing four options lives at `/tmp/jot-shortcuts-mockups/index.html` during the design phase.
- **Ollama detection + local model picker** *(targets v1.13)* — when Ollama is the selected AI provider, replace the freeform "Model" text field with a probe that detects Ollama's state and populates a picker. Four states surface distinct copy: running with models (auto-populated picker by model name + size + parameter family), running with no models (link to `ollama.com/library`), installed but not running ("Open Ollama" button), not installed (link to `ollama.com/download`). Probe is a 2s timeout `GET 127.0.0.1:11434/api/tags`; result cached in `@AppStorage` for warm-boot picker. Internal plan: `docs/plans/ollama-detection.md`.

### Bugs

*(none currently logged)*

### Done in the unreleased dev tree

These have landed in code but haven't shipped yet — listed here so the backlog stays current.

- **Parakeet v3 + EOU pairing** *(v1.12)* — retires the v3+Nemotron pairing in favor of v3+EOU as the multilingual primary. v3 batch's English output was visibly worse than Nemotron's live preview, creating a "transcript got worse at stop" UX bug. EOU is intentionally lighter so the live preview reads as a rough draft. Migration shim auto-rewrites existing v3+Nemotron users. Internal plan: `docs/plans/v3-eou-pairing.md`.
- **JA alias-based vocabulary** *(v1.12)* — unlocks custom vocabulary on the Japanese primary via text-layer alias substitution. Real acoustic CTC rescoring is blocked on two upstream FluidAudio gaps (no `CtcJaKeywordSpotter`, no token timings on `TdtJaManager.transcribe`). Internal plan: `docs/plans/custom-vocabulary-mvp.md` §8–§10.
- **Nemotron-vocab UI guidance** *(v1.12)* — one-click "Switch to Parakeet v3 + EOU" button in Settings → Vocabulary when Nemotron is the active primary, plus a "Doesn't support custom vocabulary" caveat on the Nemotron picker row. Reflects that Nemotron's streaming pipeline can't supply the token timings the rescorer needs.
