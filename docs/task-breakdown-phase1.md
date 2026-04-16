# Phase 1 Task Breakdown — Skeleton + Bootstrap (with Pre-flight Spikes)

Source material: `plans/swift-rewrite.md`, `design-requirements.md`, `features.md`.

This doc breaks Phase 1 and the three pre-flight spikes into executable tasks. The spikes run **in parallel** with Phase 1 tasks — they exist to kill unknowns early, not to block the skeleton. If a spike fails, switch that area to the documented fallback before the dependent Phase 3 / 4 work begins.

**Exit criterion for Phase 1:** the app launches on an Apple Silicon Mac running macOS 14+, opens an empty Settings scene, tracks first-run state, reports per-capability permission status honestly, can be relaunched in-place after an Accessibility grant, and exposes a callable function that fetches the Parakeet model into the cache. Phase 2 (Audio + Transcription) can begin.

---

## Legend

- **Touches** — new files / directories the task creates (or existing files it edits). Paths are relative to the repo root; Swift sources live under `Sources/` (configured as an Xcode synchronized folder group), resources under `Resources/`.
- **Depends on** — other tasks in this doc that must land first.
- **Acceptance** — observable pass/fail. Every criterion must be demonstrated manually on a real Apple Silicon Mac.

---

# Pre-flight Spikes

Each spike is a **disposable standalone Xcode project** (not code in the main target). Keep them in `spikes/<name>/` at repo root. When a spike passes, delete the project and fold the key insight into Phase 1 / 3 / 4 as a one-paragraph note in `docs/plans/swift-rewrite.md` under "Decisions confirmed by spikes." If a spike fails, adopt the documented fallback and note the decision in the same place.

---

## Spike S1 — Delivery matrix (synthetic ⌘V reliability)

**Why:** Highest-risk unknown in the plan. If synthetic `⌘V` fails in common apps, the entire "paste at cursor" value prop collapses to clipboard-only mode.

**Touches**
- `spikes/delivery-matrix/` — standalone SwiftUI mini-app
  - `DeliverySpikeApp.swift` — one window, a text field, a "Paste sample text to frontmost app in 3 s" button
  - `Paster.swift` — the clipboard sandwich + `CGEventPost` of `⌘V`
  - `README.md` — matrix of tested apps and observed results
- `spikes/delivery-matrix/Jot-DeliverySpike.entitlements` — `com.apple.security.app-sandbox = false`, hardened runtime on

**Depends on**
- Accessibility (post-events) permission granted for the spike binary. Spike README documents the grant step.

**Acceptance**
1. Build the spike, grant Accessibility, run it.
2. For each target app, focus a text input in the target, trigger the spike's 3-second countdown, switch focus to the target, and observe whether the canned string appears.
3. Target apps, minimum:
   - **AppKit native:** Notes, Mail, Safari address bar, TextEdit
   - **Electron:** Slack, Discord, VS Code, Notion, Obsidian
   - **Chromium:** Chrome address bar + a `<textarea>`, Arc, Brave
   - **Terminal:** Terminal.app, iTerm2
   - **Secure-field-heavy:** 1Password (main window search, not the password field itself — verify graceful failure there)
4. Record pass / fail / quirks per app in `README.md`.
5. Decision gate:
   - **Pass** (≥ 90 % of target apps accept the paste) → proceed with synthetic `⌘V` as the primary delivery path for Phase 3.
   - **Fail** → switch Phase 3 Delivery layer's default to clipboard-only + optional AX text-insertion for AX-compliant fields; add a toast surfacing the fallback.

---

## Spike S2 — KeyboardShortcuts dynamic enable/disable

**Why:** Cancel (`Esc`) must only be claimed while a recording is in flight. If `KeyboardShortcuts.disable(.cancelRecording)` doesn't actually release the OS-level registration, every `Esc` press gets swallowed from other apps — an immediate deal-breaker.

**Touches**
- `spikes/hotkey-toggle/` — standalone SwiftUI mini-app
  - `HotkeySpikeApp.swift` — one window, two toggles ("Enable Toggle Recording", "Enable Cancel"), a log view that prints every firing
  - `Shortcuts.swift` — declares `.toggleRecording` (⌥Space) and `.cancelRecording` (Esc)
  - `Package.resolved` — pinned `sindresorhus/KeyboardShortcuts`
  - `README.md` — observations

