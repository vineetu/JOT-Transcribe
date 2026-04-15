# Open Voice — Swift Rewrite (research / design)

**Status.** v4. Iterated through three design-review rounds. Ready to act on if a Go decision is made.

**One-line goal.** Replace the Tauri 2 + SvelteKit + Rust app with a single-target SwiftUI macOS application that ships native menu-bar UI, runs Parakeet TDT 0.6 B on the Apple Neural Engine via FluidAudio, and feels like a real Mac utility — without surrendering any user-visible behavior the current app provides.

**Cost (honest framing).** The implementer is an AI assistant, not a salaried engineer, so "calendar weeks" isn't the right unit. The real costs are:

- **Your (CEO) time reviewing builds and running smoke tests on the Mac.** Each build → you launch → you report back = one cycle. Realistic: 20–40 cycles to reach the v1 release criteria.
- **Debug cycles when things break in ways I can't see from code.** Prod-only Gatekeeper rejections, SwiftUI view-tree quirks, hotkey conflicts with other apps — these all require you to paste an error or screenshot because I can't observe them. Budget 5–10 such loops on top of the nominal cycles.
- **Decisions.** The doc has open questions (custom vocab in scope? PTT exposed?). Each one is a 30-second answer from you.
- **My per-task cost.** Writing ~12k lines of Swift across an Xcode project is hours of my wall-time, not weeks. But that time only matters if it's interleaved with your review — I don't dump 12k lines at once and hope it works.

Realistic elapsed-time expectation, gated by your review bandwidth: **a few days if you're tightly available, a couple of weeks if we're doing a cycle or two a day, a month or more if the cadence slows.** The schedule is set by how often you can launch the build and report back.

**Alternative.** Option A in `transcription-option-a-rust-cpu.md` — Parakeet on CPU via the existing Tauri/Rust stack, 3–5 days, gets you the quality win immediately. Treat the rewrite as the optional follow-up after living with Option A for a couple of weeks of daily dictation.

---

## 1. Why rewrite at all

The current app works. The UI rebuild just landed. So: why throw away weeks of code?

The honest answer is that the current architecture is paying a tax for shape it doesn't need.

- **Three languages** (Rust + TypeScript + soon Swift if we go with Option B sidecar) for a single-user single-platform local utility.
- **Yjs CRDTs + IndexedDB workspace** designed for multi-user sync — used here for one user storing recordings on one Mac. Pure incidental complexity.
- **Tauri WebView** can't naturally produce the Mac-native feel the intent brief asks for ("feels like a commercial Mac app, not a side project"). Vibrancy works, but the WebView gives the whole window a slightly-off character: text rendering, focus rings, scroll inertia, context menus, even how `Cmd-Q` propagates.
- **The fastest transcription path** (FluidAudio + Parakeet on ANE, ~171 ms for 25 s of audio, 66 MB resident — measured on this Mac in `docs/research/parakeet-vs-moonshine-benchmark.md`) is naturally Swift. Everything else is plumbing around it.
- **System APIs we need** (global hotkeys, accessibility, vibrancy, NSPanel overlays, SwiftData persistence, SwiftUI settings, `MLModelConfiguration.computeUnits`) are all first-class in Swift and second-class through Tauri plugins.

A Swift rewrite isn't about being purer; it's about removing layers between the user and the silicon. Specifically, the intent brief's "60-second 'this is a real app' moment" is achievable in SwiftUI in ways it can't be in a WebView wrapper.

**And Swift is, frankly, the best language for a native Mac app.** Apple's frameworks are designed for it; the platform's APIs ship with Swift signatures first; AppKit/SwiftUI/CoreML/AVFoundation/MLPackage all assume you're calling them from Swift. Going through Rust + Tauri to reach those APIs is paying tax we have no reason to pay for a single-platform single-user utility. The current architecture made sense when the upstream Whispering project was cross-platform and multi-user; it doesn't for what Open Voice actually is.

The cost is real (6–10 weeks of focused work to reach feature parity with what ships today, factoring in the Swift learning curve) and is acknowledged in §13.

---

## 2. What we're replacing — feature inventory (anchored to current app)

The companion feature-inventory note (Agent-generated, pasted into `docs/research/current-feature-inventory.md` if we want it standalone — for now embedded as the source of truth for this plan) catalogs everything the existing app does. The high-level surface to preserve:

- **Press hotkey, speak, text appears at cursor.** Default `Option+Space` toggle; `Control+Shift+V` paste-last; `Escape` cancel (only registered while recording — a critical detail).
- **Menu-bar dropdown** (Start/Stop, Audio Input submenu, Copy Last Transcription, Show Window, Settings…, Quit).
- **Tray icon state changes** (idle / recording / transcribing / error).
- **Floating status indicator** (240×36 pill at top-center, four states, signature character-reveal animation on success).
- **Main window** with Home (last transcription preview + record button), Recordings library (search, play, delete, re-transcribe, edit title), Settings.
- **Setup wizard** (welcome → microphone permission → accessibility permission → shortcut config → model download → test).
- **Hide-to-tray on close**, real Cmd+Q quit, single-instance, vibrancy sidebar, follow-system dark/light.
- **Sound effects** for start/stop/cancel/transcribe-complete/error.
- **Clipboard sandwich** for paste-at-cursor with original-clipboard restoration.
- **Custom-vocabulary post-processing** (planned, currently tabled — same find/replace approach inherits to Swift).

