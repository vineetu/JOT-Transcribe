# S1 — delivery-matrix

## Status: BUILT, HUMAN-VERIFICATION-PENDING

## What the spike is

A minimal SwiftUI executable (`Spikes/delivery-matrix/`) that exposes a text field, a 3-second-countdown "Paste" button, and a log view. On button press it runs `Paster.paste(...)`:

1. Snapshots the current `NSPasteboard.general` items (all types, all data).
2. Clears and writes the sample string as `.string`.
3. Builds `⌘V` key-down + key-up `CGEvent`s with the command flag and `CGEventPost`s them at `.cghidEventTap`.
4. Optionally posts `Return` after a 40 ms delay (if "Also press Return" is checked).
5. After 350 ms (enough for the target app to consume the paste), restores the original pasteboard items.

This is the exact "clipboard sandwich" the Phase 3 Delivery layer plans to use, isolated so we can measure reliability per target app before building on it.

## What I (agent) verified

- [x] Builds for arm64-macos14
  - Command: `cd Spikes/delivery-matrix && swift build -c release`
  - Output: `Build complete! (5.46s)`
  - `file .build/release/DeliveryMatrix` → `Mach-O 64-bit executable arm64`
- [x] Launches without crashing. Ran the binary, left it up for ~2 s, killed it cleanly.
- [x] Clipboard sandwich code path is implemented end-to-end:
  - Pasteboard snapshot/restore: `Paster.swift:58–87`
  - `CGEventSource` + `⌘V` post at `.cghidEventTap`: `Paster.swift:20–46`
  - Optional Return: `Paster.swift:48–59`
  - AX trust check before posting: `Paster.swift:10–12`
- [x] When Accessibility is not granted, `AXIsProcessTrusted()` returns false and the log prints a clear FAIL message rather than silently doing nothing.

## What requires a human at the machine

Running a GUI paste test against real apps is not something an agent can do — there's no way to focus Slack, confirm a 1Password secure-field failure mode, or visually read a `<textarea>`. Do this manually:

- [ ] **Grant Accessibility for this binary.** System Settings → Privacy & Security → Accessibility → add `Spikes/delivery-matrix/.build/release/DeliveryMatrix` (or run it once and accept the prompt). Toggle on.
- [ ] **AppKit native.** Focus each of Notes, Mail, Safari address bar, TextEdit. For each: click into a text field in the target, switch to the spike, click "Paste in 3 s", switch focus back within the countdown. Expected: sample string appears at cursor; log shows `POSTED ⌘V`.
- [ ] **Electron.** Same drill for Slack, Discord, VS Code, Notion, Obsidian.
- [ ] **Chromium.** Same for Chrome (address bar + a textarea on any page), Arc, Brave.
- [ ] **Terminal.** Terminal.app, iTerm2.
- [ ] **Secure field (expected graceful fail).** 1Password main-window search field — paste should work. The actual password field should reject the paste gracefully (no crash, no half-state).
- [ ] **Restore check.** Before starting, copy something identifiable (e.g. an image or custom text). After each paste, `⌘V` into a scratch TextEdit — confirm the original clipboard content is restored.
- [ ] **Decision gate:**
  - **PASS** (≥ 90 % of target apps accept the paste, and graceful fail in secure fields) → adopt synthetic `⌘V` as primary delivery path for Phase 3.
  - **FAIL** (< 90 %, or any target corrupts state) → switch Phase 3 Delivery default to clipboard-only with a toast + optional AX text-insertion where the target supports it. See the fallback note in `docs/plans/swift-rewrite.md`.

Record outcomes per app in a short table at the bottom of this file once testing is done.

## How to run

```bash
cd Spikes/delivery-matrix
swift build -c release
swift run -c release DeliveryMatrix
```

## If the spike fails

See the "Fail" branch in the decision gate above, and the fallback described under "Delivery" in `docs/plans/swift-rewrite.md` — clipboard-only with an explicit toast is the documented retreat, never a silent no-op.
