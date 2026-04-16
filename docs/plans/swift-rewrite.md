# Jot — Swift Rewrite Plan

## Goal

Ship a native macOS dictation utility: press a hotkey, speak, text pastes at the cursor. On-device transcription via Parakeet on the Apple Neural Engine. Feels like a real Mac utility.

Sources of truth for **what** to build:
- `../design-requirements.md`
- `../features.md`

This plan answers **how**: architecture, key library choices, pre-flight spikes, build order, release bar.

---

## Key Decisions

| Layer | Choice |
|---|---|
| App framework | SwiftUI + AppKit interop — SwiftUI for main UI, AppKit for `NSStatusItem` and `NSPanel` |
| Platform | **Apple Silicon only.** Parakeet on the Neural Engine is an Apple Silicon feature; Intel Macs are out of scope. |
| Minimum macOS | Sonoma 14.0 (required by FluidAudio and the ANE Parakeet runtime) |
| Transcription | FluidAudio + Parakeet TDT 0.6 B **v3** on the Apple Neural Engine |
| Audio capture | `AVAudioEngine` + `AVAudioConverter` to 16 kHz mono Float32 |
| Global hotkeys | `sindresorhus/KeyboardShortcuts` Swift Package |
| Persistence | SwiftData for recordings; `@AppStorage` / `UserDefaults` for prefs |
| Status indicator | `NSPanel` hosting a SwiftUI view. Dynamic Island-style pill hugging the notch on notch-equipped Macs; centered under the menu bar on non-notch Apple Silicon Macs. Reference aesthetic: the [oto](https://www.tryoto.com) indicator. |
| Menu bar | `NSStatusItem` with a native `NSMenu` |
| Distribution | DMG via GitHub Releases. Manual update-by-redownload in v1. |

---

## Pre-flight Spikes

Three independent unknowns. Each is a half-day spike. Run all three in parallel before committing to the full build — if any fails, swap in the listed fallback and continue.

1. **Delivery matrix.** Does synthetic `⌘V` actually paste reliably into the full range of apps a user types into — AppKit native (Notes, Mail, Safari), Electron (Slack, Discord, VS Code, Notion), Chromium browsers (Chrome, Arc, Brave), Terminal / iTerm, and secure-field-heavy apps (1Password)? This is the highest-risk unknown in the whole plan: if it fails in common apps, the whole value prop suffers.
   - *Fallback:* clipboard-only mode (transcript goes on the clipboard, user pastes manually) + optional AX text-insertion when the focused field supports it.

2. **KeyboardShortcuts dynamic enable/disable.** Does `KeyboardShortcuts.disable()` actually release the OS-level hotkey so `Esc` doesn't get stolen from other apps when we're not recording?
   - *Fallback:* use Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` directly (~50 lines of Swift).

3. **Overlay placement.** Does the indicator `NSPanel` land cleanly below the notch on notch-equipped Macs, center under the menu bar on non-notch Macs, and survive display changes (external monitor plug/unplug, resolution changes, Retina vs non-Retina)? `NSScreen.safeAreaInsets` reports the notch geometry — verify it's stable across hot-plug events.
   - *Fallback:* anchor to menu-bar center with a fixed offset; skip notch-hugging on non-trivial multi-display setups for v1.

**Not a spike anymore:** FluidAudio mirror URL. Upstream already supports overriding the model source, so pointing it at our own endpoint is a configuration step, not an unknown.

---

## Architecture

Single Xcode project at repo root. One executable target.

### Layers

- **App** — entry point, scenes, AppDelegate, top-level observable state, permission checks. See *Permissions* below for the four distinct capabilities modern macOS exposes.
- **MenuBar** — `NSStatusItem` owner + native menu. Dynamic "Start / Stop Recording" label driven by recorder state.
- **Overlay** — `NSPanel`-hosted SwiftUI status indicator. Dynamic Island-style presentation anchored below the notch. Click-through by default; becomes interactive for the copy/info affordances during success and error states.
- **Recording** — `AVAudioEngine` tap → converter → in-memory buffer + WAV file on disk. Hotkey routing with dynamic Escape registration (only claimed while recording is active).
- **Transcription** — FluidAudio wrapper (single in-flight), post-processing, model download/load.
- **Delivery** — clipboard sandwich (save → write → synthetic `⌘V` → restore); optional auto-Enter.
- **Library** — SwiftData model, recordings list with search and date grouping, detail view with playback, per-row actions (re-transcribe, reveal, delete, rename).
- **Settings** — SwiftUI `Settings` scene with General / Transcription / Sound / Shortcuts panes. Shortcuts pane is **editable** in v1 using `KeyboardShortcuts.Recorder` — not the read-only view of the current Open Voice build.
- **Setup Wizard** — separate window gated by first-run flag. Welcome → Permissions → Model → Microphone → Shortcuts → Test.
- **Sounds** — bundled chimes with a thin `AVAudioPlayer` wrapper.

### Permissions

Jot touches four distinct macOS privacy capabilities. Each has its own grant flow and failure mode; the app models them separately rather than treating "permissions" as a single boolean.

| Capability | What for | Revocation effect |
|---|---|---|
| **Microphone** | Record audio. | Recording blocked. Prompted once, granted in-process. |
| **Input Monitoring** | Observe global key presses to detect the hotkey. | Hotkeys stop firing. Requires relaunch after grant. |
| **Accessibility — post events** | Synthesize `⌘V` (and optional Enter) into the frontmost app. | Paste fails silently. Requires relaunch after grant. |
| **Accessibility — full AX trust** *(optional polish)* | Insert text directly into the focused field via the AX API when `⌘V` is unreliable. | Falls back to synthetic `⌘V`; not strictly required. |

**Failure-mode behavior:**
- Mic denied → setup wizard parks on the permissions step and re-prompts.
- Input Monitoring denied → hotkeys don't fire; menu bar recording still works; UI guides the user to System Settings and offers a Restart button.
- Post-events denied → **clipboard-only delivery**: transcript goes on the clipboard, toast reads "Copied — paste with ⌘V." No dead-end.
- The existing Open Voice wizard already has a Restart button after the Accessibility grant; Jot mirrors that pattern.

### Data flow on a hotkey press

Hotkey fires → recorder state flips to recording → audio engine taps the mic, converts to 16 kHz mono, accumulates a buffer and writes a WAV file → on stop, buffer is handed to Parakeet → transcript runs through post-processing → clipboard sandwich pastes at the cursor → SwiftData row saved → status indicator plays the success state → idle.

No IPC. No serialization. Each step is a Swift function call.

---

## Phased Build

Five phases. Pre-flight spikes run alongside Phase 1.

1. **Skeleton + bootstrap** — Xcode project, `@main` app, AppDelegate, empty Settings scene, first-run detection. Permissions service (mic + input-monitoring + accessibility post-events), with the accessibility restart flow baked in (mirrors the current Open Voice wizard pattern). Model-download utility (not the wizard UI yet — a plain function that fetches the Parakeet model into the cache if missing, so the rest of the phases have something to call).
2. **Audio + Transcription** — `AVAudioEngine` capture + converter, FluidAudio wrapper loaded, end-to-end "record 3 seconds → print transcript" working.
3. **Hotkeys + Delivery** — KeyboardShortcuts wired, `Esc` dynamic, clipboard sandwich, synthetic `⌘V`, clipboard-only fallback for denied post-events permission.
4. **UI Surfaces** — menu bar, status indicator, recordings library, settings panes (including the editable shortcuts pane). Parallel-ready once Phase 3 lands.
5. **Setup Wizard UI + Polish** — polished first-run flow wrapped around the Phase 1 bootstrap utility, vibrancy, sound chimes, DMG packaging.

### Critical path
Phase 1 → 2 → 3. Then 4 and 5 run in parallel. Spikes sit alongside Phase 1.

---

## Release Criteria

v1 ships when every item below passes on a real Mac, confirmed by a manual smoke test:

- Hotkey → speak → text pastes at the cursor in the frontmost app. Works from any app, every time.
- Push-to-talk mode works.
- Cancel key is only active while recording.
- Long recordings (> 60 s) transcribe reliably.
- Status indicator cycles correctly through recording / transcribing / success / error, rendered under the notch (or centered under the menu bar on non-notch Macs).
- Shortcuts pane accepts new bindings via `KeyboardShortcuts.Recorder` and persists them.
- All settings persist across restarts.
- Setup wizard runs on first launch and is re-runnable from General.
- Launch-at-login toggle works.
- Recordings library lists, searches, plays back, renames, re-transcribes, and deletes.
- Three consecutive days of daily driving with zero crashes.

---

## Future Plans

Not in v1, but architecture should accommodate them:

- **Custom vocabulary** — user-supplied find/replace pairs applied as post-processing. The `PostProcessing` layer exists precisely so this can be slotted in without reshaping the pipeline.
- **Auto-updates via Sparkle 2** — v1 ships as a manually-updated DMG. Sparkle with EdDSA signing comes in a later version (needs Developer ID + notarized builds + appcast hosting).
- **Scaled transcript search** — SwiftData handles v1's library sizes. If transcript corpora grow large and search gets sluggish, swap to GRDB + SQLite FTS5.
- **Model download robustness** — resumable downloads, checksum verification, cache versioning. A plain `URLSession` download with progress is enough for v1 on modern broadband.

---

## References

- `../design-requirements.md` — product requirements (source of truth)
- `../features.md` — feature parity target
- `../research/parakeet-vs-moonshine.md` — engine selection research
- `../research/parakeet-vs-moonshine-benchmark.md` — benchmark data
