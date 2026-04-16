# S3 — overlay-placement

## Status: BUILT, PARTIALLY AGENT-VERIFIED, HUMAN-VERIFICATION-PENDING FOR NOTCH + HOT-PLUG

## What the spike is

A minimal AppKit executable (`Spikes/overlay-placement/`) that runs as `.accessory` (no dock icon, no main window), creates one `NSPanel`, and parks a pink opaque pill (~200×35) near the top-center of the current screen:

- `NSPanel` level: `.screenSaver`
- `ignoresMouseEvents = true`, non-activating, `canBecomeKey = false`
- `collectionBehavior` includes `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary`
- Placement logic (`Placement.swift`):
  - Reads `NSScreen.safeAreaInsets.top`.
  - If `top > 0` (notch present) → park flush under the notch.
  - Else → center under the menu bar (24 px offset).
- Observes `NSApplication.didChangeScreenParametersNotification` and re-runs placement on display hot-plug / resolution change.

## What I (agent) verified

- [x] Builds for arm64-macos14
  - Command: `cd Spikes/overlay-placement && swift build -c release`
  - Output: `Build complete! (1.00s)` after fixing a Swift 6 `@MainActor` isolation issue on `AppDelegate`.
  - `file .build/release/OverlayPlacement` → `Mach-O 64-bit executable arm64`
- [x] Launches without crashing AND actually exercised the placement code path end-to-end:
  - Ran the binary for ~2 s and observed `NSLog` output:
    ```
    [OverlayPlacement] placed on screen DELL U2520D inset.top=0.0 origin=(1180,1377)
    [OverlayPlacement] launched; 2 screen(s) detected
    ```
  - This confirms on the current machine: `NSScreen.main?.safeAreaInsets` reads cleanly (no crash), 2 screens are enumerated, and the non-notch fallback branch (`inset.top=0.0`) placed the panel under the menu bar on the Dell external.
- [x] Key code paths present:
  - `NSPanel` subclass at `.screenSaver` level: `OverlayWindow.swift:10–30`
  - `ignoresMouseEvents`, non-activating, etc.: `OverlayWindow.swift:15–27`
  - `safeAreaInsets.top` read + branching: `Placement.swift:12–24`
  - `didChangeScreenParameters` observer: `OverlayApp.swift:19–24`, `OverlayApp.swift:27–30`
  - Cursor-tracking currentScreen: `OverlayController.swift:27–33`

## What requires a human at the machine

I only exercised the non-notch fallback path on this specific hardware. The notch path (`topInset > 0`) is implemented but has not been observed firing, and I can't plug/unplug displays or read the screen with my eyes.

- [ ] **Step 1 — Notch Mac.** Run on a MacBook Pro 14"/16" (M1 Pro+) or MacBook Air M2+. `NSLog` should emit `inset.top=<nonzero>` and a y-coordinate placing the pill flush under the notch footprint. Visually confirm the pink pill sits under the notch, doesn't block mouse clicks, and doesn't hide on Cmd-Tab.
- [ ] **Step 2 — Non-notch Mac.** Run on a Mac mini or MacBook Air M1. `NSLog` should emit `inset.top=0.0` (already seen on Dell external) and the pink pill should be centered under the menu bar.
- [ ] **Step 3 — Multi-display, cursor follows.** With an external display attached, move the cursor between displays. Because the spike re-places only on `didChangeScreenParameters` (not on cursor motion), the pill stays on whichever screen was current at last-place time. This is acceptable for v1 — the main app will re-place on record-start. Confirm that when the screen parameters change (plug/unplug, scaling change), the pill repositions correctly without a relaunch.
- [ ] **Step 4 — Unplug / replug.** Unplug external display. Expect `NSLog` line from the screen-change observer; pill re-anchors on the remaining screen cleanly. Replug — re-anchors again.
- [ ] **Step 5 — Retina scaling.** System Settings → Displays → toggle scaled resolution. Screen-change observer should fire; pill geometry should remain correct (no half-pixel artefacts, no off-screen placement).
- [ ] **Decision gate:**
  - **PASS** (notch placement visually correct on notch Mac, hot-plug re-places cleanly) → use `NSScreen.safeAreaInsets` + screen-change observer in Phase 4 Overlay layer.
  - **FAIL** (insets unstable, hot-plug drops placement) → anchor to menu-bar center with a fixed y-offset in v1. Skip multi-display polish.

## How to run

```bash
cd Spikes/overlay-placement
swift build -c release
swift run -c release OverlayPlacement
```

Quit with `killall OverlayPlacement` (app is `.accessory`, no UI to terminate).

## If the spike fails

See fallback in `docs/plans/swift-rewrite.md`: park under the menu bar at a fixed y-offset, skip multi-display polish for v1.
