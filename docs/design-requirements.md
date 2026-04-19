# Jot — Design Requirements

Stack-agnostic requirements for the app. This document describes **what** Jot must do and the constraints it must satisfy — not **how** it's implemented. Intended as the reference for any future rewrite.

---

## Product Summary

A macOS utility that turns a hotkey press into typed text. The user presses a shortcut, speaks, and the resulting transcription is pasted at their cursor. Everything runs on-device.
---

## Functional Requirements

### Dictation pipeline
- **Hotkey-driven recording.** A single global shortcut starts recording; pressing it again stops and transcribes.
- **Push-to-talk.** An alternate mode where holding a key records and releasing it ends the recording.
- **Cancel.** A dedicated shortcut discards the current recording without transcribing. The cancel key is only claimed while a recording is active, so it doesn't interfere with other apps.
- **No length limit.** Recordings of arbitrary duration transcribe reliably.
- **Automatic transcription.** Transcription runs immediately after the recording ends.
- **Re-transcription.** The user can re-run transcription on any past recording.

### Transcription
- **Local-only.** Audio is transcribed on the device. It never crosses the network.
- **Parakeet on the Apple Neural Engine.** Parakeet is the transcription engine, running on the Neural Engine (ANE) on Apple Silicon for low latency and low power draw. Rationale and benchmarks in `docs/research/parakeet-vs-moonshine-benchmark.md` and `docs/research/parakeet-vs-moonshine.md`.
- **Model catalogue.** Several Parakeet models spanning a size / accuracy trade-off.
- **In-app model management.** Downloading, selecting, and switching models happens inside the app with clear progress feedback.

### Output
- **Paste at cursor.** Transcribed text is inserted into the frontmost app at the current caret position.
- **Optional auto-Enter.** Users can opt to send the paste (useful for chat inputs and search fields).
- **Clipboard policy.** Users choose whether the transcript stays on the clipboard or the prior clipboard contents are restored after paste.
- **Copy last transcription.** A quick command to copy the most recent transcription — available from the main UI, the menu bar, and a dedicated shortcut.

### Optional LLM post-processing
- **Transcript cleanup (Transform).** Off by default. When enabled and an LLM provider is configured, Jot runs a lightweight cleanup pass (remove filler words and false starts, fix grammar/punctuation) between transcription and delivery. Must preserve the speaker's meaning, tone, and vocabulary; must fall back to the raw transcript on any failure. Both raw and cleaned transcripts are persisted so the user can review what changed.
- **Voice-driven rewrite (AI Rewrite).** Select text anywhere, trigger a dedicated shortcut, speak an instruction, and have an LLM rewrite the selection in place. Opt-in; unbound by default. The spoken instruction is the primary signal: the system must classify the intent (voice-preserving / structural / translation / code) and select a specialized tendency block, but the user's instruction always takes precedence over any branch default. Structural transforms ("convert to bullets", "numbered steps") and translation must produce the requested shape, not a length-matched paraphrase.
- **Provider neutrality.** OpenAI-compatible (GPT / Ollama / any self-hosted endpoint exposing `/chat/completions`), Anthropic, and Gemini (including Vertex-style endpoints) are all supported. Ollama is a first-class option so privacy-sensitive users can keep the LLM path local too.
- **Configured-unlocks-the-toggle.** Cleanup is gated on whether a provider is configured at all — provider == Ollama, or a non-empty API key, base URL, or model. Test Connection is a manual diagnostic the user can run to confirm reachability; it does not unlock the toggle, and runtime failures fall back to the raw transcript.
- **Editable prompts.** The cleanup (Transform) prompt is fully user-editable. For Rewrite, the user-editable surface is the shared-invariants block only — the per-branch tendency blocks that the classifier selects from are compile-time constants and not surfaced for editing, to keep the classifier/tendency contract intact. Both paths ship with "reset to default."

### Recordings library
- **Browse history.** A chronologically grouped list of every recording with its transcript.
- **Search.** Free-text search across title, subtitle, and transcript.
- **Playback.** Inline waveform with play/pause and scrub.
- **Rename inline.**
- **Per-recording actions.** Re-transcribe, Reveal in finder/files, Delete (with confirmation).
- **Retention controls.** User-selectable retention window (forever / 7 / 30 / 90 days) with automatic cleanup.
- **Home quick access.** The most recent transcription is one click away from the main screen.

### Status indicator
- **Pipeline state must be visible.** The user can tell at a glance whether Jot is recording, transcribing, showing a just-finished transcript, or reporting an error.
- **Dynamic Island-style presentation.** Modeled after iOS's Dynamic Island: a compact pill that expands to show the relevant state and contracts away when idle. On Mac, it is anchored below the notch on notch-equipped displays (and in the equivalent position on non-notch displays).
- **Non-intrusive.** Does not steal focus, does not block clicks to the apps behind it.
- **Short-lived.** Success and error states auto-dismiss; only the active recording state persists for the duration of the recording.