Hidden-but-preserved features (cloud providers, VAD, file upload, transformations) per the intent brief: not in scope for the rewrite, but data structures must support adding them back.

---

## 3. Target architecture

### 3.1 Stack

| Layer | Choice | Why |
|---|---|---|
| App framework | **SwiftUI + AppKit interop** | SwiftUI for the main window, settings, setup wizard, recordings list. AppKit (`NSStatusItem`, `NSPanel`) for menu bar and floating overlay where SwiftUI doesn't reach. macOS 14+ supports `MenuBarExtra` natively but its window-style limitations push us to a hybrid for the overlay. |
| Minimum macOS | **14.0 (Sonoma)** | FluidAudio requires 14+; SwiftUI `MenuBarExtra` is mature on 14+; this is also what Parakeet-on-ANE needs anyway. The current app's `minimumSystemVersion: "10.15"` is broader than the user actually uses. |
| Transcription | **FluidAudio + Parakeet TDT 0.6B v2** on ANE | Measured 171 ms / 25 s, 66 MB resident, near-zero CPU. v2 is English-optimized; v3 is multilingual but loses English recall. v2 default. |
| Audio capture | **AVAudioEngine + AVAudioConverter** | Tap mic input, convert to 16 kHz mono Float32 in-memory buffers, hand directly to FluidAudio. No WAV file round-trip required for transcription, though we still write a WAV to disk for the recordings library. |
| Global hotkeys | **`sindresorhus/KeyboardShortcuts`** (Swift Package) | Has separate `onKeyDown` and `onKeyUp` callbacks (push-to-talk works). User-customizable UI via `KeyboardShortcuts.Recorder`. macOS 10.15+. Storage is `UserDefaults` automatic. |
| Persistence | **SwiftData** for recordings library + **`@AppStorage` / `UserDefaults`** for preferences | SwiftData is the greenfield-recommended path on macOS 14+. Single-user, single-machine = no need for CRDTs. SwiftData rows reference the WAV files on disk by URL. |
| Floating overlay | **`NSPanel` hosting a SwiftUI view** | Always-on-top, click-through, no shadow, transparent, key-window selectable. SwiftUI doesn't expose enough to do this without the AppKit hatch. |
| Auto-updates | **Sparkle 2 with EdDSA** | If we have an Apple Developer ID for code signing. Without one, manual GitHub-Release download. |
| Distribution | **DMG via GitHub Releases**; optional `brew install --cask` later | Same model the current app implies. Code-sign + notarize if Developer ID; otherwise ad-hoc + xattr-d quarantine on user's side (matches what we do today). |
| Build | **Standalone Xcode project** at repo root, sibling to the existing `src-tauri/` etc. for clean cutover | Single executable target, no SPM-only build (Sparkle resource bundle prefers Xcode). |

### 3.2 Module layout

```
swift/
├── OpenVoice.xcodeproj
├── OpenVoice/
│   ├── App/
│   │   ├── OpenVoiceApp.swift         // @main, scenes, AppDelegate
│   │   ├── AppModel.swift             // top-level observable state (recorder state, current recording, etc.)
│   │   └── Permissions.swift          // mic + accessibility checks/requests
│   ├── MenuBar/
│   │   ├── StatusItemController.swift // NSStatusItem owner + icon swapping per state
│   │   └── MenuBarMenu.swift          // SwiftUI Menu in MenuBarExtra
│   ├── Overlay/
│   │   ├── StatusIndicatorPanel.swift // NSPanel subclass, floating, click-through
│   │   └── StatusIndicatorView.swift  // SwiftUI: dot + text + animations per state
│   ├── Recording/
│   │   ├── AudioRecorder.swift        // AVAudioEngine tap → 16kHz mono Float32 buffer + WAV file
│   │   ├── HotkeyRouter.swift         // KeyboardShortcuts wiring; dynamic Escape-during-recording
│   │   └── RecorderState.swift        // idle / recording / transcribing / error enum + observable
│   ├── Transcription/
│   │   ├── ParakeetEngine.swift       // FluidAudio AsrManager wrapper, single in-flight, model loading
│   │   ├── PostProcessing.swift       // custom-vocab find/replace
│   │   └── ModelDownload.swift        // first-run model fetch, mirrored from our endpoint
│   ├── Delivery/
│   │   ├── ClipboardSandwich.swift    // save → write new → CGEvent paste → restore
│   │   └── EnterKey.swift             // optional auto-Enter
│   ├── Library/
│   │   ├── Recording.swift            // SwiftData model
│   │   ├── RecordingsList.swift       // SwiftUI list view, search, group-by-date
│   │   ├── RecordingDetail.swift      // SwiftUI detail with playback
│   │   └── RecordingActions.swift     // re-transcribe, delete, copy
│   ├── Settings/
│   │   ├── SettingsScene.swift        // SwiftUI Settings(){…} root
│   │   ├── GeneralPane.swift
│   │   ├── ShortcutsPane.swift
│   │   ├── SoundPane.swift
│   │   └── TranscriptionPane.swift    // model selector if we ever expose multiple
│   ├── Setup/
│   │   ├── SetupWindow.swift          // separate window, gated by first-run flag
│   │   └── Steps/Welcome|Microphone|Permissions|Shortcuts|Model|Test.swift
│   └── Sounds/
│       ├── SoundPlayer.swift
│       └── Resources/start.aiff … etc.
├── Tests/
└── Resources/
    ├── Assets.xcassets               // app icon, status item icons (template images, 22pt)
    └── Info.plist
```