**Depends on**
- Input Monitoring granted for the spike binary. README documents.

**Acceptance**
1. Toggle off `.cancelRecording` in the spike. Focus another app (e.g. Safari). Press `Esc`. Expected: Safari handles it normally (e.g. blurs the address bar).
2. Toggle on `.cancelRecording`. Press `Esc` from Safari. Expected: spike log prints the firing; Safari does **not** see the key.
3. Toggle off again. Confirm Safari handles `Esc` normally a second time.
4. Repeat 10x rapidly, toggling on/off, to rule out stuck registration.
5. Decision gate:
   - **Pass** → use `KeyboardShortcuts.disable/.enable` for the dynamic-Esc behavior in Phase 3.
   - **Fail** → implement ~50 lines of Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` wrapper under `Recording/Hotkeys/` in Phase 3 instead.

---

## Spike S3 — Overlay placement under the notch

**Why:** Dynamic Island-style presentation is a load-bearing part of the product requirements. Needs to handle notch / non-notch Macs and display hot-plug without the pill flying off-screen.

**Touches**
- `spikes/overlay-placement/` — standalone AppKit mini-app
  - `OverlayApp.swift` — no main window; creates one `NSPanel` with a pink debug rectangle sized to the notch footprint
  - `OverlayWindow.swift` — `NSPanel` subclass, `.screenSaver` level, `ignoresMouseEvents = true`, non-activating
  - `Placement.swift` — reads `NSScreen.main?.safeAreaInsets`, positions the panel under the notch on notch Macs, centered under menu bar on non-notch
  - `ScreenObserver.swift` — subscribes to `NSApplication.didChangeScreenParametersNotification`
  - `README.md` — hardware tested + observations

**Depends on**
- Access to at least one notch Mac (MacBook Pro 14"/16" M-series, MacBook Air M2+) and one non-notch Apple Silicon Mac (Mac mini + external display, or MacBook Air M1).

**Acceptance**
1. Launch on a notch Mac. Pink rectangle lands flush under the notch, stays pinned during mouse hover, is click-through.
2. Launch on a non-notch Mac. Pink rectangle is centered under the menu bar.
3. With an external display attached, drag focus between displays — panel re-anchors to the correct screen.
4. Unplug and re-plug the external display. Panel repositions correctly without a relaunch.
5. Toggle Retina scaling in System Settings → Displays. Panel geometry stays correct after the mode change.
6. Decision gate:
   - **Pass** → use `NSScreen.safeAreaInsets` + screen-change observer in Phase 4 Overlay layer.
   - **Fail** (inset unstable, or hot-plug breaks positioning) → anchor to menu-bar center with a fixed y-offset in v1; revisit notch-hugging post-v1. Skip multi-display polish.

---

# Phase 1 Tasks

Single executable target `Jot` in a new `Jot.xcodeproj` at repo root. Swift 5.9+, macOS deployment target 14.0, `arm64` only.

---

## Task T1 — Xcode project scaffold

**Touches**
- `Jot.xcodeproj/` — new project, target `Jot` (macOS App, SwiftUI lifecycle)
- `Sources/App/JotApp.swift` — `@main` struct, empty `Scene`
- `Sources/App/AppDelegate.swift` — `NSApplicationDelegate` stub, hooked via `@NSApplicationDelegateAdaptor`
- `Resources/Info.plist` — deployment target 14.0, `LSApplicationCategoryType = public.app-category.productivity`, `LSUIElement = NO` for v1 (main window exists)
- `Resources/Jot.entitlements` — hardened runtime; sandbox **off** in v1 (synthetic `⌘V` + AX API need non-sandboxed)
- `Resources/Assets.xcassets` — empty, with AccentColor + AppIcon placeholders
- `.gitignore` — `xcuserdata/`, `*.xcworkspace/xcuserdata/`, `DerivedData/`, `.DS_Store`
- Empty layer folders matching `CLAUDE.md` map (`App/`, `MenuBar/`, `Overlay/`, `Recording/`, `Transcription/`, `Delivery/`, `Library/`, `Settings/`, `SetupWizard/`, `Sounds/`)

**Depends on:** none.

**Acceptance**
1. `xcodebuild -scheme Jot -destination 'platform=macOS,arch=arm64' build` succeeds from a clean checkout.
2. Running the app from Xcode shows a blank window with the app name in the menu bar. `⌘Q` quits cleanly.
3. `file build/Build/Products/Debug/Jot.app/Contents/MacOS/Jot` reports an arm64 Mach-O binary.
4. `git status` is clean after build (no untracked Xcode artefacts).

---

## Task T2 — SPM dependencies

**Touches**
- `Jot.xcodeproj/project.pbxproj` — add Swift Package dependencies:
  - `FluidInference/FluidAudio` — pinned to the latest release compatible with Parakeet TDT 0.6B v3
  - `sindresorhus/KeyboardShortcuts` — pinned to latest
- `Sources/App/JotApp.swift` — add `import FluidAudio` and `import KeyboardShortcuts` to force resolution at build time (remove once real call sites exist)

**Depends on:** T1.

**Acceptance**
1. `xcodebuild -resolvePackageDependencies` completes without warnings.
2. `Package.resolved` is committed and pins specific versions.
3. Both imports compile in `JotApp.swift`.

---

## Task T3 — AppDelegate + single-instance enforcement

**Touches**
- `Sources/App/AppDelegate.swift`
  - `applicationDidFinishLaunching(_:)` — wire the permissions service (T5), first-run state (T4), and model-download utility (T7)
  - `applicationShouldHandleReopen(_:hasVisibleWindows:)` — show main window if hidden
  - Single-instance check using a distributed notification: on launch, post `com.jot.ping`; if another instance responds within 200 ms, foreground the existing one and `NSApp.terminate(nil)` the new one
- `Sources/App/SingleInstance.swift` — isolates the ping/response logic
- `Sources/App/JotApp.swift` — `@NSApplicationDelegateAdaptor(AppDelegate.self)`

**Depends on:** T1.

**Acceptance**
1. Launch Jot. Launch it a second time from Finder. Expected: first instance comes to front; no second window appears; second process exits.
2. `ps aux | grep Jot` shows exactly one `Jot.app` process.
3. Closing the main window does not terminate the process (deferred `NSStatusItem` lands in Phase 4 — for now confirm the process stays alive via Activity Monitor).

---

## Task T4 — First-run detection

**Touches**
- `Sources/App/FirstRunState.swift`
  - `@MainActor final class FirstRunState: ObservableObject`
  - `@AppStorage("jot.setupComplete") var setupComplete: Bool = false`
  - `var isFirstLaunch: Bool { !setupComplete }`
  - `func markComplete()` — flips the flag
- `Sources/App/JotApp.swift` — injects `FirstRunState` into the environment

**Depends on:** T1.

**Acceptance**
1. Fresh install (delete the app's `UserDefaults` domain): `FirstRunState.isFirstLaunch == true`.
2. Call `markComplete()`, relaunch: `isFirstLaunch == false`.
3. `defaults delete com.jot.Jot jot.setupComplete` resets to first-launch on next start.
4. The flag is addressable from both SwiftUI (`@EnvironmentObject`) and AppKit code paths (`FirstRunState.shared` singleton wrapper is acceptable if documented).

---

## Task T5 — Permissions service (four capabilities)

Four distinct capabilities, each with its own status enum and refresh path. Do **not** merge them into a single boolean — the revocation flows differ.

**Touches**
- `Sources/Permissions/Capability.swift` — `enum Capability: CaseIterable { case microphone, inputMonitoring, accessibilityPostEvents, accessibilityFullAX }`
- `Sources/Permissions/PermissionStatus.swift` — `enum PermissionStatus { case notDetermined, denied, granted, requiresRelaunch }`
- `Sources/Permissions/PermissionsService.swift` — `@MainActor final class PermissionsService: ObservableObject`
  - `@Published var statuses: [Capability: PermissionStatus]`
  - `func refreshAll()` — synchronously polls each capability
  - `func request(_ capability: Capability) async` — triggers the grant flow where one exists (mic only; others open System Settings)
  - Per-capability implementations:
    - Mic: `AVCaptureDevice.authorizationStatus(for: .audio)` + `AVCaptureDevice.requestAccess(for: .audio)`
    - Input Monitoring: `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` — note: a denied-then-granted flip requires relaunch; service must report `.requiresRelaunch` when the last-observed status was denied
    - Accessibility post-events: `AXIsProcessTrustedWithOptions(nil)` — same relaunch caveat
    - Accessibility full AX trust: reuses the post-events check — treat as the same capability in v1 but keep the enum slot for future AX text-insertion polish
  - `NSWorkspace.shared.notificationCenter` observer for `didActivateApplicationNotification` — triggers `refreshAll()` when the user returns from System Settings
- `Sources/Permissions/SystemSettingsLinks.swift` — deep links (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` etc.)
- `Resources/Info.plist` — `NSMicrophoneUsageDescription = "Jot records audio from your microphone to transcribe it into text on your Mac."`

