# Jot

Native macOS dictation utility. Press a hotkey, speak, and the transcript is pasted at the cursor. Core transcription stays on-device; optional AI features can use Apple Intelligence, local Ollama, or user-configured cloud providers. No telemetry.

**Stack:** Swift / SwiftUI with AppKit interop (`NSStatusItem`, `NSPanel`). Transcription via [FluidAudio](https://github.com/FluidInference/FluidAudio) running Parakeet TDT 0.6B v3 on the Apple Neural Engine. Audio capture through `AVAudioEngine` + `AVAudioConverter` (16 kHz mono Float32). Global hotkeys via `sindresorhus/KeyboardShortcuts`. Persistence via SwiftData; prefs via `@AppStorage` / `UserDefaults`.

**Platform:** Apple Silicon only, macOS Sonoma 14.0+. Intel Macs are out of scope — Parakeet on the ANE is an Apple Silicon feature.

Full product requirements live in `docs/design-requirements.md` and the shipping feature inventory in `docs/features.md`. **Read those before making non-trivial decisions.** This file is a map, not the spec.

---

## Architecture layers

Single Xcode project, one executable target. Each layer is a Swift function boundary — no IPC, no serialization between stages.

| Layer | Responsibility |
|---|---|
| **App** | `@main` entry point, scenes, `AppDelegate`, top-level observable state, permission checks |
| **MenuBar** | `NSStatusItem` owner + native `NSMenu`; dynamic "Start / Stop Recording" label; "Open Jot…", Recent Transcriptions, and "Check for Updates…" |
| **MainWindow** | Single `NSWindow` shell with a source-list sidebar (Home / Ask Jot / Settings / Help / About); owns routing between sections, sidebar history, and the deep-link contract between Settings, Help, and Ask Jot |
| **Home** | Landing pane: hotkey glance, dismissible first-run banner, full recordings search/list/detail surface |
| **Ask Jot** | Conversational help chatbot pane; grounded in bundled `help-content.md`; Apple Intelligence default, optional cloud routing; markdown answers, voice input, and in-app feature citations |
| **AskJot/Cloud** | Provider-specific streaming adapters (`OpenAI`, `Anthropic`, `Gemini`, `Ollama`) plus inline tool-calling for feature-slug navigation when cloud Ask Jot is enabled |
| **Overlay** | `NSPanel`-hosted SwiftUI status indicator (Dynamic Island-style pill under the notch) |
| **Recording** | `AVAudioEngine` tap → converter → buffer + WAV on disk; hotkey routing with dynamic Escape; CoreAudio device pinning |
| **Transcription** | FluidAudio wrapper (single in-flight), post-processing, model download/load |
| **Delivery** | Clipboard sandwich: save → write → synthetic `⌘V` → restore; optional auto-Enter |
| **Library** | SwiftData models — `Recording` (dictation) + `RewriteSession` (rewrite runs) — and the merged `LibraryItem`-driven Home list, detail views, playback (recordings only), and per-row actions |
| **Settings** | Sidebar section (not a separate scene): General / Transcription / Vocabulary / Sound / AI / Shortcuts. Per-field `info.circle` popovers with "Learn more →" deep-links into Help. Editable LLM prompts under `CustomizePromptDisclosure` |
| **Help** | In-app prose walkthrough: Basics / Advanced / Troubleshooting. Accepts deep-links from Settings popovers, Ask Jot feature links, and Help hero sparkle affordances |
| **LLM** | Provider-neutral client for transcript cleanup (Transform) + Rewrite; Apple Intelligence (on-device, default for new installs on macOS 26+), OpenAI, Anthropic, Gemini, Ollama. Apple Intelligence bypasses the HTTP client entirely and calls the on-device `FoundationModels` framework via `AppleIntelligenceClient`. Rewrite uses a regex instruction classifier (`RewriteInstructionClassifier`) to route to one of four branch prompts — voice-preserving / structural / translation / code — composed on top of a small shared-invariants block |
| **Rewrite** | Two hotkeys, one pipeline. `.rewriteWithVoice` (v1.4; raw KeyboardShortcuts storage key `rewriteSelection` preserved across the v1.4→v1.6 Swift symbol rename): selection → synthetic ⌘C → record voice instruction → classify → branch-specific LLM prompt → paste back. `.rewrite` (v1.5; raw storage key `articulate` preserved): selection → synthetic ⌘C → fixed `"Rewrite this"` instruction → LLM → paste back. No voice capture on the fixed-prompt path |
| **SetupWizard** | First-run window: Welcome → Permissions → Model → Microphone → Shortcuts → Test |
| **Sounds** | Bundled chimes wrapped in a thin `AVAudioPlayer` helper |

**Four distinct privacy capabilities** (not one boolean): Microphone, Input Monitoring, Accessibility post-events, and optional full AX trust. Each has its own grant flow and revocation behavior. Denied post-events degrades to clipboard-only delivery with a toast — never a dead end.

---

## File / directory ownership

Swift code lives under `Sources/` at repo root, with `Resources/` alongside it. `Sources/` is configured as an Xcode **synchronized folder group** (`PBXFileSystemSynchronizedRootGroup`), so new files dropped into layer subfolders are picked up without editing `project.pbxproj`.

```
Sources/
  App/            ← App layer (entry, AppDelegate, root state)
  AskJot/         ← Ask Jot chatbot pane, state, rendering, voice input, slug-link pipeline
  AskJot/Cloud/   ← Cloud Ask Jot streaming adapters + tool-calling
  MenuBar/        ← NSStatusItem + NSMenu
  Overlay/        ← NSPanel status-indicator pill
  Home/           ← Landing pane + full recordings browser
  Recording/      ← AVAudioEngine capture, converter, hotkey routing
  Transcription/  ← FluidAudio wrapper, post-processing, model I/O
  LLM/            ← Provider-neutral HTTP client + AppleIntelligenceClient + prompts + classifier
  Rewrite/        ← Selection-capture + paste-back controller (fixed and voice-instruction variants)
  Permissions/    ← Mic / input-monitoring / accessibility capability modelling
  Delivery/       ← Clipboard sandwich, synthetic paste, auto-Enter
  Library/        ← SwiftData models + recordings UI/state used by Home
  Settings/       ← SwiftUI Settings scene panes
  SetupWizard/    ← First-run flow window
  Sounds/         ← Chime assets + AVAudioPlayer helper
  Help/           ← In-app Help tab (Basics / Advanced / Troubleshooting cards + visuals)
  Donation/       ← Support / donate surface
  Privacy/        ← Privacy-scan flows for logs and exports
  Vocabulary/     ← Custom vocabulary storage + rescoring helpers
Resources/
  Assets.xcassets/
  help-content-base.md   ← checked-in grounding doc base
  fragments/             ← generated help-doc fragments
  help-content.md        ← generated at build time, gitignored
  Info.plist
  Jot.entitlements
tools/
  generate-fragments.swift
  concat-help-content.swift
  check-help-doc-budget.swift
docs/             ← Requirements, feature inventory, plans, research — read-only from code
```

Keep each folder to its single layer. Cross-layer shared types (e.g. `Recording` model) belong in the layer that owns the source of truth (Library for the SwiftData model) and are imported by consumers.

---

## Key constraints

- **Transcription stays on-device.** Audio and transcripts never leave the Mac via the transcription path. The only automatic network calls are: the initial Parakeet model download, and the daily Sparkle update check.
- **LLM paths are provider-neutral; Apple Intelligence is the default on macOS 26+.** Transform (cleanup) and Rewrite route through whatever provider the user has selected. For fresh installs on macOS 26+, Apple Intelligence (on-device via the `FoundationModels` framework) is the default — no API key, no network, nothing leaves the Mac. Existing v1.4 users keep their configured provider unchanged (`@AppStorage` honors the stored value). Ollama remains available for users who want local-but-not-Apple. Cloud providers (OpenAI, Anthropic, Gemini) are opt-in.
- **Ask Jot has its own provider policy.** Ask Jot defaults to Apple Intelligence at the instrumentation level. If the selected AI provider is non-Apple, Ask Jot only routes to that provider when the user explicitly enables "Allow Ask Jot to use this provider" in Settings → AI; otherwise Ask Jot remains on Apple Intelligence.
- **Ask Jot grounding is budget-enforced at build time.** `Resources/help-content.md` is generated from `Resources/help-content-base.md` plus fragments by build-phase scripts in `tools/`, is gitignored, and must stay within a 1500-token budget. The current shipped grounding doc is 1015 tokens.
- **Ask Jot post-processing is provider-agnostic.** Slug correction / injection / sharp-fix forcing / command scrubbing run on both Apple and cloud Ask Jot responses. Inline tool-calling is cloud-only. The current shipped pass lifted citation coverage from roughly 28% to roughly 61%, with sharp-fix leak coverage at 100%.
- **No telemetry.** No analytics, crash reporting, or error pings. A privacy-conscious user with Little Snitch must see only: model download (first-run), appcast fetch (daily), and whatever LLM endpoint they explicitly configured.
- **No accounts.** The app must be fully usable without signing in anywhere.
- **Apple Silicon, macOS 14+.** Don't add compatibility shims for Intel or older macOS.
- **Global shortcuts must not steal keys they don't own.** The cancel key (`Esc`) is only active while recording, transforming, capturing a voice instruction for Rewrite with Voice, or rewriting.
- **Native Mac feel.** SwiftUI + AppKit where appropriate, SF Symbols, system semantic colors, `NSVisualEffectView` vibrancy, HIG-aligned motion. No web-in-a-wrapper patterns.
- **Out of scope:** cloud transcription, VAD / continuous listening, file upload, non-macOS ports, multi-user sync.

---

## Releasing a new version

**Use the flavor-specific wrappers, never `release.sh` directly.** They add precondition asserts that catch the two known failure classes (Sony content leaking into public DMG; sony/main push rejected non-fast-forward).

- Public: `./scripts/release-public.sh <version>` — refuses if `JOT_FLAVOR_NAME` is set, asserts Info.plist is clean (no FLAVOR_1, no playstation hosts, no Sony SUFeedURL), confirms `git diff Resources/Info.plist` is empty (catches stale state from manual `xcodebuild archive` testing). Push targets `public` remote only.
- Sony: `./scripts/release-sony.sh <version>` — sources `.flavor-sony.env`, asserts the env is well-formed, sets `JOT_FORCE_PUSH=1` (sony/main diverges per cycle; force-with-lease + force-if-includes makes it safe). Push targets `sony` remote only.

Both wrappers `exec` into `scripts/release.sh`, which **also runs the same asserts internally** as defense-in-depth. So even a direct `./scripts/release.sh 1.9` invocation bails on a misconfigured worktree — the wrappers fail earlier with clearer messages and never leave the worktree mid-build.

What `release.sh` does once the asserts pass: bumps `CFBundleShortVersionString`, derives `CFBundleVersion` from commit count, builds + signs + notarizes the DMG, generates the Sparkle appcast (public only — `JOT_SKIP_APPCAST=1` for Sony), commits the allowlist, tags `v<version>` (Sony adds `-sony` suffix), pushes to the configured remote, and creates the GitHub release. The DMG is published via `gh release create`; the public website's download button resolves to it via GitHub's `releases/latest/download/Jot.dmg` redirect.

Per-machine prerequisites (one-time):

- Notarization keychain profile: `xcrun notarytool store-credentials Jot --apple-id <id> --team-id 8VB2ULDN22` (interactive; password goes into the login keychain).

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

Release checks before shipping:

- `help-content.md` budget check passes.
- `HelpInfraTests.runAll()` including `InfoCircleAnchorTests` passes in `DEBUG`.

### Custom flavors

The Sony wrapper (`scripts/release-sony.sh`) is the model — it sources
`.flavor-sony.env`, sets `JOT_PUSH_REMOTES=sony` + `JOT_FORCE_PUSH=1`, and
exec's `scripts/release.sh`. The env file is gitignored and holds flavor-
specific values: tag suffix, GH host/repo, push remotes, DMG name, and a path
to a `KEY=VALUE` overrides file whose entries are injected into `Info.plist`
for the archive (and restored on exit). For a new flavor, copy the Sony
wrapper as a starting template and add a flavor-specific
`scripts/lib/assert-<flavor>-plist.sh` that runs after overrides apply.

To release the Sony flavor: `./scripts/release-sony.sh <version>`.

**Signing:** Developer ID Application: Vineet Sriram (8VB2ULDN22). Details in `docs/plans/apple-signing.md`.

**Auto-update:** Sparkle 2.x checks `appcast.xml` at repo root (served via GitHub raw content). EdDSA private key is in the local Keychain — do not export it. Public key is in Info.plist (`SUPublicEDKey`).

**Website:** ALL website and donations-service changes live in the separate repo `vineetu/jot-website`, cloned at `~/code/jot-website` — do NOT edit `website/` in this repo; it's a legacy copy.

- `~/code/jot-website/jot-transcribe.com/` — the marketing site at **https://jot-transcribe.com/** (primary domain, June 2026 on), including the live **donations page** at `/donations/` and the privacy page at `/privacy`. Pure static; deploy by running `vercel deploy --prod --yes` inside that folder (Vercel project `jot-transcribe`, already linked via `.vercel/`).
- `~/code/jot-website/website/` — the legacy site still served at https://jot.ideaflow.page/ (kept for old links only; all content now lives on jot-transcribe.com). Served from disk on the ideaflow workspace box via `cortex-runports` (see that repo's README runbook); edits go live only when that box pulls.
- `~/code/jot-website/webhook-service/` — Go donations service behind https://jot-donations.ideaflow.page/ (Every.org webhooks + summary API).

Download links everywhere use GitHub's `releases/latest/download/Jot.dmg` pattern, so sites auto-point at the newest non-prerelease without a redeploy.

---

## When you ship a feature, update these

A lightweight checklist — keeps README, website, docs, and release notes from drifting behind the code. Run through it at the end of any user-visible change:

- [ ] **`docs/features.md`** — canonical feature inventory. If the user can do something new, it belongs here.
- [ ] **`docs/design-requirements.md`** — only if the product shape or an out-of-scope line shifted.
- [ ] **`README.md`** — add/trim the short marketing bullet if it's a headline feature.
- [ ] **`website/index.html`** — the "Capabilities" card grid, only for headline features.
- [ ] **`Resources/help-content.md` budget** — confirm the build-phase budget check still passes after Help / Ask Jot copy changes.
- [ ] **Shortcuts registry** — if the feature is driven by a hotkey, register it in `Sources/Recording/Hotkeys/ShortcutNames.swift` and wire it through `HotkeyRouter`. Make sure `Esc` / cancel dispatches to it if it's cancellable.
- [ ] **Status pill states** — if the feature has its own in-progress UI, add the state to `RecorderController.State` / `PillState` and handle it in every `switch` on those enums.
- [ ] **Menu bar** — if it surfaces as a menu action, add it in `JotMenuBarController`.
- [ ] **Settings pane** — add a toggle / field in the matching sidebar section (General / Transcription / Sound / AI / Shortcuts) if there's any configurability. New fields should carry an `info.circle` popover with a "Learn more →" deep-link into the Help tab.
- [ ] **Help tab** — add prose under Basics / Advanced / Troubleshooting so the feature is discoverable in-app, and wire the Settings popover's deep-link to land on that section.
- [ ] **Help infra tests** — in `DEBUG`, run `HelpInfraTests.runAll()` and make sure `InfoCircleAnchorTests` still resolves every deep-link anchor.
- [ ] **Setup wizard** — only if a new permission or a new required setup step.

Keep cross-cutting concerns (cancellability, pipeline states, hotkey routing) in exhaustive `switch` statements on enums — the compiler is the checklist for "did I update every site?" when a case is added.

---

## Where to read next

- `docs/design-requirements.md` — stack-agnostic product requirements (source of truth for **what**)
- `docs/features.md` — shipping feature inventory
- `docs/plans/transform.md` — optional LLM cleanup + Rewrite design
- `docs/research/apple-intelligence-as-provider.md` — Apple Intelligence default-provider decision, long-form limitations, 6-provider strategy
- `docs/research/future-model-switching.md` — latent issue flagged for when a 2nd Parakeet variant ships
- `docs/plans/apple-signing.md` — Developer ID signing + notarization notes