### 3.3 Data flow on a hotkey press

1. `KeyboardShortcuts.onKeyDown(.toggle)` fires on the main thread.
2. `RecorderState` checks current state. If idle → `AudioRecorder.start()`; if recording → `AudioRecorder.stop()` + transcription pipeline.
3. `AudioRecorder.start()` instantiates `AVAudioEngine`, attaches a tap to `inputNode`, configures an `AVAudioConverter` to 16 kHz mono Float32, accumulates buffers in memory and simultaneously writes a WAV file to `~/Library/Application Support/com.openvoice.app/recordings/{uuid}.wav`. Updates `RecorderState` → `.recording`. Registers Escape via `HotkeyRouter.registerCancel()`.
4. `AudioRecorder.stop()` flushes the WAV file, returns the in-memory `[Float]` buffer + the file URL. Updates `RecorderState` → `.transcribing`.
5. `ParakeetEngine.transcribe(samples:)` calls `AsrManager.transcribe(samples)` (the FluidAudio API). Returns `String`.
6. `PostProcessing.apply(text:)` runs find/replace.
7. `ClipboardSandwich.deliver(text:)` saves the user's clipboard, writes the transcript, simulates Cmd+V, waits 100 ms, restores the original clipboard. Optionally simulates Enter.
8. `Recording` row written to SwiftData with the WAV URL, transcript, timestamp, duration. UI updates via `@Query`.
9. `RecorderState` → `.idle`. Status indicator shows "success" with character-reveal of the first 32 chars, auto-dismisses after 2.4 s.
10. `HotkeyRouter.unregisterCancel()`.

All of this runs without IPC, JSON serialization, or process boundaries. Each step is a Swift function call.

---

## 4. Specific decisions worth pinning

### 4.1 Audio path

`AVAudioEngine` mic input runs at the device's native format (built-in mic on Apple Silicon is typically 48 kHz Float32; USB interfaces often 44.1 kHz, 48 kHz, or 96 kHz; AirPods report 16 kHz). We attach a tap at the device's native format, wrap each buffer in an `AVAudioConverter` to 16 kHz mono Float32, and push converted frames to two destinations in parallel:
- An in-memory `[Float]` accumulator for direct hand-off to FluidAudio.
- A WAV writer (`AVAudioFile` with the converted format) for the recordings library.

The current Rust app writes a WAV first then re-reads it for transcription — a round trip we don't need in Swift. Saves disk I/O on the latency-critical path.

If FluidAudio supports streaming (it does, per their docs), we can later replace the "stop → transcribe whole buffer" pattern with progressive transcription during recording. v1 ships the simpler stop-then-transcribe path.

### 4.2 Transcription engine

FluidAudio v0.12.4+ via `AsrModels.downloadAndLoad(version: .v2)` + `AsrManager(config: .default).transcribe(samples)`. Verified working on this Mac in the bench harness at `/tmp/ov-swift-bench/`. v2 = English-only, higher recall on English than v3. v3 = 25 languages, lower English accuracy.

We pick **v2** as the only shipped variant for now. Settings doesn't expose a picker. If multilingual turns out to matter, add a Settings toggle and download v3 alongside.

### 4.3 Model download

FluidAudio's default fetch is direct from Hugging Face on first use. We do not want a surprise network call after setup completes (intent brief: no cloud calls for core functionality).

**Decision:** mirror the Parakeet CoreML `.mlpackage` on our own release endpoint and download during the setup wizard. Source-of-truth is our mirror, not Hugging Face, so the user only ever fetches from a URL we control.

**How we route through FluidAudio:** Step 0 verifies whether FluidAudio's `AsrModels.downloadAndLoad` accepts a custom URL. If yes, pass our mirror URL. If no, vendor FluidAudio (Apache-licensed, well-scoped) and patch one line in the download path — manual quarterly review for upstream updates is acceptable for a library this small.

This is **the same model under both bundling and download-on-first-run** — see §4.11 for the bundling-vs-download decision; §4.3 only covers where the bytes come from.

Cache location: `~/Library/Application Support/com.openvoice.app/parakeet-coreml/`. FluidAudio defaults to `~/Documents/FluidAudio/` which is wrong for a non-user-facing cache; we override the path at startup or symlink.

### 4.4 Hotkeys + the Escape-only-while-recording rule

`KeyboardShortcuts` registers shortcuts in `UserDefaults` automatically, but the actual OS-level binding is established when a callback is registered via `onKeyDown(for:)`. The library's `disable(_:)` and `reset(_:)` APIs control whether the binding is currently active. To keep Escape from being stolen from other apps:

- Define the cancel shortcut name (`KeyboardShortcuts.Name("cancelRecording", default: .init(.escape))`).
- At app start, immediately call `KeyboardShortcuts.disable(.cancelRecording)` so the binding is registered with UserDefaults but inactive.
- In `AudioRecorder.start()`, call `KeyboardShortcuts.enable(.cancelRecording)` along with a one-time `onKeyDown(for: .cancelRecording) { cancel() }` callback registration (idempotent).
- In `AudioRecorder.stop()` and `cancel()`, call `KeyboardShortcuts.disable(.cancelRecording)`.

This mirrors the current app's behavior. The pattern needs to be verified against the live API in step 0 of §5 — if `disable` doesn't actually release the OS-level grab, fall back to a hand-rolled `RegisterEventHotKey`/`UnregisterEventHotKey` pair via Carbon (well-trodden path; ~50 lines of Swift).

### 4.5 Status indicator overlay

