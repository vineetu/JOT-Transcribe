# S2 — hotkey-toggle

## Status: BUILT, HUMAN-VERIFICATION-PENDING

## What the spike is

A minimal SwiftUI executable (`Spikes/hotkey-toggle/`) that pulls in `sindresorhus/KeyboardShortcuts` 2.4.0 (same version pinned in the main project) and declares two shortcuts:

- `.toggleRecording` — default `⌥Space`
- `.cancelRecording` — default `Esc`

The UI is two toggles (one per shortcut) and a log view. Flipping a toggle calls `KeyboardShortcuts.enable(_:)` / `disable(_:)`. Every key-down firing logs a line. This isolates the one question we care about: **when `disable(_:)` is called, is the OS-level hot-key registration actually released, so the key goes back to the focused app?** That matters for `Esc`, which we only want to claim during a recording.

## What I (agent) verified

- [x] SPM resolves `sindresorhus/KeyboardShortcuts` at 2.4.0 (same pin as main project).
  - Output includes `Computed https://github.com/sindresorhus/KeyboardShortcuts at 2.4.0`.
- [x] Builds for arm64-macos14
  - Command: `cd Spikes/hotkey-toggle && swift build -c release`
  - Output: `Build complete! (13.11s)`
  - `file .build/release/HotkeyToggle` → `Mach-O 64-bit executable arm64`
- [x] Launches without crashing. Ran the binary, left it up for ~2 s, killed it cleanly.
- [x] Key code paths present:
  - `KeyboardShortcuts.Name` declarations: `Sources/HotkeyToggle/Shortcuts.swift:4–11`
  - `onKeyDown` handler registration: `HotkeyToggleApp.swift:28–32`
  - Enable/disable switching based on toggle state: `HotkeyToggleApp.swift:38–46`
- [x] Type-checks against 2.4.0's public API (`enable`, `disable`, `onKeyDown(for:action:)`, `.Name(_:default:)`).

## What requires a human at the machine

We can confirm the API compiles and handlers fire on the spike's window, but confirming that `Esc` is **released back to other apps** requires pressing `Esc` in Safari (or another app) and watching its UI. Do this manually:

- [ ] **Launch the spike.** `swift run -c release HotkeyToggle`. On first launch macOS will likely prompt for Input Monitoring — grant via System Settings → Privacy & Security → Input Monitoring. (KeyboardShortcuts uses Carbon `RegisterEventHotKey` which doesn't strictly need Input Monitoring on current macOS, but grant it to be safe for the test.)
- [ ] **Step 1 — Cancel OFF, expect Safari sees Esc.** Toggle "Enable Cancel Recording (Esc)" off. Focus Safari, click in the address bar, press `Esc`. Expected: Safari blurs / acts normally. Spike log does NOT print `FIRED: cancelRecording`.
- [ ] **Step 2 — Cancel ON, expect spike sees Esc.** Toggle it on. Focus Safari, press `Esc`. Expected: spike log prints `FIRED: cancelRecording`. Safari does NOT see the Esc (address bar stays focused / modal stays up).
- [ ] **Step 3 — Cancel OFF again, expect Safari sees Esc.** Toggle off. Press Esc in Safari. Safari handles it normally.
- [ ] **Step 4 — Rapid toggle.** Flip cancel on/off 10 times rapidly, then confirm behavior at the final state matches the toggle. This rules out stuck registration from repeated `enable`/`disable`.
- [ ] **Step 5 — Toggle Recording always works.** With whatever state, press `⌥Space` (while `toggleRecording` is on). Spike logs `FIRED: toggleRecording`. Toggle its checkbox off, press `⌥Space`. Nothing logged. Toggle on again, press — logs again.
- [ ] **Decision gate:**
  - **PASS** → use `KeyboardShortcuts.enable/.disable` for dynamic Esc in Phase 3.
  - **FAIL** (disable leaves Esc swallowed, or rapid toggle breaks) → fall back to a thin Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` wrapper in `Sources/Recording/Hotkeys/` (~50 lines). See fallback in `docs/plans/swift-rewrite.md`.

## How to run

```bash
cd Spikes/hotkey-toggle
swift build -c release
swift run -c release HotkeyToggle
```

## If the spike fails

Follow the Carbon-HIToolbox fallback in `docs/plans/swift-rewrite.md`. KeyboardShortcuts itself wraps `RegisterEventHotKey` under the hood, so if its dynamic disable is broken, bypassing it and calling Carbon directly is the smallest retreat.