**Depends on:** T1, T3.

**Acceptance**
1. On a Mac where all four are not yet granted, `refreshAll()` reports `.notDetermined` / `.denied` honestly.
2. Call `await service.request(.microphone)` — the system prompt appears. Granting updates `statuses[.microphone]` to `.granted` without a relaunch.
3. Open System Settings → Privacy → Input Monitoring, toggle on "Jot". Return to the app. Service reports `.requiresRelaunch` (because the process is still running with the old decision). Restart. Service reports `.granted`.
4. Same sequence for Accessibility → post-events.
5. Revoke mic permission in System Settings while the app runs; on reactivation, `statuses[.microphone]` flips to `.denied` without needing a relaunch.
6. Unit test: mock each underlying API and confirm the status enum mapping matches the table above.

---

## Task T6 — Accessibility restart helper

**Why:** Input Monitoring and Accessibility grants are **not detected by the running process** — the kernel only re-checks on new binaries. Users need a frictionless "I granted it, now restart" path. Mirror the existing Open Voice wizard pattern.

**Touches**
- `Sources/App/RestartHelper.swift`
  - `func relaunchApp()` — spawn a short-lived helper (or use `NSWorkspace.shared.open(URL(fileURLWithPath: Bundle.main.bundlePath))` after a 500 ms `atexit`-scheduled delay), then `NSApp.terminate(nil)`
  - Verified idiom: use `Process` to run `/usr/bin/open -n -W <bundle> &` and exit; documented in the file header