`NSPanel` subclass with:
- `level = .floating` (or `.statusBar` if `.floating` is intercepted by full-screen apps; verify)
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`
- `styleMask = [.borderless, .nonactivatingPanel]`
- `isFloatingPanel = true`
- `ignoresMouseEvents = true` by default; flipped to `false` only when state is `.success` (for the tappable copy icon) or `.error` (for the (i) tooltip)
- SwiftUI content via `NSHostingView`, positioned on screen with `setFrame(NSRect, display: true)` at top-center of `NSScreen.main!.visibleFrame`

State-specific animations (pulse, breathe, character reveal) implemented in SwiftUI with `withAnimation` and timing functions from the existing `ui-rebuild-design.md`.

### 4.6 Persistence

**SwiftData `@Model class Recording`** — schema reconciled against the current Yjs schema in `src/lib/workspace/definition.ts`:

```
id: UUID                       // primary key                          (Yjs: id)
title: String                  // user-editable                         (Yjs: title)
subtitle: String               // freeform notes / second line          (Yjs: subtitle)
transcript: String             // post-processed final text             (Yjs: transcribedText)
rawTranscript: String          // pre-post-processing (for re-running)  (NEW — needed for custom-vocab re-runs)
audioURL: URL                  // points to recordings/{uuid}.wav       (NEW — Yjs only stored id, file location was implicit)
timestamp: Date                // when recorded                         (Yjs: timestamp)
createdAt: Date                // record creation                       (Yjs: createdAt)
updatedAt: Date                // last edit                             (Yjs: updatedAt)
durationSeconds: Double                                                 (NEW — read from WAV header on import)
transcriptionStatus: String    // done/failed/transcribing/pending      (Yjs: transcriptionStatus)
engineUsed: String             // "parakeet-v2"                         (NEW — for future engine swaps)
sourceTag: String?             // "manual" / "vad" / "upload"           (NEW — preserves hidden-feature schema)
errorMessage: String?          // populated when status == "failed"     (NEW)
```

Schema preserves every Yjs field that's in active use, plus adds five fields needed by the rewrite (rawTranscript for re-runnable post-processing, audioURL because SwiftData needs an explicit URL ref, durationSeconds for list display without re-reading the WAV, engineUsed/errorMessage/sourceTag for future evolution). The Yjs `_v` versioning column is dropped — SwiftData handles schema migration via its own mechanism.

**WAV files** at `~/Library/Application Support/com.openvoice.app/recordings/{uuid}.wav`. SwiftData row holds the URL; we don't move blobs into the database.

**Preferences** via `@AppStorage` (UserDefaults under the hood) for sound toggles, autostart, output preferences (clipboard, cursor, enter). `KeyboardShortcuts` handles its own UserDefaults storage. Custom-vocab pairs stored in UserDefaults as a JSON-encoded array.

**Setup wizard completion flag** is a UserDefaults boolean. SwiftData container creation happens at app launch regardless; setup gate is a window-level decision.

### 4.6a Migration from the current Tauri app

Single-user app, single Mac. There are real recordings on disk today (`~/Library/Application Support/com.openvoice.app/recordings/` — currently 362 WAV files plus 362 sidecar `.md` metadata files). Three options:

- **(a) Clean slate.** Delete the directory, start fresh. Acceptable if you don't care about the existing recordings.
- **(b) Manual archive.** Before cutover, `cp -r ~/Library/Application\ Support/com.openvoice.app/recordings ~/Documents/openvoice-backup-$(date +%s)`. Lets you keep the WAVs around even if the new library is empty. ~700 MB.
- **(c) Import script.** Write a one-shot Swift CLI that walks the existing `recordings/` directory, parses each `.md`'s YAML frontmatter (id, title, timestamp, transcript, status), and inserts a `Recording` row into the new SwiftData store pointing at the existing WAV. ~half day of work, preserves the library.

**Recommended:** (c) for first launch (low cost, no data loss), with (b) as a one-line note in the setup wizard's first step ("we recommend backing up your recordings folder before cutover, just in case"). The import is idempotent and bails out if the SwiftData store is already populated.

Cutover sequence:

1. Stop the current Tauri app, drag to Trash.
2. (Optional but recommended) Run the backup `cp` command above.
3. Install the new Swift `.app`. On first launch it detects the existing `recordings/` directory and offers to import.
4. Re-grant Microphone + Accessibility permissions in System Settings if the OS doesn't carry them over (bundle ID stays `com.openvoice.app`, so they should).
5. Re-set hotkeys if needed — `KeyboardShortcuts` uses its own UserDefaults namespace and won't see the Tauri app's localStorage.

### 4.7 Hide-to-tray + Cmd+Q

`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false` (menu-bar utilities don't quit on last window closing). `applicationShouldTerminate` returns `.terminateNow` so Cmd+Q from the app menu actually quits. Tray "Quit" calls `NSApp.terminate(nil)`.

This is dramatically simpler than the Rust IS_QUITTING flag dance — Swift's NSApplicationDelegate hooks distinguish "window closed" from "quit requested" natively.

### 4.8 Vibrancy

`NSVisualEffectView` with `.material = .sidebar`, `.blendingMode = .behindWindow`, `.state = .followsWindowActiveState`. Embed inside SwiftUI via a small `NSViewRepresentable` wrapper. Native, no third-party crate.

### 4.9 Dark/light mode

Native — SwiftUI follows `NSApp.effectiveAppearance` automatically. No `mode-watcher` library, no boot script in HTML.

### 4.10 Sounds

`AVAudioPlayer` for short asset playback. Bundle the same `.aiff`/`.wav` files from the current app under Resources. Per-event toggles map to `@AppStorage` keys.

### 4.11 Distribution + signing

**Planned:** ship ad-hoc signed, model downloaded on first run. User explicitly confirmed ad-hoc signing is acceptable for personal distribution. User installs from GitHub Releases DMG and clears quarantine with `xattr -dr com.apple.quarantine /Applications/Open\ Voice.app` (one-time after each install).

**Why downloaded-on-first-run rather than bundled.** §5 Step 0 verifies whether Sequoia accepts ad-hoc signatures on bundles containing CoreML models. Even if that passes, downloading is the safer default because (a) we already planned to mirror the model on our release endpoint per §4.3, (b) it keeps the DMG small (~10 MB) instead of large (~610 MB), and (c) it sidesteps a class of model-bundle Gatekeeper edge cases. Cost: the wizard's "downloading model" step is mandatory on first launch — same UX the current app already has.

If broader distribution ever matters, add Apple Developer ID ($99/year, ~1 day pipeline setup) + Sparkle 2 with EdDSA for auto-updates. Non-breaking change to the app itself.

---

## 5. The path to feature parity

Estimates are ranges with the high end as the realistic-after-surprises number.

0. **Validation gate (do before any other work).** Three binary checks. The whole rewrite hangs on these. [~1 day budgeted; +3–5 days if any fails]

   | Check | Pass | Fail | Fail cost | Go / no-go |
   |---|---|---|---|---|
   | FluidAudio URL override (does `AsrModels.downloadAndLoad` accept a custom URL or base-URL?) | use it | vendor the FluidAudio source, patch one URL line, own quarterly updates | +2–3 days | go either way |
   | `KeyboardShortcuts.disable()` actually releases the OS-level grab (test by binding Escape, calling `disable`, confirming Escape works in TextEdit) | use it | hand-roll `RegisterEventHotKey`/`UnregisterEventHotKey` (~50 lines Carbon) | +1–2 days | go either way |
   | Ad-hoc signed Swift binary with bundled CoreML `.mlpackage` launches on macOS Sequoia after `xattr -dr com.apple.quarantine` | bundle the model | don't bundle — download on first run instead (we're already mirroring it; just gates wizard on download) | +0 days (free) | go |

   **Go decision:** all three checks resolve to a path forward. Two of three are guaranteed go; the only no-go scenario is if FluidAudio (Apache-licensed, well-scoped) can neither be invoked with a custom URL nor practically vendored — extremely unlikely.
1. **Skeleton.** Xcode project, basic `App` + `Settings` scene, status item via `NSStatusItem` (chosen over `MenuBarExtra` so we can do tray-icon animation in step 4). AppDelegate hooks for `applicationShouldTerminateAfterLastWindowClosed = false`. Window appears + closes. [~1 day]
2. **Audio capture + transcription core.** `AVAudioEngine` tap with input-device-native format, `AVAudioConverter` to 16 kHz mono Float32, `AVAudioFile` writer, FluidAudio model download + cache + transcribe call. Debug button to record 10 s and log transcript. Verify on built-in mic AND a USB mic at a different sample rate. [~3–4 days]
3. **Hotkeys + delivery.** `KeyboardShortcuts` for toggle + paste-last + (optional) push-to-talk; dynamic Escape per §4.4; CGEvent-based clipboard sandwich; optional auto-Enter. End-to-end "press Option+Space, speak, text appears in active app" works. [~2 days]
4. **Tray icon states.** `NSStatusItem` icon swaps for idle / recording / transcribing / error. Tray menu with the six items (Toggle, Audio Input submenu, Copy Last, Show Window, Settings, Quit). Audio Input submenu populated from `AVCaptureDevice.DiscoverySession`; selection persists to `@AppStorage`. [~2 days]
5. **Status indicator overlay.** `NSPanel` + SwiftUI view with the four states and animations. Position at top-center; toggles `ignoresMouseEvents` based on state. [~2 days]
6. **Recordings library.** SwiftData model with the full schema (see §4.6), `@Query`-driven list view with date grouping, detail view with `AVAudioPlayer` playback, search, edit-title, delete, re-transcribe. [~3–4 days]
7. **Setup wizard.** Six steps as separate SwiftUI views in a single window (Welcome → Microphone permission → Accessibility permission → Shortcuts → Model download → Test). First-run gate via UserDefaults. Each step is conditional progression. [~3–4 days]
8. **Settings panes.** General (audio device, output preferences), Shortcuts (`KeyboardShortcuts.Recorder` widgets), Sound (toggles), Transcription (engine info + custom vocab list). [~2–3 days]
9. **Custom-vocab post-processing.** Find/replace pipeline + Settings UI for adding pairs. [~1 day]
10. **Sounds.** Bundle assets, `AVAudioPlayer`, per-event toggles wired to settings. [~0.5 day]
11. **System polish.** Vibrancy in main window via `NSVisualEffectView`, follow-system dark/light (free), hide-to-tray semantics, Cmd+Q via `applicationShouldTerminate`, single-instance via `NSWorkspace.runningApplications` check + bring-to-front, autostart toggle (LaunchAgent plist), app icon. [~3 days]
12. **End-to-end QA + cutover.** Run through the v1 release checklist below; fix what breaks; replace the current `/Applications/Open Voice.app` with the Swift build. [~2 days]

### v1 release criteria (the finish line)

The Swift app ships when **all** of these hold on this Mac:

- All steps 1–11 are complete.
- The smoke-test checklist passes:
  1. Press Option+Space → speak "hello world" → text appears in active app within 500 ms of release.
  2. Long recording (>60 s) → transcription completes; status indicator shows elapsed-time progress past 3 s.
  3. Press Escape during recording → recording cancelled, no transcript; Escape works normally in other apps when no recording is in progress.
  4. Open Settings → change a sound-toggle → quit app → relaunch → setting persists.
  5. Cmd+Q from anywhere → app actually quits (doesn't hide-to-tray).
  6. Close the main window with the red close button → window hides, tray icon stays, hotkey still works.
  7. Tray menu has the six items, "Toggle Recording" label flips during a recording, Audio Input submenu lists detected devices.
  8. Recordings library shows new recordings with title, transcript, timestamp, playable audio. Search filters. Delete works.
  9. Setup wizard runs on a fresh `~/Library/Application Support/com.openvoice.app/` directory and lands on a working app at the end.
- Three days of daily driving with no crash.
- Recordings imported from the Tauri app are visible and playable in the Swift app's library (or the user has explicitly opted for clean-slate per §4.6a).

**"Calendar" doesn't apply.** The per-step estimates above are in "developer-days" out of habit. Translate to what matters:

- **Per-step review cycles with you.** Step 2 (audio capture) is 2–4 cycles (build, try on built-in mic, try on USB mic, fix edge cases). Step 7 (setup wizard) is 4–6 cycles (one per wizard step, plus layout feedback). Step 11 (system polish) is the longest — each of vibrancy/hide-to-tray/Cmd+Q/single-instance/autostart is its own cycle.
- **Total cycles to v1:** realistic 40–60.
- **Total wall-time:** bounded by your availability, not mine. If we run 5 cycles a day, this is about two weeks. If we run one cycle a day, it's a month and a half.

**Critical path** (the chain of steps where a slip in one slips the whole project):

```
Step 0 ─► Step 1 ─► Step 2 ─► Step 3 ─► Step 7 (setup wizard depends on model loading via Step 2)
                       │                  │
                       └─► Step 4 ───────►│
                       └─► Step 5 ───────►│
                       └─► Step 6 ───────►│
