# S3 — overlay-placement

Disposable AppKit mini-app that parks a pink `NSPanel` pill at `.screenSaver` level under the notch (or centered under the menu bar on non-notch Macs). Repositions on `didChangeScreenParameters`.

## Build & run

```bash
cd Spikes/overlay-placement
swift build -c release
swift run -c release OverlayPlacement
```

The app runs as `.accessory` (no dock icon, no main window). You'll see a pink pill near the top center of the current screen. Click-through (doesn't steal mouse events) because `ignoresMouseEvents = true`.

## Usage

1. Launch on a notch Mac → pink pill flush under the notch footprint.
2. Launch on a non-notch Mac → pink pill centered under the menu bar.
3. With an external display attached, move mouse to the other display → pill follows cursor's screen on the next re-place (plug/unplug or resolution change triggers `didChangeScreenParameters`).
4. Unplug/replug external display → pill re-anchors cleanly, no relaunch needed.
5. Toggle Retina scaling in System Settings → Displays → pill geometry correct after mode change.

Logs are emitted via `NSLog` for each placement event — visible in Console.app or via `log stream --predicate 'processImagePath CONTAINS[c] "OverlayPlacement"'`.

Quit with `killall OverlayPlacement` (no UI to terminate; `.accessory` apps have no dock-click quit).

## Fallback if it fails

If `safeAreaInsets.top` is unstable or hot-plug breaks placement, anchor under menu-bar center with a fixed y-offset. Skip multi-display polish for v1.
