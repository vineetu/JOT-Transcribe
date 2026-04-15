# Apple Code Signing & Notarization

## Problem
When users download the Open Voice DMG and open it, macOS Gatekeeper shows "unidentified developer" warning or blocks it entirely. This is because the app is ad-hoc signed (`signingIdentity: "-"` in `tauri.conf.json`).

## Background
macOS requires two things for a clean install experience:
1. **Code signing** — a Developer ID certificate signs the binary
2. **Notarization** — Apple scans the app and issues a "ticket" that's stapled to the DMG

Without both, Gatekeeper blocks the app. Users must manually right-click → Open or run `xattr -d com.apple.quarantine`.

## Current State
- `src-tauri/tauri.conf.json` line 23: `"signingIdentity": "-"` (ad-hoc)
- `src-tauri/entitlements.plist`: microphone + audio-input entitlements only
- No GitHub Actions CI/CD workflow exists
- Bundle identifier: `com.openvoice.app`
- Tauri's DMG bundler already supports `--codesign` and `--notarize` flags

## Requirements
1. Apple Developer Program membership ($99/year, individual account)
2. Developer ID Application certificate (NOT App Store distribution cert)
3. App-specific password for notarytool
4. Keychain profile configured on build machine

## Implementation Plan

### Phase 1: Apple Developer Setup
1. Enroll at https://developer.apple.com/programs/ ($99/year, individual)
   - Timeline: usually same-day activation, up to 48h worst case
2. Create "Developer ID Application" certificate in Certificates, Identifiers & Profiles
3. Download and install certificate in Keychain Access
4. Create app-specific password at https://appleid.apple.com → Sign-In & Security → App-Specific Passwords
5. Store notary credentials in keychain:
   ```bash
   xcrun notarytool store-credentials "open-voice-notary" \
     --apple-id "YOUR_APPLE_ID" \
     --team-id "YOUR_TEAM_ID" \
     --password "YOUR_APP_SPECIFIC_PASSWORD"
   ```

### Phase 2: Configure Tauri for Signing
1. Update `src-tauri/tauri.conf.json`:
   ```json
   "macOS": {
     "entitlements": "entitlements.plist",
     "hardenedRuntime": true,
     "minimumSystemVersion": "10.15",
     "signingIdentity": "Developer ID Application: Your Name (TEAM_ID)"
   }
   ```
2. Build with `bun tauri build` — Tauri auto-signs with the configured identity
3. Notarize the DMG:
   ```bash
   xcrun notarytool submit "src-tauri/target/release/bundle/dmg/Open Voice_7.11.0_aarch64.dmg" \
     --keychain-profile "open-voice-notary" --wait
   xcrun stapler staple "src-tauri/target/release/bundle/dmg/Open Voice_7.11.0_aarch64.dmg"
   ```

### Phase 3: GitHub Actions (Future)
Create `.github/workflows/release.yml`:
1. Trigger on version tag push
2. Store certificate as base64 in GitHub Secrets (`APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`)
3. Store notary credentials (`APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`)
4. Build → sign → notarize → create GitHub release with signed DMG

## Timeline Per Release (After Setup)
- Build: ~5 min
- Signing: automatic during build
- Notarization: 5-15 min (first time may be longer)
- Staple + upload: 1 min

## Key Files
- `src-tauri/tauri.conf.json` — signingIdentity config
- `src-tauri/entitlements.plist` — app capabilities
- `.github/workflows/release.yml` — CI/CD (to be created)