### Menu bar presence
- A tray / menu-bar extra providing: toggle recording, copy last transcription, show main window, open settings, and quit.
- The recording command's label reflects current state.

### Settings
- **Input device** (microphone selection).
- **Transcription defaults** — auto-paste, auto-Enter, clipboard policy, optional transcript-cleanup toggle (gated on a configured LLM provider).
- **AI** — provider / base URL / model / API key / shortcut / test-connection / editable prompts.
- **Sounds** — per-event audio feedback (start, stop, cancel, success, error).
- **Shortcuts** — editable bindings for every global command, surfaced with `KeyboardShortcuts.Recorder`. Must communicate the platform constraint that global hotkeys require a modifier.
- **General** — launch at login, retention policy (default 7 days), reset-permissions escape hatch, re-open setup wizard.

### In-app help
- **Prose walkthrough of every user-facing feature** is available inside the app (not only via external docs). Must cover Basics, Advanced (provider setup, editable prompts, auto-update), and Troubleshooting (permissions, BT-redirect, hotkey constraints). Each Settings field should have a lightweight inline explanation and an affordance to jump to the matching Help section.

### Setup wizard
- **Guided first-run.** Walks the user through permissions, model download, microphone selection, and a working test of the full pipeline.
- **Re-runnable.** Available on demand from Settings; each step preloads the user's current selections.
- **Skippable.** The user can exit the wizard at any point without being forced through.

### Permissions
- **Microphone access** must be explicitly granted before recording.
- **Input Monitoring** must be granted so global shortcuts fire from any app.
- **Accessibility (post events)** must be granted before synthetic paste and AI Rewrite's synthetic copy work. Denied Accessibility must degrade to clipboard-only delivery with a clear toast — never a dead end.
- **Graceful handling.** The app must continuously observe permission state and guide the user to resolution when access is revoked or deferred. Some grants (Input Monitoring, Accessibility) are cached per-process by macOS, so a restart is offered when the user grants them for the first time.
- **Reset path.** The user can wipe the app's privacy entries and start fresh.

### Window behaviour
- **One instance.** Launching again focuses the running app rather than spawning a duplicate.
- **Hide to menu bar on close.** Closing the main window does not quit the app.
- **Keyboard parity with native apps.** `⌘,` opens settings, `⌘Q` quits, standard Mac shortcuts work in text fields.

---

## Non-Functional Requirements

### Privacy
- **No audio, transcript, or settings data leaves the device.** Ever.
- **No telemetry.** No usage analytics, crash reporting, or error pings.
- **No accounts.** The app is usable without signing in anywhere.

### Performance
- **Low-latency paste.** From stop-recording to pasted text should feel instant for short utterances on Apple Silicon.
- **Responsive UI.** No blocking spinners for normal interactions.
- **Modest footprint.** The app should be unobtrusive in RAM and CPU when idle.

### Platform & environment
- **macOS, Apple Silicon first.** Must feel like a native Mac citizen: HIG-aligned visuals, real menu bar integration, vibrancy where appropriate, dark/light mode support.
- **Offline.** All core flows must work with no internet connection, except the initial model download.
- **Autostart.** Users can opt in to launch at login.

### Reliability
- **Global shortcuts must not steal keys they don't own.** Example: the cancel key is only registered during recording.
- **Shortcut conflict handling.** If two commands end up bound to the same accelerator, the app resolves it gracefully rather than silently dropping one.
- **Permission resilience.** Revoking a permission mid-session surfaces a clear recovery path rather than failing silently.

### UX quality bar
- **Native Mac feel.** Typography, spacing, controls, and motion that match a shipping Mac app — not a web app in a wrapper.
- **Discoverability.** Every shipping feature should have an obvious entry point in the UI.
- **Reversible actions.** Destructive actions (delete, reset permissions) confirm first.

---

## Out of Scope (explicit)

These are not requirements and should not be reintroduced without a new intent brief:

- Cloud transcription providers of any kind. (Transcription itself stays on-device; only the optional cleanup and rewrite LLM paths can reach out, and only when the user has explicitly configured a provider.)
- Voice-activity-detection / continuous listening modes.
- Transcription from uploaded audio files.
- Telemetry, usage metrics, or crash reporting.
- Non-macOS platforms.
- Multi-user accounts or sync.

---

## Success Criteria

- A user who installs the app for the first time can record, see their text pasted where they expect it, and understand where each feature lives — within a single setup pass.
- A returning user can rely on the global shortcut from any app, every time, without the app needing to be in the foreground.
- A privacy-sensitive user can verify (with Little Snitch or similar) that no audio or transcript data leaves their Mac.

---

## Frontend Design (current reference)

A snapshot of the visual language shipping today. This is meant as a **reference** for the rewrite — not every detail is load-bearing. Longer form: `docs/plans/ui-rebuild-design.md`.

