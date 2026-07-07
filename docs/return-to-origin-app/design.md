# Return to the app you started dictating in (opt-in)

**Status:** design — **reviewed** (independent adversarial pass integrated below). **Blocked on a runtime spike (§8) before implementation.**
**Owner:** driven from a Reddit r/SideProject request ("make it an option to return to the app when dictation finishes").
**Default:** OFF. This is opt-in; the current behavior is unchanged for everyone who doesn't enable it.

> **Gate:** do not implement until the §8 activation spike proves Jot can deterministically bring another app frontmost on the macOS 15+ floor. If it can't, this feature cannot exist and should be closed. Two design changes below (Origin travels with the transcript; notification-based wait) are adopted regardless of the spike outcome.

---

## 1. What we're building

A single Settings toggle in **General → (advanced) delivery knobs**:

> **Return to the app I started in** — When on, the transcript is delivered back to the app that was frontmost when you began dictating, and that app is refocused — even if you clicked into another app while speaking. When off (default), the transcript pastes wherever your cursor is now.

Storage key: `jot.returnToOriginApp` (`Bool`, default `false`), mirroring the existing `jot.autoPressEnter` delivery-toggle pattern.

---

## 2. Why this is subtle on macOS (the crux finding)

An investigation of the focus/activation path (cited below) established that **on macOS the frontmost app never changes during a normal hotkey dictation**:

- The overlay pill is a genuine non-activating panel — `styleMask [.borderless, .nonactivatingPanel]`, `canBecomeKey == false`, shown only via `orderFrontRegardless()` (`Sources/Overlay/OverlayPanel.swift:98,169`, `OverlayWindowController.swift:177`). It never takes key/main.
- Jot never calls `NSApp.activate` / `makeKey` anywhere in record → stop → paste.
- Delivery is a **system-wide synthetic ⌘V** to whatever app is frontmost (`Sources/Delivery/ClipboardSandwich.swift:122`, `.cgSessionEventTap`). It is not targeted at an app or element.
- There is **no** focus capture and **no** focus restoration in the codebase today (grep for `frontmostApplication` / `NSRunningApplication` / `AXUIElement` in the dictation path returns nothing; the only `NSRunningApplication` use is the single-instance relauncher, `Sources/App/SingleInstance.swift:50`).

