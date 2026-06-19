# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud transcription providers, VAD / continuous listening, pre-recorded file upload, and analytics are intentionally excluded. Core transcription stays local; optional AI features can use Apple Intelligence on-device, local Ollama, or user-configured cloud providers.

> **For agents updating this file:** most major sections end with a `**Related:**` footer that lists the other sections touched by the same feature. When you change a feature, walk the Related links from its section and audit each one for drift — that's the blast radius. Cross-link new features from at least two existing sections in both directions so future agents can find them. Anchor format is GitHub-flavored slugs (lowercased, spaces → `-`, parens / `&` stripped).

---

## Recording & Dictation

- **Toggle recording** — press the hotkey (default `⌥Space`) to start, press again to stop and transcribe. Also triggerable from the tray menu and the Recents recording button.
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
- **Language-based model selection** — you pick the **language** you speak (Settings → Transcription or the Setup Wizard); Jot auto-selects and downloads the right on-device model. Model names are hidden — they surface only in About → Acknowledgements. All run via FluidAudio on the ANE; switching is non-destructive (other models stay installed unless you delete them):
  - **English** → **Nemotron** on capable hardware (≥ M2 Pro **and** ≥ 16 GB RAM — the premium English engine, true low-latency streaming), or **Parakeet v2** on every other Mac (English-optimized batch model — best English accuracy where Nemotron can't run). ≈600 MB / ≈720 MB.
  - **European languages** → shared **Parakeet v3** (multilingual batch) with a FluidAudio Latin/Cyrillic script hint. ≈1.85 GB.
  - **Japanese** → **Parakeet 0.6B JA** (separate model, no live preview). ≈1.25 GB.
- **Post-processing (Parakeet v2 only)** — v2 transcripts run through a deterministic cleanup chain before delivery, since v2 emits rawer text than v3 / Nemotron:
  - **Filler-word removal** — regex strip of `um/uh/er/uhm/erm` + recapitalization, no LLM.
  - **Number normalization** — deterministic spoken-number → digit conversion (handles money, percent, year, time-of-day, address, cardinals; preserves idioms and phone-shaped sequences).
  - **Paragraph segmentation** — pause-based `\n\n` breaks when FluidAudio returns token timings.
  - v3 (default + int4 + Nemotron-paired), Japanese, and Nemotron-only deliberately skip this chain — they already emit clean, cased, punctuated text natively, and running the regex pass on top can regress correct casing.
- **In-app model download** — each model is fetched from within Jot on first use with a progress bar.
- **Startup self-healing** — at launch (and after an auto-update relaunch) Jot verifies the active transcription model actually *loads*, not just that its files are present — so a truncated or corrupt model (interrupted download, disk issue) is caught proactively instead of at the cursor when you next dictate. If a model side is broken, Jot surgically re-downloads only the affected part (never the shared multilingual batch bundle), shows the progress on a window-independent status pill, and opens Settings → Transcription so you can see what's happening. The re-download retries on the next launch if it fails.
- **Never blocks dictation during a repair** — if your active model is re-downloading and you press the dictation hotkey, Jot temporarily transcribes on another installed English model (preferring Parakeet v2) and shows a "Temporarily using … while … re-downloads" notice, then flips back automatically once the repair completes. Only when no alternate English model is installed do you wait for the download (with a live progress pill).

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
- **Editable prompt** — the cleanup prompt (filler removal → grammar → numeric normalization → list detection → paragraph structure → "return only" contract) is managed in the unified **Settings → Prompts → Cleanup** section, alongside every other prompt, under a "Customize prompt" chevron with a "Reset to default" escape hatch. The Auto-correct on/off toggle stays in Settings → AI (it governs whether cleanup runs automatically); a "Open Prompts →" link there jumps straight to the editor.
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
- **Select text → press the shortcut.** No dictation step. Jot sends the selection to the configured LLM and the result replaces the selection.
- **Selectable default prompt** — a tap on the Rewrite hotkey fires your chosen **default prompt**. Set it from any prompt row in Settings → Prompts (the bolt icon / "Set as default") or promote the prompt you're about to use from the hold-picker with `⌘D`. The default prompt is marked with a "Default" badge in the panel and a bolt in the picker. When no default is set, the tap falls back to the shared system prompt's no-instruction behavior (improve clarity / flow / articulation while preserving every piece of information, voice, register, language, and length) — the LLM never sees a literal "Rewrite this" placeholder, which keeps safety-tuned providers (Apple Intelligence, Anthropic Haiku) from refusing.
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
- **Set as default** — mark any prompt (bundled or user-authored) as the default fired by a tap on the Rewrite hotkey. Settable from every row (bolt icon), from a bundled prompt's detail sheet, or from the hold-picker (`⌘D`); a "Default" badge marks the current pick and tapping the affordance again clears it (tap reverts to the shared Rewrite prompt). Deleting the custom prompt that was the default clears the selection automatically.
- **Cleanup prompt is a managed entry** — the automatic post-dictation Cleanup prompt is editable in the Prompts panel's "Cleanup" section, so all prompt text lives in one place. The Auto-correct on/off toggle remains in Settings → AI.
- **Search** — single search field filters across title, body, and category. Sections with no matches hide entirely so the surface stays compact during search.
- **Inspect any prompt** — tap a bundled prompt row to open a read-only detail sheet with the full body, sample input/output, voice augment hint, provider compatibility list, and tier/category badge. Tap a user prompt row to open the editor.
- **Provider compatibility metadata** — each bundled prompt declares which providers it has been verified against (Apple Intelligence, OpenAI, Anthropic, Gemini, Ollama). The picker may demote rows where the active provider is untested. Custom prompts default to "works with all".

**Related:** [Rewrite](#rewrite-optional), [Prompt picker](#prompt-picker), [Settings → Prompts](#prompts), [Settings → AI](#ai), [Privacy & Data](#privacy--data).

## Ask Jot

- **Dedicated sidebar pane** — a top-level "Ask Jot" entry sits between Help and About (hidden when the Advanced toggle is off) and opens a full-pane conversational help experience.
- **Grounded answers** — responses are grounded in Jot's bundled help documentation and stream into the chat UI without navigating away from Ask Jot. Apple Intelligence via `FoundationModels` is the default Ask Jot provider, with a 300-token response cap.
- **Follows the global AI provider** — Ask Jot uses whichever provider you've configured in Settings → AI (Apple Intelligence, OpenAI, Anthropic, Gemini, or Ollama). To keep Ask Jot on Apple Intelligence, set the global provider to Apple Intelligence. Users who had explicitly opted out via the v1.12 "Allow Ask Jot to use this provider" toggle retain their privacy preference — Ask Jot stays on Apple Intelligence for them and a one-time banner explains the change.
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
- **Copy last transcription** — from the Recents card, Recordings detail, the tray menu, or a global shortcut.
- **Quick copy from any row** — an inline copy button on every Recents recordings row copies that recording's transcript to the clipboard without opening detail.

**Related:** [Recording & Dictation](#recording--dictation), [Global Shortcuts](#global-shortcuts), [Settings → Transcription](#transcription), [Recents & Library](#recents--library).

## Global Shortcuts

All shortcuts are bindable in the Shortcuts pane. Defaults and bindings:

- **Toggle Recording** — default `⌥Space`.
- **Cancel Recording** — default `Esc`, active only while recording, transforming, or rewriting so it doesn't steal `Esc` from other apps when idle.
- **Paste Last Transcription** — default `⌥,`.
- **Push to Talk** — unbound by default.
- **Rewrite with Voice** — voice-driven rewrite of selected text; default `⌥.`.
- **Rewrite** — applies a fixed `"Rewrite this"` prompt to the selected text (no voice step); default `⌥/`.

Each action can use either a **chord** (one or more modifiers + a key — macOS does not permit Carbon global hotkeys bound to a bare key) or a **single key**. The single-key picker offers Caps Lock, Fn / Globe, the right-side modifiers, and any function key **F1–F20**, detected via NSEvent (requires Accessibility permission). For function keys, F1–F12 only reach Jot when macOS's "Use F1, F2, etc. as standard function keys" setting is on (otherwise hold Fn); F13–F20 are unaffected but aren't on every keyboard. The Shortcuts pane and the Help tab both surface this. Conflicting bindings are handled gracefully (no two commands silently share a key).

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

## Recents & Library

- **Single library surface** — **Recents** (renamed from **Home** in v1.13; the underlying pane and storage are unchanged) hosts the full library experience: dictation recordings and Rewrite sessions interleave chronologically. There is no separate Library sidebar destination.
- **Hotkey glance + discovery banner** — the Recents header keeps the current shortcut summary and the dismissible first-run basics banner. When the Advanced toggle is off (slim mode for fresh installs that didn't complete the Setup Wizard), the banner appends a one-line hint pointing at Settings → General → Advanced so users can discover the gated surface.
- **Merged library list** — browse by date group (Today, Yesterday, Last 7 days, …), search across title, transcript, and Rewrite fields (selection / instruction / output / model). A leading icon distinguishes kinds (`waveform` for dictation, `wand.and.stars` for Rewrite).
- **Recording detail** — every dictation recording opens into the waveform/detail view with playback, scrubbing, and the full transcript. Recording row actions: Re-transcribe, Reveal in Finder, Copy, Delete.
- **Rewrite session detail** — every Rewrite run opens into a three-pane view (Selected text → Instruction → Rewritten output) with the model label and flavor in the header. Rewrite row actions: Copy Output, Delete (no playback, no Re-transcribe, no Reveal — Rewrite sessions don't persist audio).
- **Inline management** — rename items inline; retention applies uniformly to both kinds via Settings → General → Keep library items.

**Related:** [Recording & Dictation](#recording--dictation), [Rewrite](#rewrite-optional), [Settings → General](#general) (retention), [Output — Paste & Clipboard](#output--paste--clipboard).

## Main Window

Jot runs as a menu-bar app with a single main window opened from the tray and app commands. The window uses a left source-list sidebar for navigation — no separate Settings window.

Sidebar entries:

- **Recents** — landing pane plus the full recordings browser. (Previously labeled "Home" in v1.12 and earlier; the underlying pane and storage are unchanged.)
- **Ask Jot** — conversational help assistant grounded in the in-app docs. Hidden when the Advanced toggle is off.
- **Settings** — grouped children: General, Transcription, Vocabulary (hidden when Advanced is off), Sound, AI, Shortcuts. The Settings disclosure group is collapsible and the state persists across launches; clicking the "Settings" header navigates to General without force-expanding the group.
- **Help** — Basics, Advanced, Troubleshooting.
- **About** — app identity, privacy pledge, donation link, and the Troubleshooting log-sharing flow.

The main window is the single destination for all five sections — there is no separate Settings window and no global `⌘,` binding (the default SwiftUI `appSettings` command group is intentionally removed).

### Advanced toggle

A master toggle in **Settings → General** controls which power-user surfaces are visible. When **off**, four surfaces are hidden: the Vocabulary sub-row under Settings, the Ask Jot sidebar entry, the About-pane Ask Jot section + the Help Basics sparkle affordances, and the Push-to-Talk + Paste Last Result rows in Settings → Shortcuts. When **on**, the sidebar matches the v1.12 layout. Existing users upgrading to v1.13 keep Advanced on (no visible change). Fresh installs start with Advanced off; completing the Setup Wizard automatically flips it on. Toggling never deletes data — hidden surfaces preserve their state on disk, and existing hotkey bindings continue to fire even when their Settings row is hidden.

## Navigation

- **Sidebar history** — every sidebar selection is pushed onto a back/forward stack.
- **Back / forward shortcuts** — `⌘[` moves backward through sidebar history and `⌘]` moves forward. Menu items are disabled when the corresponding stack is empty.

## Settings

Fields throughout Settings carry per-field `info.circle` popovers for inline help. Each popover's "Learn more →" link deep-links into the matching section of the Help tab.

### General
- Input device (microphone) — pick any connected input device; selection is remembered across sessions and the meter restarts so the bars track the newly-bound device. A disconnected preferred device stays visible in the picker as "Last used (not connected)".
- Launch at login
- Library retention — Forever / Last 7 / 30 / 90 days (default: 7 days). Applies to both dictation recordings and rewrite sessions.
- **Show advanced features** — master toggle that hides power-user surfaces (Vocabulary sub-row, Ask Jot sidebar entry, About-pane Ask Jot section, Help Basics sparkle affordances, Push-to-Talk row, Paste Last Result row) so first-run users see a smaller surface. Fresh installs start with this **off** and completing the Setup Wizard automatically flips it **on**. Existing v1.12 users upgrade with it on (no visible change). Toggling never deletes data — hidden surfaces preserve state on disk and existing hotkey bindings keep firing even when their Settings row is hidden. See [Main Window → Advanced toggle](#advanced-toggle).
- Run setup wizard again (preloads current selections)
- **Restart Jot** — a Troubleshooting row that quits and relaunches the app after a confirmation prompt, re-registering global shortcuts from scratch. Use when a hotkey suddenly produces a Unicode character (≤, ÷, …) instead of triggering its action, which happens when another app grabs the same shortcut while Jot is off.
- **Reset group** — a dedicated section at the bottom of General with three tiered actions:
  - **Reset settings** — clears preferences, API keys, and shortcut bindings; keeps recordings and downloaded models. Relaunches Jot.
  - **Erase all data** — destructive; wipes recordings, downloaded transcription models, and all settings. macOS permissions are untouched. Relaunches Jot.
  - **Reset permissions** — runs `tccutil reset All` for Jot so macOS re-asks for Microphone, Input Monitoring, and Accessibility. Relaunches Jot.
  All three require a confirmation alert. Only "Erase all data" is tinted red — the other two are styled as normal interactive rows so they don't read as disabled.

### Transcription
- Transcription language picker — the user picks the **language** they speak; Jot resolves and downloads the right on-device model automatically (model names are hidden — they surface only in About → Acknowledgements). English → **Nemotron** on capable hardware (≥ M2 Pro and ≥ 16 GB — premium English engine) or **Parakeet v2** elsewhere (best English accuracy where Nemotron can't run); 25 European languages → shared Parakeet v3 with a FluidAudio Latin/Cyrillic script hint; Japanese → Parakeet 0.6B JA (separate model, no live preview). Default is the system locale's language, falling back to English. The English model is chosen automatically by hardware tier; European and Japanese are tier-independent, and Nemotron is reachable only for English on eligible Macs. Shows install state + footprint + a percentage download for the resolved model, and an `info.circle` popover deep-linking to Help → "Transcription language". A stored model choice (v3 / Nemotron / v2) is grandfathered with no surprise download: the stored model always wins over the language's default until the user deliberately re-picks a language.
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard
- Navigation row to Settings → AI for Cleanup, Rewrite, and other AI transcription features
- Footer note clarifying that AI-powered transcription features are configured in Settings → AI

### Vocabulary
**Experimental.** Marked with an inline "Experimental" badge in the Settings pane. The CTC rescoring pipeline is a best-effort boost layered on top of the primary transcription model — it never gates correctness, and the underlying FluidAudio API surface that exposes per-token timings is only available on a subset of models. The Vocabulary sub-row is hidden in the Settings sidebar when the Advanced toggle is off (its stored terms persist and re-appear when Advanced is re-enabled).

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
- Provider (Apple Intelligence / OpenAI / Anthropic / Gemini / Ollama). Ask Jot follows this selection by default; users who had toggled the v1.12 "Allow Ask Jot to use this provider" opt-in OFF before upgrading keep Ask Jot pinned to Apple Intelligence (no per-provider opt-in lives in this pane anymore).
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
- Editable bindings for Toggle Recording, Push to Talk, Paste Last Transcription, Rewrite, Rewrite with Voice. Cancel Recording (Esc) is hardcoded, not configurable, and not shown in the Shortcuts list — a footnote tells the user that Esc is the cancel key and that chord global hotkeys must include at least one modifier.
- Each row can switch between a chord binding and a **single-key** binding (Caps Lock, Fn, a right-side modifier, or a function key **F1–F20**, grouped under a "Function keys" header in the picker). The row's info popover notes that F1–F12 only register as function keys when macOS's "Use F1, F2, etc. as standard function keys" setting is on (otherwise hold Fn), and that F13–F20 aren't present on every keyboard.
- **Push to Talk** and **Paste Last Transcription** rows are hidden when the Advanced toggle is off. Their bindings still fire — only the configuration UI is gated.

**Related:** [Global Shortcuts](#global-shortcuts), [Recording & Dictation](#recording--dictation), [Rewrite](#rewrite-optional), [Output — Paste & Clipboard](#output--paste--clipboard).

## About

A top-level sidebar pane (not a Settings child) for identity, giving back, privacy, and diagnostics.

- App identity (icon, tagline, version / build) and the project vision statement.
- **Check for Updates…** — manual Sparkle update check from the About pane, alongside the current version.
- **Ask Jot entry point** — a dedicated row with a sparkles icon jumps straight into the chatbot. Hidden when the Advanced toggle is off.
- **Support Jot** — a single **Donate to charity** button that opens the in-app donations browser; donations route 100% to the author's every.org charity fund (the actual donate step opens every.org in the user's browser; no payment flows inside Jot). Beneath the button, an inline **"$X raised across N donations"** caption hydrates from the cached `/summary` payload immediately on appear, then refreshes from the donations server in the background. The caption is omitted on a fresh install (no cache and no successful fetch yet) and when the server reports zero donations.
- **Privacy pledge** — inline reminder that transcription is local-only. About-pane network calls are limited to the one-time model download, the daily Sparkle appcast check, and the donations `/summary` GET that hydrates the "raised so far" caption on appear.
- **Troubleshooting** — a dedicated section for error reporting:
  - **View log** — opens the local error log in a sheet with a Done button.
  - **Copy log / Reveal in Finder / Send via email** — each goes through a privacy-scan sheet that checks the log for API keys, credential URLs, absolute paths, and your last 90 days of transcripts before handing over the file. Every flow offers an "Auto-redact and …" option when anything sensitive is found. Emails are pre-addressed to `jottranscribe@gmail.com` with app diagnostics pre-filled; the log itself is placed on the clipboard so the user can review before pasting.
  - **Send Feedback** — a single feedback button (consolidated in v1.13 — the separate "Send bug report" row was removed) that opens a composer sheet with the redacted log and app-details footer pre-filled. An in-sheet "Show original log" toggle reveals the un-redacted log on demand. Attach **up to 3 screenshots** via the paperclip button (NSOpenPanel restricted to image content types); each attachment renders as a thumbnail with an inline X to remove it. A live upload-size counter shows the current payload; oversized payloads are reduced automatically through iterative JPEG quality reduction to fit the 5 MB server cap, and an inline "too large" error surfaces if the encoder can't bring the payload under cap. Submit stays disabled while any attachment is mid-encode so partial uploads never ship.

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
3. **Language** — "What language will you speak?" The step shows a single language menu (default = the system locale's language, falling back to English; model names hidden), a size-only download hint, and a percentage Download button for the resolved model. Jot auto-selects and downloads the right model — English → Parakeet v2, European → Parakeet v3, Japanese → Parakeet JA. The advance gate keys on the resolved primary model alone (it does not require a live-preview/EOU companion, so Japanese — which has none — can satisfy it). Already-downloaded models skip straight through. The optional vocabulary-boost (CTC 110M) section remains below and is non-blocking.
4. **Microphone** — pick the input device for recording. A live input-level meter under the picker confirms the mic is hot before you continue. A disconnected preferred device stays visible as "Last used (not connected)".
5. **Shortcuts** — preview of the default Toggle Recording shortcut.
6. **Test dictation** — bind your dictation hotkey and verify the full pipeline end-to-end in one merged step. Redesigned in v1.13: one focal chip displays the currently-bound key with a gentle pulse animation while waiting for you to press it. Three quick-pick chips below offer Caps Lock, ⌥ Right Option, and ⌥ Space — tap any to bind, no recorder needed. A **Custom…** button opens an inline recorder for arbitrary chords. The previous "Trigger type: Single key | Chord" picker is gone — the wizard infers chord vs single-key from what you actually pick. If Input Monitoring isn't granted, a banner surfaces immediately at page load with a "Grant in System Settings" deep-link button (replacing the prior 12-second silent timer). Header copy adapts: fresh installs see "Press the key combination you want to use to start a recording"; returning users with a non-default binding see "Looks like you already have a hotkey — let's make sure it works." The actual capture window has no hard 3-second cap and can be re-tested as many times as you like.
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

### Website & marketing *(redesign shipped to repo 2026-06-11)*

Full website v2 redesign landed in `website/` (commit `e947729`; design spec in `docs/website-design.md`, research in `docs/research/website-redesign-2026.md`, local-only): text wordmark (black dotless-j + blue wave tittle from the iPhone icon, red reserved for recording cues), golden-ratio type scale + Fibonacci spacing, animated recording-pill demo, hover-highlighted feature rows, device-aware dual Mac/iPhone download CTAs, LinkedIn-ready OG card, and an unlisted `/admin/` Mission Control dashboard (live GitHub download metrics, post composer with UTM links + share intents, LinkedIn card preview, GoatCounter hookup).

**TODOs:**

- ~~Deploy blocked~~ **Resolved 2026-06-12:** the site is live at **https://jot-transcribe.com/** (Vercel project `jot-transcribe`, deployed from `~/code/jot-website/jot-transcribe.com/`; `/admin/` and `/donations/` both resolve). All site/doc references synced to the new domain. The old `jot.ideaflow.page` still serves the legacy deployment — retire or redirect it eventually.
- Reassign the Simple Host `jot` site record from `jamychatterjee@gmail.com` (created there by accident) to `vineetu@gmail.com`.
- Analytics: create a GoatCounter account, uncomment the script tag at the bottom of `website/index.html` with the site code, and connect the same code in the `/admin/` traffic panel.
- Replace the CSS typing demo in the hero with a real 5–8 s muted screen-recording loop of an actual dictation (<2 MB MP4/WebM, poster fallback on mobile) — research says real capture beats simulation for credibility.
- Icon unification: Mac app icon (black + red dot) and iPhone app icon (blue + white wave) still differ; the website defines the target mark (black j + blue wave). Regenerate the OG card and favicon once the icons converge.
- Run the LinkedIn Post Inspector on `https://jot-transcribe.com/` before the first launch post (LinkedIn caches link previews ~7 days).
- Build the competitor matrix from `docs/research/website-redesign-2026.md` (Google AI Edge Eloquent / Wispr Flow / Superwhisper / VoiceInk / Handy / hardware devices — raw tables are ready there).
- Product idea surfaced during marketing review: **auto-categorize dictations** (LLM tag pass — email / note / prompt / message — fits the existing Transform pipeline). Must ship in the app before the website can market it.
- ~~Short custom domain~~ **Done 2026-06-12:** `jot-transcribe.com`.
- `/admin/` can't show iPhone install counts (App Store Connect has no public API) — consider an outbound link to App Store Connect analytics.

### Bugs

*(none currently logged)*

### Done in the unreleased dev tree

These have landed in code but haven't shipped yet — listed here so the backlog stays current.

- **Advanced mode master toggle** *(v1.13)* — new **Settings → General → Show advanced features** switch. Hides Vocabulary, Ask Jot (sidebar + About-pane row + Help Basics sparkles), Push-to-Talk and Paste Last Result Shortcuts rows when off. Fresh installs start off; Setup Wizard completion auto-flips it on. Existing v1.12 users upgrade with it on (zero visible change). Toggling never deletes data and hidden hotkey bindings still fire. See [Main Window → Advanced toggle](#advanced-toggle) and [Settings → General](#general).
- **Home → Recents rename** *(v1.13)* — sidebar label and pane title now read "Recents." Strings-only rename; underlying pane and storage are unchanged.
- **Ask Jot follows the global provider** *(v1.13)* — the v1.12 "Allow Ask Jot to use this provider" toggle has been removed. Ask Jot now uses whichever AI provider is configured globally. Users who explicitly toggled the old setting OFF retain their preference (Ask Jot stays on Apple Intelligence for them) and a one-time first-open banner explains the change.
- **Collapsible Settings group in the sidebar** *(v1.13)* — the Settings sidebar group (General / Transcription / Vocabulary / Sound / AI / Shortcuts) is now a disclosure that can collapse to a single row. State persists across launches. Clicking the "Settings" header label navigates to General without forcing the group to expand.
- **Setup Wizard model step simplification** *(v1.13)* — the model step defaults to a single pre-selected Nemotron row with a Download button. A "Show 3 more options" disclosure expands to reveal Parakeet v3 multilingual + EOU, Parakeet Japanese, and Parakeet v2 (deprecated, listed last). The whole disclosure row is clickable, and the disclosure auto-expands for returning users whose stored model is not Nemotron.
- **Send Feedback: screenshot attachments** *(v1.13)* — attach up to 3 images to a feedback report via a paperclip → NSOpenPanel flow. Thumbnails render with X-to-remove, a live upload-size counter is visible, and iterative JPEG quality reduction is applied automatically to fit a 5 MB server cap. Inline "too large" error surfaces if the encoder can't fit the payload; Submit is gated against partial encodes.
- **Send Feedback consolidated to a single button** *(v1.13)* — the separate "Send bug report" row in About-pane Troubleshooting has been removed. The single Send Feedback button always includes the redacted log + app-details footer pre-filled, and the in-sheet "Show original log" toggle is preserved.

#### Bug fixes in v1.13

- **Speaker Labels card no longer leaks into Settings → Transcription.** The card was rendering even though the feature's kill switch said hide; the kill switch is now respected. Speaker Labels itself remains gated by the kill switch and invisible to users.

### Released — v1.12

- **Parakeet v3 + EOU pairing** — retires the v3+Nemotron pairing in favor of v3+EOU as the multilingual primary. v3 batch's English output was visibly worse than Nemotron's live preview, creating a "transcript got worse at stop" UX bug. EOU is intentionally lighter so the live preview reads as a rough draft. Migration shim auto-rewrites existing v3+Nemotron users. Internal plan: `docs/plans/v3-eou-pairing.md`.
- **JA alias-based vocabulary** — unlocks custom vocabulary on the Japanese primary via text-layer alias substitution. Real acoustic CTC rescoring is blocked on two upstream FluidAudio gaps (no `CtcJaKeywordSpotter`, no token timings on `TdtJaManager.transcribe`). Internal plan: `docs/plans/custom-vocabulary-mvp.md` §8–§10.
- **Nemotron-vocab UI guidance** — one-click "Switch to Parakeet v3 + EOU" button in Settings → Vocabulary when Nemotron is the active primary, plus a "Doesn't support custom vocabulary" caveat on the Nemotron picker row. Reflects that Nemotron's streaming pipeline can't supply the token timings the rescorer needs.