### Aesthetic direction
- macOS System Settings polish — quiet, minimal, native. The UI should disappear into the act of dictation.
- No brand palette — the app rides on system semantic colors and vibrancy.
- Calm over attention-seeking. The one place motion is given a real budget is the speak → text success transition.

### Layout
- Sidebar + content shell on a single main window. The sidebar carries a small wordmark, a source list of sections (Home, Library, Settings with grouped children, Help), and a status zone at the bottom (current model + last transcription state).
- Settings is a section of the main window — not a separate scene. `⌘,` opens the main window directly on Settings; closing either entry point hides to the tray.
- Setup wizard lives in its own small, centered window with a horizontal slide between steps.
- Transparent / inset title bar where applicable so sidebar vibrancy extends into the chrome.

### Color & appearance
- Respects `prefers-color-scheme` (light and dark). Dark mode was designed first; light mode mirrors it.
- Accent is System Blue. Semantic reds, greens, oranges for destructive/success/warning.
- Grouped panels use the macOS "grouped background" pattern (lighter than window in light mode, darker in dark).
- Hairlines, not shadows. Shadows are reserved for floating surfaces (status indicator, popovers).

### Typography
- System font stack (SF Pro on Mac). Monospace (SF Mono) for transcripts, timestamps, keybind chips.
- Hierarchy: display (wizard titles) → page title → section label → body → secondary → caption. Weight used sparingly — semibold for titles, regular for body.

### Spacing & radius
- 4 px spacing unit. Common scale: 4 / 8 / 12 / 16 / 20 / 24 / 32.
- 6 px radius for controls, 10 px for cards and grouped boxes, pill for toggles and the recording button.

### Controls
- Buttons: primary / secondary / ghost / destructive / toolbar variants, three sizes. Subtle press animation (brief 98% scale).
- Toggles: iOS-style pill switches.
- Inputs: 28 px tall, thin border, focus replaces border with a 2 px accent (Mac pattern — not an outer halo).
- Selects: native where possible; the custom styled selects mimic the Mac "popup button" look.
- GroupBox: rounded panel, rows separated by inset hairlines — matches System Settings.

### Surfaces & elevation
- Window uses vibrancy for the sidebar.
- Grouped boxes are flat; separation comes from background contrast, not shadow.
- Only floating elements (status indicator, popovers) carry shadows, plus a hairline stroke to keep edges crisp.

### Motion
- Short and decisive. 80 ms for hover/press, ~140 ms for state changes, ~200 ms for view transitions, ~320 ms reserved for the success moment.
- Respects reduced motion — animations collapse to zero and pulses become static.

### Status indicator (current look)
- Single pill-style overlay anchored near the top of the primary display.
- Recording: red dot with a breathing pulse, static equalizer bars, elapsed-time counter.
- Transcribing: blue dot with a three-dot loader.
- Success: green dot with a short transcript preview and a copy glyph.
- Error: red dot with a short message and a hover info icon.
- Click-through during recording/transcribing; becomes interactive for the copy/info affordances during success/error.
- **Direction for the rewrite:** replace this with a Dynamic Island-style presentation anchored below the notch (see Status indicator requirement above). The current look is the starting point, not the destination.

### Tray menu
- Native menu. Short and functional: toggle recording (dynamic label), copy last transcription, show window, settings, quit.

### Wizard
- Minimal shell — no sidebar or nav chrome. Header + step content + footer with Back / Skip / Primary action and a horizontal step indicator.

### Iconography
- Line icons at ~16 px in navigation, larger in context. On the rewrite, prefer SF Symbols — they ship native weights and optical sizes and match the system.

### Recording button (Home)
- Large circular button, ~88 px. Idle, hover, active, recording (filled red with outer-ring pulse), transcribing (accent with dot loader), disabled.

### Explicit design rules
- No gradients.
- macOS HIG alignment — native controls, native menus, native vibrancy.
- Dark mode is the design canvas; light mode must mirror.
- No hedging spinners — state is communicated with named colors and small animated glyphs.
- Each surface has one purpose: main window (with sidebar navigation into Home / Library / Settings / Help), setup wizard, status indicator, tray.

### Rewrite-time notes
- Sidebar + content, grouped-box settings, and light/dark semantic tokens all map cleanly to native Mac UI frameworks (SwiftUI `Form`/`Section`, `NSSplitViewController`, system colors, `NSVisualEffectView` sidebar material). Keep them.
- Tray should be a real `NSStatusItem` with an `NSMenu`. No WebView.
- The status indicator should be a native window (e.g., `NSPanel` with `screenSaver` level and `ignoresMouseEvents` toggled per state) so the Dynamic Island-style presentation can be painted with native layers rather than a transparent WebView.
- Replace Lucide with SF Symbols.
- Waveform, equalizer, and success-reveal animations are small enough to redraw natively (Core Animation / SwiftUI Canvas) — no need to port the current DOM implementations.