**Depends on:** T1.

**Acceptance**
1. Call `RestartHelper.relaunchApp()` from a debug menu item. The app quits and reopens within ~1 second. The new process shows a new PID in Activity Monitor.
2. Permissions granted between quit and relaunch are observable in the new process on first `PermissionsService.refreshAll()`.
3. No zombie processes — `ps aux | grep Jot` shows exactly one `Jot.app` after the relaunch.
4. The user's main window position / frontmost state is preserved (best-effort; document any regression).

---

## Task T7 — Parakeet model-download utility

Function only — no wizard UI yet. Phase 2 (Transcription) and Phase 5 (Wizard UI) both call into this.

**Touches**
- `Sources/Transcription/ModelCache.swift`
  - Cache root: `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, ...).appendingPathComponent("Jot/Models/Parakeet")`
  - `func isModelCached(_ id: ParakeetModelID) -> Bool`
  - `func cacheURL(for id: ParakeetModelID) -> URL`
- `Sources/Transcription/ParakeetModelID.swift` — enum of supported model IDs, starting with `tdt_0_6b_v3`
- `Sources/Transcription/ModelDownloader.swift`
  - `func downloadIfMissing(_ id: ParakeetModelID, progress: @escaping (Double) -> Void) async throws`
  - Uses FluidAudio's model-download API if available, else a plain `URLSession.shared.download(for:delegate:)` against the FluidAudio mirror URL documented in `plans/swift-rewrite.md`
  - Resumability is **not** required in v1 (future work; see plan)
- `Sources/Transcription/ModelDownloadError.swift` — `enum`: `networkUnreachable`, `diskFull`, `corrupted`, `unknown(Error)`

