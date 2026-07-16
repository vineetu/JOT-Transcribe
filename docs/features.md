# Jot — Feature Inventory

User-facing features in the shipping build. This is the product surface — not implementation. Cloud transcription providers, VAD / continuous listening, and analytics are intentionally excluded. (Local file import now covers audio **and** video — video audio is extracted on-device.) Core transcription stays local; optional AI features can use Apple Intelligence on-device, local Ollama, or user-configured cloud providers.

> **For agents updating this file:** most major sections end with a `**Related:**` footer that lists the other sections touched by the same feature. When you change a feature, walk the Related links from its section and audit each one for drift — that's the blast radius. Cross-link new features from at least two existing sections in both directions so future agents can find them. Anchor format is GitHub-flavored slugs (lowercased, spaces → `-`, parens / `&` stripped).

---

## Recording & Dictation

- **Toggle recording** — press the hotkey (default `⌥Space`) to start, press again to stop and transcribe. Also triggerable from the tray menu and the Recents recording button.
- **Push to talk** — hold a hotkey to record, release to stop. Unbound by default.
- **Cancel recording** — press the hotkey (default `Esc`) to discard without transcribing. Active only while recording so it doesn't steal `Esc` from other apps.
- **Any-length recordings** — no hard duration limit; long recordings work reliably.
- **Import an audio or video file** — drop an existing audio or video file onto the dictate zone on Recents (or click "browse" to pick one) to transcribe it exactly like a live recording, no mic needed. Near-universal format support, all on-device: AVFoundation for the common set, plus a bundled ~3 MB decode-only FFmpeg fallback for the long tail (WebM, MKV, WMA, AVI, …). See [Recents & Library](#recents--library) for the full writeup.
- **Silent-capture detection** — if a recording returns zero-amplitude audio (often a Bluetooth mic that quietly re-routed at the OS level), Jot surfaces an actionable error pointing at the likely culprit instead of returning an empty transcript.
- **Per-device microphone selection** — pick any connected input device in Settings or the Setup Wizard. Jot remembers your selection across sessions, and the picker keeps a disconnected device visible as "Last used (not connected)" so you don't lose track of it.
- **Never lose audio** — a dictation's audio is never thrown away because transcription couldn't run. If the transcriber is busy (a file import or another job is in progress) or errors out, the recording is still **saved to Recents as a pending item** ("Needs transcription" chip) that you re-transcribe with one click — instead of the old behavior where a busy-time dictation was lost. A startup scan also **adopts any orphaned audio** left on disk (from a crash, or from earlier versions) as pending recordings, so nothing you recorded stays lost. An explicit cancel still discards, as expected.
- **Graceful mic disconnect handling** — if your preferred input device disappears, Jot reacts based on what you're doing. **Idle**: silently falls back to the system default for your next recording and surfaces a small notice in the status pill ("Recorded with system default — AirPods Pro was unavailable"). **Mid-dictation**: salvages the audio captured so far rather than dropping the whole take, with a notice noting how many seconds were saved. **Mid-voice-command** (Rewrite, Ask Jot voice input): cleanly errors out with a "Mic disconnected — try again" pill, since a partial instruction is worse than none. A 250 ms debounce absorbs Bluetooth flicker.

**Related:** [Local Transcription](#local-transcription), [Settings → General](#general), [Status Indicator](#status-indicator), [Global Shortcuts](#global-shortcuts), [Setup Wizard](#setup-wizard), [Recents & Library](#recents--library).

## Local Transcription

- **On-device only** — audio is transcribed locally on the Apple Neural Engine; it never leaves the Mac.
- **Language-based model selection** — you pick the **language** you speak (Settings → Transcription or the Setup Wizard); Jot auto-selects and downloads the right on-device model. Model names are hidden — they surface only in About → Acknowledgements. All run via FluidAudio on the ANE; switching is non-destructive (other models stay installed unless you delete them):
  - **English** → **Nemotron** on capable hardware (**≥ 16 GB RAM and an M2 Pro-class-or-newer chip** — any Pro/Max/Ultra from M2 on, or a base chip from M4 on; M1 and base M2/M3 don't qualify), the premium English engine; or **Parakeet v2** on every other Mac (English-optimized batch model — best English accuracy where Nemotron can't run). ≈300–600 MB / ≈600 MB. Custom vocabulary is supported on both (Nemotron via a parallel CTC spotter — see [Settings → Vocabulary](#vocabulary)).
  - **European languages** → shared **Parakeet v3** (multilingual batch) with a FluidAudio Latin/Cyrillic script hint (≈461 MB). On Nemotron-eligible Macs the five largest Latin languages — **Spanish, French, German, Italian, and Portuguese** — ride the Nemotron 3.5 Multilingual "Latin" model instead (folded in with English; see the next bullet); every other European language stays on v3 regardless of hardware.
  - **Japanese** → **Parakeet 0.6B JA** (separate model, no live preview). ≈1.25 GB.
  - **Additional languages via Nemotron 3.5 Multilingual (Experimental)** — on Nemotron-eligible Macs, six languages that have **no Parakeet fallback** become available: **Arabic, Mandarin, Korean, Hindi, Vietnamese, and Turkish**. They run on the on-device **Nemotron 3.5 Multilingual** model (≈640 MB), which also serves the lighter "Latin" variant (≈300 MB) that English + Spanish/French/German/Italian/Portuguese fold into on the same hardware. **Eligibility is identical to the English-Nemotron gate: ≥ 16 GB RAM and an M2 Pro-class-or-newer chip** (any Pro/Max/Ultra from M2 on, or a base chip from M4 on). On a Mac below that bar these six Nemotron-only languages are **shown greyed-out with the reason why** — "Needs a newer Apple Silicon chip (M2 Pro or M4 and later)" for a chip miss, or "Needs a Mac with 16 GB memory or more" for a RAM miss — rather than being hidden, so a user searching for e.g. Arabic learns why it's unavailable instead of getting an empty result. Custom vocabulary does not apply to these six. Marked **Experimental** in the picker (as is **Latvian**, which rides v3 but is its weakest European language). This **supersedes the retired Qwen3-ASR experiment** — existing Qwen users were migrated to English.
- **Post-processing (runs for every model)** — every transcript runs through a deterministic cleanup chain before delivery. One code path, no per-model gate; the two **English-word-driven stages (filler removal + number normalization) run only when the dictation language is English** — their rules are English-hardcoded, and applying them to other languages would mis-convert (e.g. French "six cents" = 600 would become "6¢"). Per-language filler/number rules are future work (see `../jot-shared/docs/multilingual-itn-options.md`). Paragraph segmentation and whitespace cleanup are language-agnostic and run for all languages:
  - **Filler-word removal (English)** — strips `um/uh/er/uhm/erm` (+ elongations), no LLM. Recapitalization is **abbreviation-aware**: the first word and the first word after each sentence-ending `.!?` are capitalized (so under-cased v2 output gets proper per-sentence caps), EXCEPT after a known abbreviation ("Dr.", "e.g.", "i.e.", "vs.", "etc.", dotted acronyms like "U.S.") — so already-cased v3 / Nemotron output isn't corrupted ("See e.g. the example." keeps "the" lowercase). Decimals are immune (only letters are capitalized, and "3.14" has a digit after the dot). A removed sentence-initial filler also exposes its following word to the capital ("Um, hello" → "Hello").
  - **Number normalization (English)** — deterministic spoken-number → digit conversion (handles money, percent, years — including bare "twenty twenty-four" and century forms — decimals ("three point one four" → 3.14), dates ("May fourth" → May 4th), duration homographs ("thirty second timeout" → 30-second, not 30th), time-of-day, address, cardinals; preserves idioms and phone-shaped sequences). Casing-safe and idempotent on already-digit text, so it's safe on every English-capable model (v2, v3-English, Nemotron).
  - **Paragraph segmentation** — pause-based `\n\n` breaks, applied wherever FluidAudio returns token timings (the Parakeet v2/v3/JA batch paths). The Nemotron paths (English + multilingual) return no per-word timings, so segmentation naturally no-ops there and those transcripts stay a single block.
  - The whole chain is shared with Jot for iPhone via the `JotTextPipeline` package (`../jot-shared`), so both apps normalize identically and are pinned by one golden-fixture suite.
- **In-app model download experience** — each model is fetched from within Jot on first use, surfaced through one shared, honest status component (never a spinner-on-a-bar). A single **determinate progress bar** shows **size · speed · ETA** ("214 MB of 640 MB · 8 MB/s · about 1 min left"), and a distinct **Preparing** phase covers the post-download CoreML compile/load so 100% never dead-airs into a hang. **Error messages name the real cause** rather than a generic "check your connection": *offline* (you must reconnect), *the model server is temporarily unavailable* (the host is down, not your Wi-Fi), *not enough disk space*, or *incomplete files* — and a raw server error body is never shown to the user. When the failure is a **server outage or a transient corrupt fetch, Jot auto-retries with backoff** (30 → 60 → 120 → 240 → capped at 300 s) with a live "Retrying in Ns…" countdown and a "Retry now" button, while you keep dictating on your current model the whole time. The status renders as a **compact card floating in the window's bottom-right corner** (not a full-width top banner) — an ambient status, not a modal — and if a background download fails while the main window is closed, a **retry row surfaces in the menu bar** ("… download failed — retry").
- **Manual model override (Advanced)** — power users can override the auto-selected model with a **"Transcription model" picker in Settings → General** (visible only when Advanced is on; hiding it never changes the active model). Switching to a not-yet-installed model **downloads-then-flips**: you keep dictating on the current model until the new one's bytes are fully on disk, then it swaps — no window where the active model is uninstalled, and no old model is ever deleted on a switch. The intent is persisted, so a switch whose download was interrupted resumes on the next launch or when the network returns.
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
- **On-pill guidance hint** — while the capture pill is open it shows what to say ("Say a change — e.g. "make it formal" — or nothing to just clean it up"), so the pill no longer looks identical to ordinary dictation and users don't freeze wondering what's happening.
- **Say nothing → clean-up, not an error** — if you press the shortcut and speak no instruction (or the mic auto-stops after a 10-second wait), Jot falls through to a default clean-up rewrite of the selection instead of erroring out.
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
- **Return to the app I started in** — opt-in, off by default; delivers the transcript back to the app that was frontmost when dictation started (refocusing it), even if you switched apps while speaking. Never yanks you across Spaces or full-screen apps to deliver text.
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

A small floating overlay near the menu bar — a Dynamic Island-style pill — that reflects pipeline state without stealing focus. The pill is deliberately monochrome: its live signals (amplitude waveform, state dots) render in a fixed ink-grey silver on the black body rather than following the macOS accent color, so the only colored element the pill ever shows is the highlighted word on a "Did you mean X?" ask card.

- **Live amplitude waveform** during recording — renders the actual audio level as a sine-wave-style animation inside the pill so the user can see Jot is hearing them. No static gif / fake animation.
- **Live preview text** during recording when the streaming option is the active primary — partial transcript appears in the pill alongside the amplitude trail as you speak. Tap the pill to expand into a multi-line scrollable view of the running transcript (latest sentence highlighted, older sentences dimmed); tap again to collapse. Non-streaming primaries leave the pill click-through so taps near the notch pass to the underlying app.
- **States:** Recording (with elapsed time + live waveform; live preview when streaming is active), Transcribing, Cleaning up (when transcript cleanup is on), Rewriting (during Rewrite), **Did you mean X?** (the custom-vocabulary ask-before-paste prompt with Use term / Keep original controls and a ~10 s timeout), Success (with a short preview and Copy), Error (with the message).
- **Movable** — the pill can be dragged anywhere on screen by grabbing its visible capsule (panel-level drag, smooth 1:1, works in every pill state). The position is **session-only** — it resets to the default below-the-notch placement on the next launch.

**Related:** [Recording & Dictation](#recording--dictation), [Local Transcription](#local-transcription), [Transcript Cleanup](#transcript-cleanup-optional), [Rewrite](#rewrite-optional), [Ask Jot](#ask-jot).

## Recents & Library

- **Single library surface** — **Recents** (renamed from **Home** in v1.13; the underlying pane and storage are unchanged) hosts the full library experience: dictation recordings and Rewrite sessions interleave chronologically. There is no separate Library sidebar destination.
- **Hotkey glance + discovery banner** — the Recents header keeps the current shortcut summary and the dismissible first-run basics banner. When the Advanced toggle is off (slim mode for fresh installs that didn't complete the Setup Wizard), the banner appends a one-line hint pointing at Settings → General → Advanced so users can discover the gated surface.
- **Merged library list** — browse by date group (Today, Yesterday, Last 7 days, …), search across title, transcript, tags, and Rewrite fields (selection / instruction / output / model). A leading icon distinguishes kinds (`waveform` for dictation, `wand.and.stars` for Rewrite).
- **Tag filter** — a chip bar above the list surfaces the tags in use; tap one to filter to recordings carrying that tag. The filter scans the whole library (not just the loaded page), so older tagged recordings still surface.
- **Infinite scroll** — the list pages in rows as you scroll (30 at a time) instead of the old hard 50-row cap, so long histories are fully browsable.
- **AI semantic search** — searching the library augments plain substring matching with on-device semantic recall (find a recording by meaning, not just exact words). It runs **EmbeddingGemma-300M** locally, indexes transcripts in the background, and is **ON by default** (opt-out in Settings). On first run it downloads the embedding model (~328 MB) once and gently backfills the existing library; substring search keeps working the whole time and semantic results arrive silently as the index fills. Semantic recall is tuned/verified for English; it never replaces substring search, only adds to it. See [AI semantic search](#ai-semantic-search) below.
- **Recording detail (redesigned)** — every dictation recording opens into a "reading surface": the transcript renders in a serif body font (New York) for comfortable reading, above a **slim playback bar** (play/pause + scrubber + elapsed/total — no waveform stub). Recording row actions: Re-transcribe, Reveal in Finder, Copy, Delete.
- **Editable transcripts** — the recording detail has an **Edit** toggle: switch the transcript into an editable field, fix anything the model got wrong, and hit **Done** to save. The original machine transcript is always recoverable via the existing "Show original" toggle, and Re-transcribe (disabled while editing) replaces an edited transcript without warning — editing is for when you simply want the text right, regardless of the audio. Edited recordings show a small "edited" marker.
- **Tags** — add free-form tags (chips) to any recording in its detail view, independent of the transcript text. Tags feed the library search and the tag filter bar.
- **Speaker diarization ("Detect speakers")** — an on-demand button in the recording detail view labels who spoke when, fully on-device. It runs FluidAudio's offline VBx pipeline (best-quality, not the old streaming engine) over the recording's audio, then renders the transcript split into per-speaker, colour-coded blocks (with a "Show plain" toggle). Speakers are labeled **"Speaker 1 / 2 / 3 …"** in the order they first appear; **right-click any speaker label → "Rename speaker…"** to name them (e.g. your own name), which renames that person across every one of their turns. The result is saved on the recording, so it's computed once and never re-run. A genuinely single-speaker recording is detected and skipped ("Single speaker — nothing to label"). **Imported audio/video files are diarized automatically** right after they transcribe (on by default; toggle in Settings → Speaker labels, Advanced) — the speaker model downloads on first use — so a dropped meeting gets speaker labels without a click, while live mic dictations stay manual-only via the button. Either way it's serialized against transcription so the two never contend for the Neural Engine. **Best for meeting & call recordings where each person is on clean, separate audio** (Zoom/Meet recordings, a video's own soundtrack) — it is *not* reliable for audio captured acoustically through speakers or a single room mic, where voices blur together. A **1-hour recording diarizes in ~20–30 seconds.**
- **Export transcript as WebVTT** — an **Export** button in the recording detail view saves the transcript as a `.vtt` file. If speakers were detected, each turn becomes a timestamped cue with a `<v Speaker N>` voice tag (works in video players, subtitle tools, and transcription apps); otherwise it's a single-cue transcript. Same on-device data, no upload.
- **Rewrite session detail** — every Rewrite run opens into a stacked three-pane reading view (Instruction → Original → Rewritten) with the model label and flavor in the header. Rewrite row actions: Copy Output, Delete (no playback, no Re-transcribe, no Reveal — Rewrite sessions don't persist audio).
- **Inline management** — rename items inline; retention applies uniformly to both kinds via Settings → General → Keep library items.
- **Transcribe an existing audio or video file** — drag an audio **or video** file onto the Dictate zone on Recents (drag-over shows a "Release to transcribe" cue), or click the quiet "browse" affordance underneath it to pick one via the standard Open panel. The file transcribes on the same on-device pipeline as a live recording, then is transcoded to the same AAC `.m4a` format used for mic recordings and saved as a normal row — playable, searchable, re-transcribable, and diarizable, indistinguishable from a dictation once it lands. **Format coverage is essentially universal, all on-device:** AVFoundation natively handles the common set (mp3, m4a, wav, FLAC, AAC, plus mp4/mov/m4v video), and for everything Apple can't read — **WebM, MKV, WMA, AVI, FLV, and more** — Jot falls back to a bundled ~3 MB decode-only FFmpeg (network-free) that extracts the audio track. Only a file with no audio track, copy-protected (DRM) content, or a genuinely unreadable/corrupt file shows a clear inline error. Only one file transcribes at a time; drop several and they queue. A live dictation always takes priority — starting one cancels any in-flight file import rather than risk losing what you just said. **Progress is shown while it works:** on the standard Parakeet model a real percent-complete bar; on Nemotron and the streaming Parakeet variants (which don't expose a progress signal here) an honest elapsed-time counter ("Transcribing… 1:23") rather than a made-up estimate.
- **`jot` command-line tool** — a bundled CLI (`Jot.app/Contents/Helpers/jot`) that transcribes any audio/video file to **WebVTT** from the terminal, with an optional `--diarize` for speaker labels: `jot transcribe meeting.mp4 --diarize -o out.vtt`. Reuses the same on-device engine + bundled ffmpeg + the app's downloaded models — nothing leaves the Mac, no network. This is the honest home for diarization: feed it a clean meeting recording, get labeled, timestamped turns out. Add it to your PATH with `sudo ln -s /Applications/Jot.app/Contents/Helpers/jot /usr/local/bin/jot`.
- **Mic and file transcription never collide — and a paused import auto-resumes** — because the on-device transcriber only runs one job at a time, a dropped file could otherwise stall (or lose) an in-progress dictation. The instant you start dictating, Jot **pauses** a running file import (the pill reads "Paused — resumes after dictation") and refuses to start a new one — a live take is never sacrificed for a background job. When your dictation finishes, the paused import **auto-resumes on its own**: re-transcribing from the start, or — if the transcript was already saved and only speaker detection was left — just re-running that. No need to re-drop the file.

### AI semantic search
- **What it does** — on top of the instant substring filter, Jot ranks recordings by semantic similarity to your query, so you can find a recording by what it was about even when you don't remember the exact wording.
- **On-device** — embeddings are computed locally with **EmbeddingGemma-300M** (Core ML, ANE). Nothing about the index or your queries leaves the Mac. The model is downloaded once (~328 MB) on first use, not bundled.
- **Background indexing** — existing recordings are backfilled gradually in the background; new recordings are embedded as they arrive. The index lives on-device alongside your recordings.
- **On by default, opt-out** — semantic search is enabled by default; a toggle disables it. Disabling falls back cleanly to substring-only search, which always works regardless of the toggle or index state.
- **Scope note** — semantic recall quality is tuned for English transcripts; for other languages it degrades gracefully to the always-present substring search.

**Related:** [Recording & Dictation](#recording--dictation), [Rewrite](#rewrite-optional), [Settings → General](#general) (retention), [Output — Paste & Clipboard](#output--paste--clipboard), [Privacy & Data](#privacy--data) (semantic-search model download).

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
- **AI semantic search** — toggle for on-device semantic recall in the recordings list (default **on**; opt-out). Stored under `jot.semanticSearch.enabled`. Turning it off falls back to substring-only search and stops indexing; substring search always works regardless. See [AI semantic search](#ai-semantic-search).
- **Transcription model (Advanced)** — an advanced-only "Transcription model" picker (shown only when Advanced is on, directly under the language field) that overrides the model Jot would auto-select from your language. Selecting a not-yet-installed model **downloads it in the background and flips only when the bytes land** — you keep dictating on the current model meanwhile — and turning Advanced off just hides the control without changing the active model. See [Local Transcription](#local-transcription).
- **Show advanced features** — master toggle that hides power-user surfaces (Vocabulary sub-row, Ask Jot sidebar entry, About-pane Ask Jot section, Help Basics sparkle affordances, Push-to-Talk row, Paste Last Result row) so first-run users see a smaller surface. Fresh installs start with this **off** and completing the Setup Wizard automatically flips it **on**. Existing v1.12 users upgrade with it on (no visible change). Toggling never deletes data — hidden surfaces preserve state on disk and existing hotkey bindings keep firing even when their Settings row is hidden. See [Main Window → Advanced toggle](#advanced-toggle).
- Run setup wizard again (preloads current selections)
- **Restart Jot** — a Troubleshooting row that quits and relaunches the app after a confirmation prompt, re-registering global shortcuts from scratch. Use when a hotkey suddenly produces a Unicode character (≤, ÷, …) instead of triggering its action, which happens when another app grabs the same shortcut while Jot is off.
- **Reset group** — a dedicated section at the bottom of General with three tiered actions:
  - **Reset settings** — clears preferences, API keys, and shortcut bindings; keeps recordings and downloaded models. Relaunches Jot.
  - **Erase all data** — destructive; wipes recordings, downloaded transcription models, and all settings. macOS permissions are untouched. Relaunches Jot.
  - **Reset permissions** — runs `tccutil reset All` for Jot so macOS re-asks for Microphone, Input Monitoring, and Accessibility. Relaunches Jot.
  All three require a confirmation alert. Only "Erase all data" is tinted red — the other two are styled as normal interactive rows so they don't read as disabled.

### Transcription
- Transcription language picker — the user picks the **language** they speak; Jot resolves and downloads the right on-device model automatically (model names are hidden — they surface only in About → Acknowledgements). English → **Nemotron** on capable hardware (≥ 16 GB and an M2 Pro-class-or-newer chip — premium English engine) or **Parakeet v2** elsewhere; European languages → shared Parakeet v3 with a FluidAudio Latin/Cyrillic script hint (the five largest Latin languages ride the Nemotron "Latin" model on eligible Macs); Japanese → Parakeet 0.6B JA (separate model, no live preview); and six **Nemotron 3.5 Multilingual** languages (Arabic, Mandarin, Korean, Hindi, Vietnamese, Turkish) reachable only on Nemotron-eligible Macs. Default is the system locale's language, falling back to English. The model is chosen automatically by hardware tier; a **Nemotron-only language on hardware below the ≥ 16 GB / M2-Pro-class bar is shown greyed-out with the reason** rather than hidden. Shows install state + footprint + a percentage download for the resolved model, and an `info.circle` popover deep-linking to Help → "Transcription language". A stored model choice is grandfathered with no surprise download: the stored model always wins over the language's default until the user deliberately re-picks a language.
- Auto-paste transcription
- Auto-press Enter after paste
- Keep transcription in clipboard
- Navigation row to Settings → AI for Cleanup, Rewrite, and other AI transcription features
- Footer note clarifying that AI-powered transcription features are configured in Settings → AI

### Vocabulary
**Experimental.** Marked with an inline "Experimental" badge in the Settings pane. The CTC rescoring pipeline is a best-effort boost layered on top of the primary transcription model — it never gates correctness, and the underlying FluidAudio API surface that exposes per-token timings is only available on a subset of models. The Vocabulary sub-row is hidden in the Settings sidebar when the Advanced toggle is off (its stored terms persist and re-appear when Advanced is re-enabled).

- **Custom vocabulary list** — a short list of user-supplied terms (product names, proper nouns, jargon) that Jot should prefer when transcribing, so names and domain words don't get misheard as their common-word neighbors.
- Inline add / rename / delete of terms; the list is persisted to disk and reloaded on pane open so external edits are picked up.
- **Anti-overcorrection gate** — a multilingual gate decides whether a spotted vocab term should actually replace what was decoded, using a CTC margin, a plausibility metric, and a common-word brake. The goal is to fix genuine mishears (your product name heard as a common word) without forcing your term onto audio that didn't contain it.
- **Ask before paste** — when the gate is unsure (e.g. a silent out-of-vocabulary near-match, or an otherwise-plausible swap), the status pill surfaces a live **"Did you mean X?"** prompt with **⏎ / Use term / Keep original** controls and a ~10-second timeout that resolves to keeping the original. Confirming applies the term and learns the correction for next time.
- **Learned corrections** — confirmed asks (and explicit mappings) are stored with provenance, so Jot remembers how to spell a term the way you want. Learned corrections are reviewable in Settings → Vocabulary.
- **Right-click "Add to Vocabulary…"** — select any text in a recording's transcript reader and right-click to open a mapping editor ("when Jot hears X → spell as Y"), so you can teach Jot a correction straight from a transcript where it got something wrong.
- Boost-model status row shows download state (not downloaded / downloading / ready / failed) for the small CTC encoder that powers spotting / rescoring.
- **Model compatibility** — custom vocabulary works on the **Parakeet** family (v3, v3 int4, v2 — the batch run is rescored via token timings) **and on the Nemotron English model** (v1.13.1): because Nemotron's stream returns no per-token timings, Jot instead runs the CTC keyword **spotter on the audio in parallel** with the Nemotron decode, then places the detections onto the transcript and applies the same gate — wall-clock stays ≈ max(decode, spot), and a vocab-off / spotter-error path is a byte-identical pass-through that never blocks dictation. It does NOT apply to **Japanese** (alias-only text substitution; no CTC JA spotter or token timings from FluidAudio) or the **experimental Nemotron 3.5 Multilingual languages** (Arabic / Mandarin / Korean / Hindi / Vietnamese / Turkish — the spotter is English/Latin-oriented). In the unsupported cases your saved terms persist and re-engage automatically when you switch to a vocab-capable model.

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
- Base URL (left-aligned) and model — override per-provider defaults. The model picker is a hand-curated per-provider list (no unauthenticated cloud catalog probe exists): OpenAI offers **GPT-5.6 Luna** (the default) and **GPT-5.6 Terra**; Anthropic offers Claude Sonnet 5 / Claude Haiku 4.5; Gemini offers Gemini 3.1 Flash-Lite / Gemini 3.5 Flash. A stored model id you picked earlier keeps working even if it's since dropped from the list.
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
- **Jot for iPhone** — a row that opens the macOS **share sheet** for the companion iOS app's App Store link, so you can AirDrop or Message it straight to your phone (where it opens in the App Store). No tracking — a static store URL.
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
- **Semantic search stays local** — the [AI semantic search](#ai-semantic-search) index and your queries never leave the Mac; embeddings run on-device via EmbeddingGemma. The only network touch is the one-time, ~328 MB model download on first use (default-on; disable semantic search to skip it).
- **Retention controls** — configurable via Settings.
- **Automatic network calls (full enumeration)** — first-run transcription model download, the one-time EmbeddingGemma download for semantic search (default-on; skipped if you disable semantic search), daily Sparkle appcast check, About-pane donations `/summary` GET on appear. Every other network call requires explicit user configuration (an LLM provider with an API key, the rewrite/cleanup/Ask Jot flows that talk to it).

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
- **Movable status pill** — the overlay pill can be dragged anywhere on screen by its visible capsule (panel-level drag, smooth 1:1, works in every state). Position is session-only and resets to the below-the-notch default on the next launch. See [Status Indicator](#status-indicator). Internal design: `docs/movable-pill/design.md`.
- **Custom vocabulary, full pass** — multilingual anti-overcorrection gate, learned corrections with provenance, an ask-before-paste **"Did you mean X?"** pill (~10 s timeout), and a right-click **"Add to Vocabulary…"** mapping on transcript selections. Custom vocabulary now also works on the **Nemotron English** model via a parallel CTC spotter (supersedes the v1.12 "Nemotron doesn't support custom vocabulary" guidance below). Still unsupported on Japanese (alias-only) and the experimental Nemotron 3.5 Multilingual languages. See [Settings → Vocabulary](#vocabulary).
- **AI semantic search** — on-device EmbeddingGemma-300M semantic recall layered on top of substring search in the recordings list; background indexing, on by default (opt-out), one-time ~328 MB model download on first use. See [AI semantic search](#ai-semantic-search). Internal design: `docs/ai-search/design.md`.
- **Recordings detail redesign** — serif "reading surface" transcript (New York), a slim playback bar (no waveform stub), and a stacked Instruction → Original → Rewritten layout for Rewrite sessions. See [Recents & Library](#recents--library).
- **Infinite scroll in the recordings list** — the old hard 50-row cap is replaced by paged loading (30 rows at a time) as you scroll. See [Recents & Library](#recents--library).
- **macOS deployment floor raised 14 → 15** — build target and `Info.plist` `LSMinimumSystemVersion` are now 15.0 (required to adopt the Core ML LLM / embedding paths). README, CLAUDE.md, and the website still say "macOS 14+ / Sonoma 14.0+" and need updating (see follow-ups).
- **Speaker diarization ("Detect speakers")** — the dormant Sortformer "Speaker Labels" scaffolding (wrong engine, nursery-rhyme enrollment) was ripped out and replaced with an on-demand, on-device FluidAudio **offline VBx** pipeline: per-speaker labeled transcript in the recording detail, anonymous "Speaker 1/2/3" labels (first-appearance order) renameable per recording via right-click, result persisted per recording, single-speaker recordings skipped. Serialized against ASR on the Neural Engine. (Owner-voice auto-recognition was removed — an uncalibrated placeholder that didn't generalize; manual rename replaces it.) Honestly scoped in-UI to clean/separate-audio recordings, not same-room/acoustic capture. See [Recents & Library](#recents--library). Internal design: `docs/speaker-diarization/design.md`, `docs/resilient-transcription/`.
- **Export transcript as WebVTT** — an Export button in the recording detail writes a `.vtt`: diarized → `<v Speaker N>` timestamped voice cues; non-diarized → a single cue. Pure `WebVTTExporter` formatter, shared conceptually with the CLI. Design: `docs/webvtt-export/design.md`.
- **File-transcription progress** — determinate where honest: a real percent bar on Parakeet (FluidAudio's `transcriptionProgressStream`), an elapsed-time counter on Nemotron (no stream; a time-estimate would lie given RTF varies with length). Design: `docs/transcription-progress/design.md`.
- **`jot` CLI** — a bundled, self-contained command-line transcriber (`Contents/Helpers/jot`, signed + hardened runtime like the ffmpeg helper) reusing the on-device engine → WebVTT, `--diarize` for word-aligned speaker cues. Standalone SPM package `tools/jot-cli/`. Design: `docs/jot-cli/design.md`.
- **Transcribe an existing audio or video file** — drop or pick an audio or video file on the Recents dictate zone; it runs the same on-device pipeline, transcodes to the library m4a, and saves a normal (playable, searchable, diarizable) row. AVFoundation covers the common audio/video set; a bundled ~3 MB decode-only, network-free FFmpeg fallback (`Contents/Helpers/ffmpeg`, LGPL) extracts audio from the long tail (WebM, MKV, WMA, AVI, FLV, …). Only no-audio/DRM/corrupt files are rejected, with a clear message. A live dictation always preempts an in-flight file import (and kills the ffmpeg decode if one is running). See [Recents & Library](#recents--library). Internal design: `docs/audio-file-transcription/design.md` (§7 video, §8 FFmpeg).
- **Return to the app I started in** — opt-in delivery mode (Settings → General, advanced): captures the frontmost app at dictation start and re-activates it (via the Accessibility API) before pasting, so the transcript lands back where you began even if you switched apps mid-dictation. Off by default; never yanks across Spaces. See [Output — Paste & Clipboard](#output--paste--clipboard). Internal design: `docs/return-to-origin-app/design.md`.

### Released — v1.18.0

- **Nemotron 3.5 Multilingual languages (replaces the Qwen3-ASR experiment)** — six languages with no Parakeet fallback (**Arabic, Mandarin, Korean, Hindi, Vietnamese, Turkish**) become selectable on Nemotron-eligible Macs, running on the on-device Nemotron 3.5 Multilingual model; its lighter "Latin" variant also folds in English + Spanish/French/German/Italian/Portuguese on the same hardware. **Eligibility gate: ≥ 16 GB RAM and an M2 Pro-class-or-newer chip** (any Pro/Max/Ultra from M2 on, or a base chip from M4 on). Below the bar the six Nemotron-only languages are shown **greyed-out with the reason** ("Needs a newer Apple Silicon chip (M2 Pro or M4 and later)" / "Needs a Mac with 16 GB memory or more") rather than hidden. The retired Qwen3-ASR experiment is gone; existing Qwen users were migrated to English. See [Local Transcription](#local-transcription).
- **Manual model override (Advanced)** — a "Transcription model" picker in Settings → General (Advanced-only) overrides the auto-selected model. A switch to a not-installed model **downloads-then-flips** (keep dictating on the current model until the new one is ready; no model is ever deleted on a switch), and a persisted intent resumes an interrupted switch on the next launch. See [Local Transcription](#local-transcription), [Settings → General](#general).
- **Model-download experience overhaul** — one determinate progress bar with **size · speed · ETA**, a distinct **Preparing** phase, **honest error messages** that name the real cause (offline vs the model server being down vs low disk — never a generic "check your connection"), **automatic retry with backoff** on a transient server outage (with a live countdown + "Retry now"), keep-dictating-meanwhile, a **compact status card floating in the window's bottom-right** instead of a full-width banner, and a **retry row in the menu bar** when a background download fails with the window closed. See [Local Transcription](#local-transcription). Design: `docs/plans/model-download-ux-mockup.html`.
- **Rewrite with Voice guidance + empty-instruction clean-up** — the capture pill now shows an on-pill hint of what to say, and saying nothing (or letting the mic auto-stop after 10 s) falls through to a default clean-up rewrite instead of erroring. See [Rewrite](#rewrite-optional).
- **Cloud picker: GPT-5.6** — the OpenAI model picker now lists **GPT-5.6 Luna** (default) and **GPT-5.6 Terra**; older 5.4/5.5 ids dropped from the list but any stored id still works. See [Settings → AI](#ai).

### Released — v1.12

- **Parakeet v3 + EOU pairing** — retires the v3+Nemotron pairing in favor of v3+EOU as the multilingual primary. v3 batch's English output was visibly worse than Nemotron's live preview, creating a "transcript got worse at stop" UX bug. EOU is intentionally lighter so the live preview reads as a rough draft. Migration shim auto-rewrites existing v3+Nemotron users. Internal plan: `docs/plans/v3-eou-pairing.md`.
- **JA alias-based vocabulary** — unlocks custom vocabulary on the Japanese primary via text-layer alias substitution. Real acoustic CTC rescoring is blocked on two upstream FluidAudio gaps (no `CtcJaKeywordSpotter`, no token timings on `TdtJaManager.transcribe`). Internal plan: `docs/plans/custom-vocabulary-mvp.md` §8–§10.
- **Nemotron-vocab UI guidance** — one-click "Switch to Parakeet v3 + EOU" button in Settings → Vocabulary when Nemotron is the active primary, plus a "Doesn't support custom vocabulary" caveat on the Nemotron picker row. Reflects that Nemotron's streaming pipeline can't supply the token timings the rescorer needs.
