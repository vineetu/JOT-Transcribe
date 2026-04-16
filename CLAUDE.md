# Jot

Native macOS dictation utility. Press a hotkey, speak, and the transcript is pasted at the cursor. Entirely on-device, no network, no telemetry.

**Stack:** Swift / SwiftUI with AppKit interop (`NSStatusItem`, `NSPanel`). Transcription via [FluidAudio](https://github.com/FluidInference/FluidAudio) running Parakeet TDT 0.6B v3 on the Apple Neural Engine. Audio capture through `AVAudioEngine` + `AVAudioConverter` (16 kHz mono Float32). Global hotkeys via `sindresorhus/KeyboardShortcuts`. Persistence via SwiftData; prefs via `@AppStorage` / `UserDefaults`.

**Platform:** Apple Silicon only, macOS Sonoma 14.0+. Intel Macs are out of scope — Parakeet on the ANE is an Apple Silicon feature.

Full product requirements live in `docs/design-requirements.md`, shipping feature inventory in `docs/features.md`, and architectural rationale + open risks in `docs/plans/swift-rewrite.md`. **Read those before making non-trivial decisions.** This file is a map, not the spec.

---

## Architecture layers

Single Xcode project, one executable target. Each layer is a Swift function boundary — no IPC, no serialization between stages.

| Layer | Responsibility |
|---|---|
| **App** | `@main` entry point, scenes, `AppDelegate`, top-level observable state, permission checks |
| **MenuBar** | `NSStatusItem` owner + native `NSMenu`; dynamic "Start / Stop Recording" label |
| **Overlay** | `NSPanel`-hosted SwiftUI status indicator (Dynamic Island-style pill under the notch) |
| **Recording** | `AVAudioEngine` tap → converter → buffer + WAV on disk; hotkey routing with dynamic Escape |
| **Transcription** | FluidAudio wrapper (single in-flight), post-processing, model download/load |
| **Delivery** | Clipboard sandwich: save → write → synthetic `⌘V` → restore; optional auto-Enter |
| **Library** | SwiftData recordings list with search, date grouping, detail + playback, per-row actions |
| **Settings** | SwiftUI `Settings` scene: General / Transcription / Sound / Shortcuts (editable via `KeyboardShortcuts.Recorder`) |
| **SetupWizard** | First-run window: Welcome → Permissions → Model → Microphone → Shortcuts → Test |
| **Sounds** | Bundled chimes wrapped in a thin `AVAudioPlayer` helper |

**Four distinct privacy capabilities** (not one boolean): Microphone, Input Monitoring, Accessibility post-events, and optional full AX trust. Each has its own grant flow and revocation behavior — see the Permissions table in `docs/plans/swift-rewrite.md`. Denied post-events degrades to clipboard-only delivery with a toast — never a dead end.

---

## Phased build order

1. **Skeleton + bootstrap** — Xcode project, `@main`, `AppDelegate`, empty Settings scene, first-run detection, Permissions service, model-download utility.
2. **Audio + Transcription** — `AVAudioEngine` capture, FluidAudio wrapper, end-to-end "record 3 s → print transcript".
3. **Hotkeys + Delivery** — `KeyboardShortcuts` wired, dynamic `Esc`, clipboard sandwich, synthetic `⌘V`, clipboard-only fallback.
4. **UI Surfaces** — menu bar, status indicator, recordings library, settings panes.
5. **Setup Wizard UI + Polish** — polished first-run flow, vibrancy, chimes, DMG packaging.

**Critical path:** 1 → 2 → 3. Phases 4 and 5 parallelize after 3. The three pre-flight spikes (paste-delivery matrix, `KeyboardShortcuts` dynamic enable/disable, overlay placement under the notch) run alongside Phase 1 — if any fails, switch to its documented fallback before investing further.

---

## File / directory ownership

Swift code lives under `Sources/` at repo root, with `Resources/` alongside it. `Sources/` is configured as an Xcode **synchronized folder group** (`PBXFileSystemSynchronizedRootGroup`), so new files dropped into layer subfolders are picked up without editing `project.pbxproj`.

```
Sources/
  App/            ← App layer (entry, AppDelegate, root state)
  MenuBar/        ← NSStatusItem + NSMenu
  Overlay/        ← NSPanel status-indicator pill
  Recording/      ← AVAudioEngine capture, converter, hotkey routing
  Transcription/  ← FluidAudio wrapper, post-processing, model I/O
  Permissions/    ← Mic / input-monitoring / accessibility capability modelling
  Delivery/       ← Clipboard sandwich, synthetic paste, auto-Enter
  Library/        ← SwiftData models + recordings UI
  Settings/       ← SwiftUI Settings scene panes
  SetupWizard/    ← First-run flow window
  Sounds/         ← Chime assets + AVAudioPlayer helper
Resources/        ← Assets.xcassets, Info.plist, Jot.entitlements
docs/             ← Requirements, feature inventory, plans, research — read-only from code
```

Keep each folder to its single layer. Cross-layer shared types (e.g. `Recording` model) belong in the layer that owns the source of truth (Library for the SwiftData model) and are imported by consumers.

---

## Key constraints

- **100% local.** No audio, transcript, or settings data leaves the device. The only network call in the app is the initial Parakeet model download.
- **No telemetry.** No analytics, crash reporting, or error pings. A privacy-conscious user with Little Snitch must see nothing outbound after model download.
- **No accounts.** The app must be fully usable without signing in anywhere.
- **Apple Silicon, macOS 14+.** Don't add compatibility shims for Intel or older macOS.
- **Global shortcuts must not steal keys they don't own.** The cancel key (`Esc`) is registered only while recording.
- **Native Mac feel.** SwiftUI + AppKit where appropriate, SF Symbols, system semantic colors, `NSVisualEffectView` vibrancy, HIG-aligned motion. No web-in-a-wrapper patterns.
- **Out of scope:** cloud transcription, VAD / continuous listening, file upload, LLM post-processing, non-macOS ports, multi-user sync.

---

## Where to read next

- `docs/design-requirements.md` — stack-agnostic product requirements (source of truth for **what**)
- `docs/features.md` — shipping feature inventory
- `docs/plans/swift-rewrite.md` — architecture, key decisions, pre-flight spikes, phased build, release bar
- `docs/plans/apple-signing.md` — Developer ID signing + notarization notes
- `docs/research/parakeet-vs-moonshine.md` and `docs/research/parakeet-vs-moonshine-benchmark.md` — engine selection rationale
