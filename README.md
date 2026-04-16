# Jot

> Speak, and it's written.

Native macOS dictation utility. Press a hotkey, speak, and text appears at your cursor — all on-device. Successor to [Open Voice](https://github.sie.sony.com/vsriram/openvoice).

## Stack

Swift · SwiftUI + AppKit where needed · AVFoundation for capture · Core ML / Apple Neural Engine for Parakeet inference · `NSStatusItem` for the menu bar · `NSPanel` for the status indicator.

## References

- `docs/design-requirements.md` — product requirements. The source of truth for what Jot must do and how it should feel.
- `docs/features.md` — feature inventory carried forward from Open Voice for parity tracking.

## Distribution

### How to ship a release

Jot v1 ships as an **ad-hoc signed** `.dmg` uploaded to a GitHub Release. Developer ID signing + notarization is a later phase — see [`docs/plans/apple-signing.md`](docs/plans/apple-signing.md).

**1. Set the version.**

The script reads `MARKETING_VERSION` from the Xcode target (bump it in the Jot target's Build Settings), or you can override per-build:

```sh
VERSION=0.2.0 ./scripts/build-dmg.sh
```

**2. Build the DMG.**

```sh
./scripts/build-dmg.sh
```

The script archives Release (`arm64`), exports the `.app`, re-applies an ad-hoc hardened-runtime signature with the bundled entitlements, and produces:

```
dist/Jot-<version>-<shortsha>.dmg
```

The DMG has a drag-to-Applications layout: `Jot.app` next to an `Applications` symlink. The final footer prints path, size, and SHA-256 — copy the SHA into your release notes so downloaders can verify.

Expected caveat: `spctl` will reject the app (Gatekeeper won't trust an ad-hoc signature). The script logs this as a warning and continues — it is **not** a build failure in v1.

**3. Publish.**

Drag both artifacts onto the GitHub Release page for the tag:

- `Jot-<version>-<shortsha>.dmg`
- A plain-text file with the SHA-256 (e.g. `Jot-<version>-<shortsha>.dmg.sha256`)

Use [`scripts/release-notes-template.md`](scripts/release-notes-template.md) as the starting point for the release body.

No CI, no automation, no auto-updater in v1 — users update by redownloading.

### What the user sees on first launch

Because the DMG is ad-hoc signed and not notarized, macOS Gatekeeper will refuse the first launch with an "unidentified developer" / "Jot is damaged" dialog. Two ways around it:

- **Right-click → Open → Open** (once). macOS then remembers the approval.
- Or strip the quarantine xattr from the terminal:
  ```sh
  xattr -dr com.apple.quarantine /Applications/Jot.app
  ```

This friction goes away once we ship a Developer ID-signed, notarized build — tracked in [`docs/plans/apple-signing.md`](docs/plans/apple-signing.md).
