# Jot vX.Y.Z

> One-line summary of this release.

## What's new

- …

## Fixes

- …

## Install

1. Download `Jot-X.Y.Z-<shortsha>.dmg` below.
2. Open the DMG and drag **Jot.app** into **Applications**.
3. On first launch macOS will warn about "unidentified developer" (Jot is ad-hoc signed in v1).
   Right-click **Jot.app** → **Open** → **Open** to bypass, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Jot.app
   ```

## Verify download

```sh
shasum -a 256 Jot-X.Y.Z-<shortsha>.dmg
# expected: <paste SHA-256 from the build-dmg.sh footer>
```

## Known limitations

- Apple Silicon, macOS 14+ only.
- Developer ID signing + notarization is coming — see `docs/plans/apple-signing.md`.
