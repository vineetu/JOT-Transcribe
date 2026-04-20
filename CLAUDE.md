# Jot

Native macOS dictation utility. Press a hotkey, speak, and the transcript is pasted at the cursor. Entirely on-device, no network, no telemetry.

**Stack:** Swift / SwiftUI with AppKit interop (`NSStatusItem`, `NSPanel`). Transcription via [FluidAudio](https://github.com/FluidInference/FluidAudio) running Parakeet TDT 0.6B v3 on the Apple Neural Engine. Audio capture through `AVAudioEngine` + `AVAudioConverter` (16 kHz mono Float32). Global hotkeys via `sindresorhus/KeyboardShortcuts`. Persistence via SwiftData; prefs via `@AppStorage` / `UserDefaults`.

**Platform:** Apple Silicon only, macOS Sonoma 14.0+. Intel Macs are out of scope — Parakeet on the ANE is an Apple Silicon feature.

Full product requirements live in `docs/design-requirements.md` and the shipping feature inventory in `docs/features.md`. **Read those before making non-trivial decisions.** This file is a map, not the spec.

---

## Architecture layers

Single Xcode project, one executable target. Each layer is a Swift function boundary — no IPC, no serialization between stages.

| Layer | Responsibility |
|---|---|
| **App** | `@main` entry point, scenes, `AppDelegate`, top-level observable state, permission checks |
| **MenuBar** | `NSStatusItem` owner + native `NSMenu`; dynamic "Start / Stop Recording" label; "Open Jot…" and "Settings…" (`⌘,`) both open the unified main window |
| **MainWindow** | Single `NSWindow` shell with a source-list sidebar (Home / Library / Settings / Help); owns routing between sections and the deep-link contract from Settings popovers into Help |
| **Home** | Landing pane: hotkey glance, recent recordings row, dismissible first-run banner |
| **Overlay** | `NSPanel`-hosted SwiftUI status indicator (Dynamic Island-style pill under the notch) |
| **Recording** | `AVAudioEngine` tap → converter → buffer + WAV on disk; hotkey routing with dynamic Escape; CoreAudio device pinning |
| **Transcription** | FluidAudio wrapper (single in-flight), post-processing, model download/load |
| **Delivery** | Clipboard sandwich: save → write → synthetic `⌘V` → restore; optional auto-Enter |
| **Library** | SwiftData recordings list with search, date grouping, detail + playback, per-row actions |
| **Settings** | Sidebar section (not a separate scene): General / Transcription / Sound / AI / Shortcuts. Per-field `info.circle` popovers with "Learn more →" deep-links into Help. Editable LLM prompts under `CustomizePromptDisclosure` |
| **Help** | In-app prose walkthrough: Basics / Advanced / Troubleshooting. Accepts deep-links from Settings popovers |
| **LLM** | Provider-neutral client for transcript cleanup (Transform) + Articulate; Apple Intelligence (on-device, default for new installs on macOS 26+), OpenAI, Anthropic, Gemini, Vertex Gemini, Ollama. Apple Intelligence bypasses the HTTP client entirely and calls the on-device `FoundationModels` framework via `AppleIntelligenceClient`. Articulate uses a regex instruction classifier (`ArticulateInstructionClassifier`) to route to one of four branch prompts — voice-preserving / structural / translation / code — composed on top of a small shared-invariants block |
| **Articulate** | Two hotkeys, one pipeline. `.articulateCustom` (v1.4 "Rewrite Selection", raw binding key preserved): selection → synthetic ⌘C → record voice instruction → classify → branch-specific LLM prompt → paste back. `.articulate` (v1.5): selection → synthetic ⌘C → fixed `"Articulate this"` instruction → LLM → paste back. No voice capture on the fixed-prompt path |
| **SetupWizard** | First-run window: Welcome → Permissions → Model → Microphone → Shortcuts → Test |
| **Sounds** | Bundled chimes wrapped in a thin `AVAudioPlayer` helper |

**Four distinct privacy capabilities** (not one boolean): Microphone, Input Monitoring, Accessibility post-events, and optional full AX trust. Each has its own grant flow and revocation behavior. Denied post-events degrades to clipboard-only delivery with a toast — never a dead end.

---

## File / directory ownership

Swift code lives under `Sources/` at repo root, with `Resources/` alongside it. `Sources/` is configured as an Xcode **synchronized folder group** (`PBXFileSystemSynchronizedRootGroup`), so new files dropped into layer subfolders are picked up without editing `project.pbxproj`.

```
Sources/
  App/            ← App layer (entry, AppDelegate, root state)
  MenuBar/        ← NSStatusItem + NSMenu
  Overlay/        ← NSPanel status-indicator pill
  Home/           ← Landing pane (hotkey glance, recent row, first-run banner)
  Recording/      ← AVAudioEngine capture, converter, hotkey routing
  Transcription/  ← FluidAudio wrapper, post-processing, model I/O
  LLM/            ← Provider-neutral HTTP client + AppleIntelligenceClient + prompts + classifier
  Articulate/     ← Selection-capture + paste-back controller (fixed and custom-instruction variants)
  Permissions/    ← Mic / input-monitoring / accessibility capability modelling
  Delivery/       ← Clipboard sandwich, synthetic paste, auto-Enter
  Library/        ← SwiftData models + recordings UI
  Settings/       ← SwiftUI Settings scene panes
  SetupWizard/    ← First-run flow window
  Sounds/         ← Chime assets + AVAudioPlayer helper
  Help/           ← In-app Help tab (Basics / Advanced / Troubleshooting cards + visuals)
Resources/        ← Assets.xcassets, Info.plist, Jot.entitlements
docs/             ← Requirements, feature inventory, plans, research — read-only from code
```

Keep each folder to its single layer. Cross-layer shared types (e.g. `Recording` model) belong in the layer that owns the source of truth (Library for the SwiftData model) and are imported by consumers.

---

## Key constraints

- **Transcription stays on-device.** Audio and transcripts never leave the Mac via the transcription path. The only automatic network calls are: the initial Parakeet model download, and the daily Sparkle update check.
- **LLM paths are provider-neutral; Apple Intelligence is the default on macOS 26+.** Transform (cleanup) and Articulate route through whatever provider the user has selected. For fresh installs on macOS 26+, Apple Intelligence (on-device via the `FoundationModels` framework) is the default — no API key, no network, nothing leaves the Mac. Existing v1.4 users keep their configured provider unchanged (`@AppStorage` honors the stored value). Ollama remains available for users who want local-but-not-Apple. Cloud providers (OpenAI, Anthropic, Gemini, Vertex Gemini) are opt-in.
- **No telemetry.** No analytics, crash reporting, or error pings. A privacy-conscious user with Little Snitch must see only: model download (first-run), appcast fetch (daily), and whatever LLM endpoint they explicitly configured.
- **No accounts.** The app must be fully usable without signing in anywhere.
- **Apple Silicon, macOS 14+.** Don't add compatibility shims for Intel or older macOS.
- **Global shortcuts must not steal keys they don't own.** The cancel key (`Esc`) is only active while recording, transforming, capturing a voice instruction for Articulate (Custom), or articulating.
- **Native Mac feel.** SwiftUI + AppKit where appropriate, SF Symbols, system semantic colors, `NSVisualEffectView` vibrancy, HIG-aligned motion. No web-in-a-wrapper patterns.
- **Out of scope:** cloud transcription, VAD / continuous listening, file upload, non-macOS ports, multi-user sync.

---

## Releasing a new version

The canonical path is one command: `./scripts/release.sh <version>` (e.g. `./scripts/release.sh 1.1`). It bumps `CFBundleShortVersionString`, derives `CFBundleVersion` from commit count, builds + signs + notarizes the DMG, generates the Sparkle appcast, scp's the DMG to the website host, commits, tags `v<version>`, and pushes to the `origin` remote.

Per-machine prerequisites (one-time):

- Notarization keychain profile: `xcrun notarytool store-credentials Jot --apple-id <id> --team-id 8VB2ULDN22` (interactive; password goes into the login keychain).
- Website scp target and credentials. The script fails fast if any of these are unset (or set `JOT_SKIP_WEBSITE_UPLOAD=1` to skip the upload entirely). Add to `~/.zshrc`:
  - `export JOT_DEPLOY_HOST="…"` — scp target in `[user@]host` form (e.g. `root@1.2.3.4`).
  - `export JOT_DEPLOY_PATH="…"` — absolute remote path for the uploaded DMG (e.g. `/srv/jot/Jot.dmg`).
  - `export JOT_DEPLOY_PASS="…"` — password for `sshpass`.

The release commit stages an explicit allowlist (`Sources/`, `Resources/`, `docs/`, `website/`, `scripts/`, `README.md`, `CLAUDE.md`, `.gitignore`, plus root-level `appcast.xml`). Anything outside those paths — local experiments, stray files at repo root — will NOT be picked up; commit those separately before running the release.

After the script finishes, upload the DMG to the GitHub release:

```
gh release create v<version> dist/Jot.dmg \
  --repo vineetu/JOT-Transcribe \
  --title "Jot v<version>"
```

If a release already exists and you just need to re-upload the DMG:

```
gh release upload v<version> dist/Jot.dmg --clobber --repo vineetu/JOT-Transcribe
```

### Custom flavors

To release a custom flavor (different endpoints / models / remote / tag suffix),
`source .flavor-<name>.env && ./scripts/release.sh <version>`. The env file is
gitignored and holds flavor-specific values — tag suffix, GH host/repo, push
remotes, DMG name, and a path to a `KEY=VALUE` overrides file whose entries are
injected into `Info.plist` for the archive (and restored on exit). See internal
team docs for the actual flavor values.

**Signing:** Developer ID Application: Vineet Sriram (8VB2ULDN22). Details in `docs/plans/apple-signing.md`.

**Auto-update:** Sparkle 2.x checks `appcast.xml` at repo root (served via GitHub raw content). EdDSA private key is in the local Keychain — do not export it. Public key is in Info.plist (`SUPublicEDKey`).

**Website:** https://jot.ideaflow.page/ — static site at `website/index.html`. Download links use GitHub's `releases/latest/download/Jot.dmg` pattern, so the site auto-points at the newest non-prerelease without a redeploy. The DMG mirrored on the site is what `release.sh` uploads via scp.

---

## When you ship a feature, update these

A lightweight checklist — keeps README, website, docs, and release notes from drifting behind the code. Run through it at the end of any user-visible change:

- [ ] **`docs/features.md`** — canonical feature inventory. If the user can do something new, it belongs here.
- [ ] **`docs/design-requirements.md`** — only if the product shape or an out-of-scope line shifted.
- [ ] **`README.md`** — add/trim the short marketing bullet if it's a headline feature.
- [ ] **`website/index.html`** — the "Capabilities" card grid, only for headline features.
- [ ] **Shortcuts registry** — if the feature is driven by a hotkey, register it in `Sources/Recording/Hotkeys/ShortcutNames.swift` and wire it through `HotkeyRouter`. Make sure `Esc` / cancel dispatches to it if it's cancellable.
- [ ] **Status pill states** — if the feature has its own in-progress UI, add the state to `RecorderController.State` / `PillState` and handle it in every `switch` on those enums.
- [ ] **Menu bar** — if it surfaces as a menu action, add it in `JotMenuBarController`.
- [ ] **Settings pane** — add a toggle / field in the matching sidebar section (General / Transcription / Sound / AI / Shortcuts) if there's any configurability. New fields should carry an `info.circle` popover with a "Learn more →" deep-link into the Help tab.
- [ ] **Help tab** — add prose under Basics / Advanced / Troubleshooting so the feature is discoverable in-app, and wire the Settings popover's deep-link to land on that section.
- [ ] **Setup wizard** — only if a new permission or a new required setup step.

Keep cross-cutting concerns (cancellability, pipeline states, hotkey routing) in exhaustive `switch` statements on enums — the compiler is the checklist for "did I update every site?" when a case is added.

---

## Where to read next

- `docs/design-requirements.md` — stack-agnostic product requirements (source of truth for **what**)
- `docs/features.md` — shipping feature inventory
- `docs/plans/transform.md` — optional LLM cleanup + Articulate design
- `docs/research/apple-intelligence-as-provider.md` — Apple Intelligence default-provider decision, long-form limitations, 6-provider strategy
- `docs/research/future-model-switching.md` — latent issue flagged for when a 2nd Parakeet variant ships
- `docs/plans/apple-signing.md` — Developer ID signing + notarization notes
