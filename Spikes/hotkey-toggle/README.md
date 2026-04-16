# S2 — hotkey-toggle

Disposable SwiftUI mini-app using `sindresorhus/KeyboardShortcuts` 2.4.0 to verify that dynamic `enable()` / `disable()` releases the OS-level registration (so `Esc` is returned to other apps when cancel isn't armed).

## Build & run

```bash
cd Spikes/hotkey-toggle
swift build -c release
swift run -c release HotkeyToggle
```

## Usage

1. Launch the app. It installs handlers for two shortcuts: `.toggleRecording` (⌥Space) and `.cancelRecording` (Esc).
2. Input Monitoring prompt may fire on first launch. Grant in System Settings → Privacy & Security → Input Monitoring.
3. Manually test:
   - Toggle `cancelRecording` OFF. Focus Safari, press Esc → Safari sees Esc (address bar blurs / overlay closes). Log does NOT print FIRED.
   - Toggle `cancelRecording` ON. Focus Safari, press Esc → log prints FIRED. Safari does NOT receive Esc.
   - Toggle off again — Safari receives Esc again.
   - Repeat rapidly 10× — registration must not stick.

Record outcomes in `docs/spike-results/S2-hotkey-toggle.md`.

## Fallback if it fails

If `disable()` doesn't actually release the key, fall back to Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` (documented in `docs/plans/swift-rewrite.md`).