```

Steps 4 (tray icon), 5 (overlay), 6 (recordings library) can each start once Step 2 lands and proceed in parallel if multiple sessions can run, otherwise in any order. Steps 8–11 are independent of 4–6 and can interleave. Step 12 (cutover) blocks on everything.

If that's too long, the alternative is Option A (Parakeet on Rust/CPU, 3–5 days) which gets you Parakeet quality immediately. After 2 weeks of daily-driving Option A, you make a more informed call: if Parakeet-on-CPU feels good enough, the rewrite is optional. If the latency, memory, or "this still feels webby" feedback is loud, the rewrite is justified. Option A is therefore not just a stepping-stone — it's a natural decision point where the rewrite can be cancelled with no waste.

---

## 6. What we lose vs. the current Tauri app

**Cross-platform.** The Tauri app technically builds for Windows and Linux. The Swift app is macOS-only. The intent brief explicitly says Mac-only is the priority, so this is not actually a loss of intended capability.

**Yjs CRDT replication.** If we ever add device-to-device sync, we'd need to redesign storage. SwiftData has CloudKit-backed sync built in, which probably covers the realistic future use case better than Yjs anyway.

**Hot reload during development.** SwiftUI previews exist but they're nowhere near as fluid as Vite HMR. Realistic dev loop is "Cmd+R, wait 1–2 s for app re-launch". Annoying for UI iteration; fine for everything else.

**The investment in the Svelte components.** Real sunk cost. Acknowledged.

---

## 7. What we gain

- ~4× faster transcription (171 ms vs 667 ms on 25 s audio, measured)
- ~10× lower memory (66 MB vs ~700 MB)
- Near-zero CPU during inference (huge for battery)
- Native everything — vibrancy, controls, scrolling, focus rings, keyboard nav
- One language (~12k LOC down from ~15k LOC across three languages)
- Bundle ~10–20 MB instead of ~50 MB
- Real Mac code-signing flow if/when we want it

---

## 8. Open questions (real unknowns)

These resolve in Step 0 (validation gate) or Step 2 (audio core):

- **FluidAudio's `AsrModels.downloadAndLoad` URL override.** Determines whether mirroring is a setting or a fork. Step 0.
- **`KeyboardShortcuts.disable()` actually releases the OS grab.** If not, fall back to Carbon `RegisterEventHotKey` (mature, well-documented). Step 0.
- **Cold CoreML compile on a clean machine.** Bench measured 28 s on this Mac with cache. On a fresh macOS 14.0 install it could be 60–120 s. Setup wizard step shows progress; verify the time fits the wizard's flow. Step 2.
- **macOS 14.0 vs 14.x.** FluidAudio likely needs Swift 5.10 runtime; 14.0 may ship 5.9. Step 0 — if 14.0 doesn't work, bump minimum to 14.4 or vendor an older FluidAudio.
- **Ad-hoc signed Swift binary launches under post-Sequoia Gatekeeper.** Step 0.

These resolve later or are punted:

- **NSPanel screen-share exclusion.** Mark `sharingType = .none` so the overlay doesn't show up in screen recordings. Default off (preserve current behaviour where the indicator IS visible in recordings); add a Setting if anyone asks.
- **Live captions during recording.** FluidAudio supports streaming. Compelling — partial text appears in the status indicator as you speak. Doubles the indicator complexity. v2.
- **Apple CloudKit sync via SwiftData.** Easy to add later for cross-device recordings library; out of scope for v1.

## 8a. Test plan

Honest answer: **manual smoke tests for v1, automated tests added incrementally**.

What's testable in XCTest from day 1:
- `PostProcessing` find/replace pipeline (pure function over `String`).
- `AudioRecorder` state-machine transitions (mock the AVAudioEngine).
- `RecorderState` invariants (can't enter `.transcribing` from `.idle`).
- `ClipboardSandwich.deliver` against a mock pasteboard.
- SwiftData model schema (Round-trip a `Recording`, query by date).

What's not realistically automated for v1:
- Global hotkey delivery (requires OS event injection — out-of-process, brittle).
- NSPanel rendering at the right screen position.
- FluidAudio integration (no mock; requires the real model loaded; covered by manual smoke test on each release build).
- SwiftUI view-tree assertions (Apple's snapshot-testing story is shaky).

A v1 release ships with the unit-tested pure logic above and a one-page manual smoke-test checklist (record short / record long / cancel / hotkey conflict / settings change persists / re-launch reads state correctly / paste at cursor in three different host apps). The dev runs it before each tag.

---

## 9. Things explicitly out of scope

- Cross-platform builds.
- iCloud sync (SwiftData makes this easy to add later).
- Live caption streaming in the overlay (v2).
- Cloud transcription providers (intent brief hides them).
- File-upload transcription (intent brief hides it).
- VAD-only recording mode (hidden in current app, stays hidden).

## 9a. Engines considered and not chosen

- **WhisperKit (Whisper on ANE).** Mature, ANE-optimized, but Whisper-only. Whisper Large v3 is multilingual-strong but Parakeet TDT v2 is faster and more accurate on English (the primary use case). Rejected.
- **Apple Speech framework (`SFSpeechRecognizer`).** Built into macOS, no model download, very low cold-start cost. But: lower accuracy on technical/jargon dictation, requires a network round-trip on first use unless you set `requiresOnDeviceRecognition = true` (and on-device mode is English-only and lower-quality than Parakeet). Worth keeping in our back pocket as a "lite mode" but not the primary engine.
- **MLX (Python) Parakeet.** Fastest on GPU but Python-only — unembeddable in a native Swift app without a sidecar. Rejected.
- **`transcribe-rs` Parakeet on CPU (Option A).** What ships first as the quick win; the rewrite supersedes it. Already documented in `transcription-option-a-rust-cpu.md`.
- **Sherpa-ONNX, Vosk, etc.** Older models, lower accuracy. Not competitive.

## 9b. Push-to-talk

PTT is in the codebase today but the default hotkey is unset. The Swift rewrite preserves the capability — `KeyboardShortcuts` exposes both `onKeyDown` and `onKeyUp`, so PTT works the same way. Settings exposes a "Push-to-Talk" hotkey field (defaulting to unbound). When set, the app uses press/release semantics; when unset, the toggle hotkey is the only entry point. Same behaviour as today.

---

## 10. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| FluidAudio API changes during development | Medium | Medium — may require small refactors | Pin to a specific minor version; only bump deliberately |
| Cold CoreML compile takes longer than the wizard copy claims | Medium | Low — user already waiting | Measure on a clean VM before shipping copy; show "Optimizing model for your Mac…" |
| AVAudioEngine input format quirks (e.g. mismatched device sample rate causes converter glitches) | Low | Medium — recordings come out distorted | AVAudioConverter handles it; budget time to actually verify across input devices |
| KeyboardShortcuts library has a bug with Option+Space specifically | Low | High — main UX feature broken | Test early; fall back to hand-rolled Carbon RegisterEventHotKey if needed |
| Notarization / Gatekeeper flow on a Swift app + bundled CoreML | Low | Medium | Standard Xcode flow; thousands of indie apps do this |
| Animation polish takes longer than estimated | Medium | Low — ships with rougher animations and improves later | Acceptable; can iterate after launch |
| Re-implementing the recording library + setup wizard turns out to be 3× the estimate because of SwiftUI quirks | Medium | High — schedule slips | Estimates are rough; build a vertical slice first (item 1–3) and re-estimate |

---

## 10a. Intent-brief alignment (what the brief left open and what we decide here)

The UI-rebuild intent brief at `docs/plans/ui-rebuild-intent.md` left several questions open. This rewrite plan answers them as follows — call out anything that's an over-commitment.

| Brief's open question | Plan's answer |
|---|---|
| **Menu-bar dropdown contents** — minimal, or include recent transcriptions / model switcher? | Keep the same six items from the current rebuild (Toggle, Audio Input submenu, Copy Last, Show Window, Settings, Quit). Do not add a recent-transcriptions list to the menu — it bloats the menu and we already have a Recordings library window for that. |
| **Floating indicator design** — pill, waveform, or icon-only color change? | Pill, four states with the character-reveal on success per `ui-rebuild-design.md`. Same design as the current rebuild. |
| **How far toward native appearance?** | Native everything — SwiftUI controls + SF Symbols + native scrolling/focus rings. Not "indistinguishable from a SwiftUI sample app" but "follows Apple HIG patterns and feels handmade." Don't promise pixel-matching specific Apple apps; promise that nothing feels webby. |
| **Dark mode** — system, user toggle, or dark-only? | Follow system. SwiftUI does this for free. No user toggle. |
| **Setup wizard redesign or keep current?** | Rebuild as native SwiftUI. Same 6 steps, same gating logic. The Tauri wizard is the spec for what each step does; the SwiftUI implementation gives us native form controls (SwiftUI `Picker`, `KeyboardShortcuts.Recorder`, `ProgressView`) for free. |
| **Recording library scope** — keep playback, search, batch delete? | Yes, all three. Plus title editing and re-transcribe (already in current app). No new features in the rewrite. |

## 11. Decision required from CEO

Pick one:

- **A.** Ship Option A (Parakeet on Rust/CPU) inside the existing Tauri app first as a quick quality win, then start the Swift rewrite as a separate effort. Total calendar: ~5 weeks.
- **B.** Skip Option A. Start the Swift rewrite immediately. Keep using the current app daily until the Swift version reaches parity. Total calendar: ~4 weeks.
- **C.** Go with Option B (Swift sidecar) instead of a rewrite. ~3 weeks, three languages forever, smaller win.

Default recommendation: **A**, because it's a few days, validates Parakeet on real daily-driver use, and de-risks the rewrite by isolating "is Parakeet's transcript quality actually right" from "is the rewrite working".

---

## 12. Reference research

- Feature inventory of current app (Agent-generated, this session)
- `docs/research/parakeet-vs-moonshine.md` — engine landscape
- `docs/research/parakeet-vs-moonshine-benchmark.md` — measured performance on this machine
- FluidAudio: <https://github.com/FluidInference/FluidAudio>
- KeyboardShortcuts: <https://github.com/sindresorhus/KeyboardShortcuts>
- MenuBarExtra docs: <https://developer.apple.com/documentation/SwiftUI/MenuBarExtra>
- SwiftData (Apple): <https://developer.apple.com/documentation/swiftdata>
- Sparkle: <https://sparkle-project.org/>
- NSPanel floating overlay pattern: <https://cindori.com/developer/floating-panel>
- WhisperKit (rejected — Whisper-only, no Parakeet): <https://github.com/argmaxinc/WhisperKit>
- macOS Accessibility / CGEvent: <https://blog.kulman.sk/implementing-auto-type-on-macos/>

---

## 13. Honest cost model

The implementer is an AI, not an FTE. Reframe:

- **My output rate** is not the constraint — I can produce an Xcode project skeleton, module stubs, most of a SwiftData model, or a SwiftUI pane in a single session each.
- **Your review rate** is the constraint. Every change I make to a UI needs you to launch the build and tell me what looks wrong, because I can't see the screen.
- **Debug loops** where things break in ways I can't diagnose from code (Gatekeeper, codesigning, runtime crashes that don't reach stderr) each cost a round-trip with you. Plan for 5–10 of these over the rewrite.
- **The "learning Swift" tax** that would apply to a human engineer doesn't apply the same way to me. I'll still write Swift that's less idiomatic than a long-time Apple engineer would, but the code-producing speed isn't gated on ramp-up.

So the real question is: how many cycles a day can you sustain? At five a day this is two weeks. At one a day it's a couple of months. That's the honest math.

If you want to de-risk: ship Option A first (much smaller number of cycles), use it daily for a couple of weeks, decide the rewrite go/no-go from a position of already having Parakeet quality.

---

## Appendix A — Pseudocode for the hot path

```swift
// AudioRecorder.swift (sketch)
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var wavWriter: AVAudioFile?

    func start(outputURL: URL) throws {
        let input = engine.inputNode
        let inputFmt = input.outputFormat(forBus: 0)
        let targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000,
                                      channels: 1,
                                      interleaved: false)!
        converter = AVAudioConverter(from: inputFmt, to: targetFmt)
        wavWriter = try AVAudioFile(forWriting: outputURL, settings: targetFmt.settings)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFmt) { [weak self] buf, _ in
            guard let self else { return }
            let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: 4096)!
            var done = false
            converter?.convert(to: outBuf, error: nil) { _, status in
                if done { status.pointee = .noDataNow; return nil }
                done = true; status.pointee = .haveData; return buf
            }
            try? wavWriter?.write(from: outBuf)
            let p = outBuf.floatChannelData!.pointee
            samples.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
        }

        try engine.start()
    }

    func stop() throws -> (samples: [Float], url: URL) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let s = samples
        samples = []
        let url = wavWriter!.url
        wavWriter = nil
        return (s, url)
    }
}
```

```swift
// HotkeyRouter.swift (sketch)
extension KeyboardShortcuts.Name {
    static let toggle = Self("toggleRecording", default: .init(.space, modifiers: .option))
    static let pasteLast = Self("pasteLast", default: .init(.v, modifiers: [.control, .shift]))
    static let cancelRecording = Self("cancelRecording", default: .init(.escape))
}

final class HotkeyRouter {
    init(recorder: AudioRecorder, transcriber: ParakeetEngine, deliverer: ClipboardSandwich) {
        KeyboardShortcuts.onKeyDown(for: .toggle) {
            Task { await self.toggle() }
        }
        KeyboardShortcuts.onKeyDown(for: .pasteLast) {
            Task { await self.pasteLast() }
        }
    }

    private func registerCancel() {
        KeyboardShortcuts.onKeyDown(for: .cancelRecording) {
            Task { await self.cancel() }
        }
    }

    private func unregisterCancel() {
        KeyboardShortcuts.disable(.cancelRecording)
    }

    private func toggle() async { /* state machine */ }
}
```
