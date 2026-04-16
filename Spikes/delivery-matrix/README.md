# S1 — delivery-matrix

Disposable SwiftUI mini-app for testing the clipboard-sandwich + synthetic `⌘V` delivery path.

## Build & run

```bash
cd Spikes/delivery-matrix
swift build -c release
swift run -c release DeliveryMatrix
```

## Usage

1. Launch the app.
2. Grant Accessibility for the built binary: System Settings → Privacy & Security → Accessibility → add `.build/release/DeliveryMatrix`.
3. Edit the sample text if desired.
4. Click "Paste to frontmost app in 3 s" and switch focus to the target app within the countdown.
5. Read the log for the post result. Verify the paste visually in the target.

## Target matrix (check each manually)

- AppKit: Notes, Mail, Safari address bar, TextEdit
- Electron: Slack, Discord, VS Code, Notion, Obsidian
- Chromium: Chrome, Arc, Brave (address bar + textarea)
- Terminal: Terminal.app, iTerm2
- Secure field (expected graceful fail): 1Password search field

Record outcomes in `docs/spike-results/S1-delivery-matrix.md`.

## Notes

- SwiftPM executable has no entitlements file or bundle structure, so hardened runtime / sandbox flags don't apply. For this spike, that's fine — Accessibility trust is what gates `CGEventPost`.
- Paster.swift implements the sandwich. It restores the pasteboard 350 ms after posting, which is enough time for typical targets to consume the paste.