**Depends on:** T1, T2 (FluidAudio SPM dependency).

**Acceptance**
1. On a fresh install, `await ModelDownloader().downloadIfMissing(.tdt_0_6b_v3) { progress in … }` fetches the model. Progress callback fires at least 10 times between 0.0 and 1.0.
2. After the first call, `ModelCache.isModelCached(.tdt_0_6b_v3)` returns `true`.
3. A second call with the model already cached returns immediately (no network I/O — verified with Little Snitch or `nettop`).
4. Simulated network failure (toggle Wi-Fi off mid-download) surfaces `ModelDownloadError.networkUnreachable`; the cache is left without a half-written file.
5. Deleting the cache directory and re-calling fetches again.

---

## Task T8 — Empty Settings scene

Placeholder only — real panes land in Phase 4. Phase 1 just needs the scene to exist so `⌘,` has somewhere to go.

**Touches**
- `Sources/Settings/SettingsScene.swift` — `struct JotSettings: Scene` with a single "Settings coming soon" `VStack`
- `Sources/App/JotApp.swift` — composes `WindowGroup { ContentView() }` + `JotSettings()`
- `Sources/App/ContentView.swift` — empty placeholder view; Phase 4 replaces this with the real sidebar + content shell

**Depends on:** T1.

**Acceptance**
1. `⌘,` from anywhere in the app opens the Settings window.
2. Settings window has the native macOS Settings.app look — fixed size, no toolbar clutter.
3. Closing the Settings window does not quit the app.

---

## Task T9 — Debug-only bootstrap smoke screen

Optional but useful for validating the services wired in T3–T7 before Phase 2. Can be deleted once Phase 4 UI lands.

**Touches**
- `Sources/App/ContentView.swift` — adds a `#if DEBUG` section that lists:
  - Each `Capability` and its current `PermissionStatus`
  - "Request mic", "Open Input Monitoring settings", "Open Accessibility settings" buttons
  - "Relaunch app" button (calls `RestartHelper`)
  - "Download Parakeet model" button with a progress bar bound to `ModelDownloader`
  - First-run flag value + "Reset first-run" button

**Depends on:** T4, T5, T6, T7, T8.

**Acceptance**
1. Running the app in Debug shows the smoke screen.
2. All five controls operate as expected (matches the acceptance steps of T4–T7 individually).
3. `#if !DEBUG` compile produces no references to this view — verify with `xcodebuild -configuration Release build`.

---

# Dependency graph

```
T1 (project scaffold)
 ├── T2 (SPM deps) ────────────────┐
 ├── T3 (AppDelegate + single-inst)│
 ├── T4 (first-run) ──────────────┐│
 ├── T5 (permissions service) ───┐││
 ├── T6 (restart helper) ────────┤││
 ├── T7 (model download) ◀── T2 ─┘│
 └── T8 (settings scene) ─────────┘│
                                   │
        T9 (debug smoke screen) ◀──┘ (needs T4, T5, T6, T7, T8)

Spikes S1, S2, S3 — independent, run in parallel with T1–T9.
```

**Suggested execution order for a single implementer:** T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9. Spikes in a separate branch in parallel.

**Suggested execution for two implementers:** one takes T1 → T2 → T3 → T8, the other takes T4 → T5 → T6 → T7 after T1 lands. Spikes can be picked up by whoever finishes their T-track first.

---

# Phase 1 done-definition

All of the following must be true on an Apple Silicon Mac running macOS 14.0+:

- The app builds, runs, and quits cleanly.
- Only one instance can run at a time.
- First-run state is readable and writable, survives restart.
- All four capabilities report honest, per-capability status and update when the user returns from System Settings.
- The restart helper relaunches the app after an Accessibility grant without leaving zombies.
- The Parakeet model can be fetched into `~/Library/Application Support/Jot/Models/Parakeet/` by calling a single async function, with a progress callback.
- The Settings scene opens with `⌘,`.
- The three spikes have landed a pass / fail decision, with the fallback adopted in plan text where needed.

**Next phase:** Phase 2 (Audio + Transcription) — `AVAudioEngine` capture, FluidAudio wrapper loaded against the model T7 downloaded, end-to-end "record 3 seconds → print transcript."