**Consequence:** the literal request ("return to the previous app after dictation") is a *no-op* for the standard flow — you never left. The feature is only meaningful when the paste target and the origin app differ, i.e. the user **switched apps mid-dictation** (or started while Jot's own window was frontmost). So we deliberately define the feature as "**deliver back to the origin app**", which is the coherent, useful reading — not a literal focus-restore-after-paste (which would strand text in the app you navigated to).

This is why the toggle is off by default and framed as an explicit alternative delivery mode, not a bug fix.

---

## 3. Behavior spec

Let **Origin** = the app frontmost at the instant dictation starts. Let **Current** = the app frontmost at delivery time.

**OFF (default, today's behavior):** paste into Current (system-wide ⌘V). No capture, no activation.

**ON:**
1. At dictation **start**, capture Origin (`NSWorkspace.shared.frontmostApplication`). If Origin is Jot itself, or nil, store nothing (feature no-ops this session).
2. At **delivery**, if a valid Origin was captured AND Origin ≠ Current AND Origin is still running:
   - Re-activate Origin and **wait** (bounded) until it is actually frontmost.
   - Then run the existing clipboard sandwich (⌘V, optional Return, clipboard restore) — so the paste lands in Origin.
3. If Origin == Current (user never switched) → activation is skipped; behaves exactly like OFF (safe no-op).
4. If Origin quit / can't be activated within the timeout → fall back to today's behavior (paste into Current) rather than dropping the transcript. Never lose text.

Ordering invariant: **activate Origin BEFORE posting ⌘V.** The paste is un-targeted, so it must be posted only once Origin owns keyboard focus, or the text lands in the wrong app.

Out of scope (v1): restoring the exact *text field / caret* inside Origin (AX element focus). We only bring the app frontmost and rely on the app restoring its own last-focused field. Capturing/re-setting a specific `AXUIElement` focus is fragile and permissioned; noted as a future enhancement.

---

## 4. Options considered

**Opt-A — Restore focus AFTER paste (literal "return to previous app").** Paste into Current, then reactivate Origin. *Rejected:* if the user switched to app B, the transcript lands in B but focus jumps to A — text and focus diverge, which is more confusing than today. Only sensible when Origin == Current, where it's a no-op anyway.

**Opt-B — Reactivate Origin BEFORE paste (deliver to origin). [SELECTED]** The transcript always goes home; focus ends there too. Matches the request's intent ("return to where you started") and is internally consistent. Cost: introduces a cross-app activation + a timing wait into the delivery path.

**Opt-C — Capture and restore the exact AX focused element.** Most precise (returns to the exact caret), but requires AX focus-setting, is fragile across apps, and adds permission surface. *Deferred* to a possible v2; not needed to satisfy the request.

---

## 5. Implementation plan (pseudocode only)

**Revised after review.** Two structural changes vs. the first draft, both adopted regardless of the spike:
- **Origin travels WITH the transcript**, not as mutable state on `RecorderController`. This eliminates an entire class of stale-reference bugs (see review C2 / §7 R4): the captured app is bound to the specific transcript instance that flows `runFlow → lastResult → handleDeliveryBridge → deliver`, so a session that never reaches `performSandwich` (in-app-stop `skipNextPaste`, clipboard-only, empty-text) can never leak its Origin into a *later* `pasteLast()`.
- **Wait on `NSWorkspace.didActivateApplicationNotification`** (already used at `PermissionsService.swift:48`), not a `frontmostApplication` busy-poll — the notification fires when activation *completes*, closing the ⌘V race a poll leaves open.

### 5.1 Capture Origin at trigger time, attach to the result
Capture at the **trigger instant** in `toggle()` (before the `await pipeline.startRecording` at `RecorderController.swift:244`), NOT at `:251` — sampling after the audio-engine spin-up await can capture the wrong app if the user clicked away during startup (review R-a). Gate on `autoPaste && returnToOriginApp` (the toggle is `.disabled(!autoPaste)`, but the stored bool persists, so guard both — review C2).

```
// RecorderController.toggle() / runFlow entry, at trigger time:
let origin: NSRunningApplication? =
    (autoPaste && returnToOriginApp)
      ? NSWorkspace.shared.frontmostApplication.flatMap {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0   // never capture Jot itself
        }
      : nil

// carry `origin` on the in-flight session and stamp it onto the produced result:
//   TranscribeOutput / lastResult gains an `originApp: NSRunningApplication?` field
//   (it already carries text + metadata through runFlow → lastResult).
```

No new `RecorderController` mutable property, no clear-on-cancel bookkeeping — the ref lives and dies with its transcript.

### 5.2 Reactivate Origin before paste (AX route primary)
The paste lives in `DeliveryService.performSandwich` (`Sources/Delivery/DeliveryService.swift:148`). The captured `originApp` arrives as a parameter on the `deliver(...)` call (threaded from `handleDeliveryBridge`), read into a local — never re-read from shared state.

```
func performSandwich(text, originApp: NSRunningApplication?) async {
    ...
    if let origin = originApp,                     // already gated at capture; nil ⇒ today's path
       !origin.isTerminated,
       NSWorkspace.shared.frontmostApplication?.processIdentifier != origin.processIdentifier,
       isOnCurrentSpace(origin) {                  // HARD guard — never yank across Spaces (R3)
        raiseFrontmost(origin)                     // AX route (see §8) with activate() fallback
        await awaitActivation(origin, timeout: 600ms)   // didActivateApplicationNotification + settle
    }
    try pasteboard.postCommandV()                  // lands in Origin, or Current on timeout/fallback
    if autoPressEnter { ... postReturn() }
    ...                                            // clipboard restore (unchanged, anchored to paste)
}

// raiseFrontmost(origin): primary = AX — AXUIElementCreateApplication(pid) then
//   set kAXFrontmostAttribute = true (or kAXRaiseAction on main window); fallback =
//   origin.activate(options: []). Which one actually works is the §8 spike.
// awaitActivation: register for NSWorkspace.shared.notificationCenter
//   .didActivateApplicationNotification filtered to origin.pid, + a small settle delay,
//   bounded by timeout. On timeout: proceed anyway — NEVER drop text.
```

`raiseFrontmost` + `awaitActivation` are the two genuinely new mechanisms; both must be bounded and must never block delivery indefinitely.

### 5.3 Settings toggle
`Sources/Settings/GeneralPane.swift`, in `dictationDeliverySections` (`:676-727`), a 4th row after "Press Return after pasting" (`:690`):

```
@AppStorage("jot.returnToOriginApp") private var returnToOriginApp = false   // near :42

HStack {
    Toggle("Return to the app I started in", isOn: $returnToOriginApp)
        .disabled(!autoPaste)     // only meaningful when auto-paste delivers
        .help("Deliver the transcript back to the app that was frontmost when you started dictating, even if you switched apps while speaking.")
    Spacer()
    InfoPopoverButton(
        title: "Return to the app I started in",
        body: "When on, Jot remembers the app you were in when you started dictating and pastes the transcript back there — refocusing it — even if you clicked into another app while speaking. When off, the transcript pastes wherever your cursor is now.",
        helpAnchor: "dictation")   // reuse existing deep-linkable slug
}
```

### 5.4 Required supporting edits (ship checklist — minimal set)
- `docs/features.md` — one bullet under "Output — Paste & Clipboard" (`:115-123`).
- `Sources/Help/HelpInfraTests.swift` — add `("GeneralPane.returnToOriginApp", "dictation")` to `InfoCircleAnchorRegistry.entries` (`:427-476`) for **completeness/hygiene**. (Correction from review: this is NOT required to keep the release gate green — `InfoCircleAnchorTests` only validates that already-registered entries resolve to deep-linkable slugs; it does not scan source for unregistered popovers. Reusing the existing `"dictation"` slug passes regardless. Add the line anyway so the registry stays a complete inventory.)
- (Optional) `Sources/Help/Basics/BasicsContent.swift` — a SubRow under the `"dictation"` hero for discoverability; if added, confirm the help-content token budget check still passes.

**No** new: hotkey/ShortcutNames, pipeline/PillState case, menu-bar item, setup-wizard step, permission, or migration (absent bool key reads as `false`).

**Explicitly OUT of scope (no interaction — confirmed by review):**
- **Rewrite flows** (`RewriteController.pasteReplacement` → its own `postCommandV`, `Sources/Rewrite/RewriteController.swift:746`) do NOT route through `DeliveryService.performSandwich`, so return-to-origin never applies. Correct: rewrite operates on the current app's selection in place.
- **Ask Jot voice input** (`Sources/AskJot/ChatbotVoiceInput.swift:245`) drives `pipeline.startRecording` directly, bypasses `runFlow`/capture, and delivers into its own field. No capture, no activation. Correct.

---

## 6. Blast radius

Small and contained:

| Area | Change | Risk |
|---|---|---|
| `RecorderController` | +1 property, capture at `:251`, clear on terminal paths | low — MainActor, additive |
| `DeliveryService` | +1 `@AppStorage`, activation + bounded wait before ⌘V | **medium** — new timing + cross-app activation in the paste path |
| `GeneralPane` | +1 toggle row + info popover | trivial |
| `HelpInfraTests` | +1 registry line | trivial (keeps release gate green) |
| `docs/features.md` | +1 bullet | none |

Everything is gated behind an off-by-default toggle, so with the flag off the delivery path is byte-for-byte today's behavior. The only code that runs for existing users is the `if returnToOriginApp` guard evaluating to false.

---

## 7. Risks & their status after review

**R1 — Cross-app activation may be restricted (THE make-or-break unknown). → OPEN, gated by §8 spike.** On macOS 14+ the activation model is cooperative and `.activateIgnoringOtherApps` is deprecated; `NSRunningApplication.activate(options:[])` from a background app raising a *third* app is best-effort and the least reliable primitive. Jot is **non-sandboxed** (`Resources/Jot.entitlements:5`) and **AX-trusted** (`AXIsProcessTrusted()` via `PermissionsService.swift:101,129`), so the deterministic route is AX: `AXUIElementCreateApplication(pid)` → `kAXFrontmostAttribute = true` (or `kAXRaiseAction`). Design now specifies AX-primary + `activate()` fallback. **Feasibility must be proven by the §8 spike before any build. If neither reliably raises another app, the feature is closed.**

**R2 — ⌘V race. → RESOLVED in design.** Replaced the `frontmostApplication` busy-poll (which flips before the target window is key-ready) with `didActivateApplicationNotification` + settle delay (already-used API, `PermissionsService.swift:48`). Review confirmed the 350 ms clipboard-restore defer and auto-Enter are anchored to the paste, so the pre-paste activation delay does not desequence them.

**R3 — Spaces / full-screen. → HARD GUARD in v1** (was an open question). `performSandwich` only activates Origin if `isOnCurrentSpace(origin)`; never yank the user to another Space/full-screen app to deliver text. Cross-Space origin ⇒ fall back to today's behavior (paste into Current).

**R4 — Stale/mis-delivered Origin (was "app quit"; review found worse). → RESOLVED by the pass-through design (§5.1).** Because Origin travels with the transcript instead of persisting on `RecorderController`, the leak paths the review found — `skipNextPaste` (`AppDelegate.swift:405`), clipboard-only (`DeliveryService.swift:92`), empty-text (`:87`) — can no longer strand a stale Origin for a later `pasteLast()` to fire text into the wrong app. `isTerminated` check + timeout fallback still cover a quit origin. This was the review's most serious finding (silent data-misdelivery) and the pass-through is its structural fix.

**R5 — Reentrancy during the ≤600 ms wait. → MITIGATED.** Origin read into a local param, not shared state, so an overlapping second dictation can't clobber the in-flight one's Origin. Overlapping `performSandwich` on the shared pasteboard is a pre-existing hazard the wait widens; serialize delivery or accept (pre-existing).

**R6 — auto-Enter / Transform. → OK.** `postReturn()` fires in Origin (correct). Transform tail delays delivery; capture is at trigger time so it's unaffected.

**R7 — Copy framing. → REQUIRED.** Because ON contradicts the default "paste where your cursor is" philosophy, the toggle + popover copy must make the two modes unmistakable so an enabling user isn't surprised that mid-dictation app switches are ignored.

---

## 8. Prerequisite: activation spike (build gate)

**One question, answered empirically before writing any feature code:** from a background, non-frontmost, AX-trusted, non-sandboxed Jot, can we *deterministically* bring a different running app frontmost on the macOS 15+ floor?

Spike protocol:
1. Small harness (or a throwaway DEBUG hook) that, from Jot while another app is frontmost, attempts to raise a chosen target app by (a) the **AX route** — `AXUIElementCreateApplication(pid)`, set `kAXFrontmostAttribute = true`, and separately `kAXRaiseAction` on the main window — and (b) `NSRunningApplication.activate(options: [])`.
2. Observe via `didActivateApplicationNotification` whether the target actually became frontmost, and measure latency (feeds the §5.2 timeout).
3. Test the real scenario: user dictates in App A, clicks into App B, stop → does the transcript land in A with A focused?
4. Per project rule, **do not claim it works without observing the actual cross-app activation** (and a real paste landing in Origin).

Outcomes:
- **AX route works** → build as designed (AX primary).
- **Only `activate()` works, flakily** → build behind a clear "best-effort" caveat, or hold.
- **Neither reliably works** → close the feature; document that macOS won't allow it. Fall back to messaging the requester that macOS already keeps you in your app for the normal flow.

Est. spike: ~half a day. Feature build (if green): ~1 day (small surface, per §6).
