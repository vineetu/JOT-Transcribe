# Setup Wizard — Shortcut Step Redesign

> **Status:** Design exploration (no code yet)
> **Scope:** `Sources/SetupWizard/Steps/TestStep.swift` and its peer assets only
> **Owner's framing:** "Much better than before but things are all over the place."
> **Out of scope:** Settings → Shortcuts pane (separate v1.13 backlog item, already redesigned in code under `Sources/Settings/Shortcuts/`)

---

## 1 · Problem statement

The Setup Wizard's hotkey step (`TestStep`) is the single page where a brand-new Jot user must (a) understand that Jot is driven by a global hotkey, (b) accept or change the default binding, and (c) prove end-to-end that pressing the binding actually starts a recording, ends it, and produces a transcript. In v1.9 the binding ("Shortcuts" step) and the live test ("Test" step) were two adjacent pages. Owners observed users picking a binding on page A, hitting Continue, then being confused when page B asked them to press it — because the two surfaces did not share an obvious causal frame. In v1.11+ the two were merged into a single `TestStep` view. That merge fixed the "users never tested" failure mode but introduced a new one: the merged page now stacks four distinct concerns vertically (trigger-type segmented control, binding editor, remediation banners, big hotkey-press card, optional timeout hint, optional transcript block) and the user has no clear "what do I look at first" anchor.

The owner's phrase — "things are all over the place" — translated into investigable claims:

1. The user's eye is meant to land on the giant hotkey chip ("⇪") in the centre of the page. But the page leads with a segmented Picker ("Trigger type — Single key | Chord") that is conceptually meaningless to a first-time user.
2. State changes (binding edited → big chip refreshes; permission denied → banner appears; hotkey fires → chip turns red; transcribe finishes → green checkmark inline below) are all *correct* but distributed across four sub-regions; the user has no single locus of "what is the system doing right now."
3. The "trigger type" idea — choose between a chord (e.g. `⌥Space`) and a single key (e.g. Caps Lock) — is a power-user concept that Jot has elevated to its first decision in onboarding. It would not exist in this position if the wizard had been designed top-down for newcomers.
4. The wizard treats fresh installs and v1.12 upgraders identically (both see the same merged step). Upgraders may already have a working chord binding that they don't want disrupted.
5. The "your hotkey didn't fire after 12 seconds" remediation pattern is correct but reactive — by the time the user has waited 12 s they have already failed to press the key, often because the binding was Caps Lock and they didn't realise their machine was now in Caps Lock toggle mode.
6. Settings → Shortcuts already shipped a polished one-row-per-action layout in v1.13 (under `Sources/Settings/Shortcuts/`). The wizard step diverges from that idiom in materially every respect — chip style, conflict surfacing, trigger-type plumbing — so a user moving between Settings and the wizard sees two different mental models for the same data.

This document audits the current step in detail, surveys six comparable Mac apps, sketches four redesign directions, recommends one, and walks through every meaningful state and edge case. **No Swift is written here.**

---

## 2 · Current state audit

### 2.1 File map

| File | Lines | Role |
|---|---|---|
| `Sources/SetupWizard/Steps/TestStep.swift` | 486 | The merged "bind + live-test" wizard step |
| `Sources/SetupWizard/WizardStep.swift` | 87 | `WizardStepID.test` enum case + `WizardStepChrome` |
| `Sources/Recording/Hotkeys/ShortcutNames.swift` | 57 | Canonical `KeyboardShortcuts.Name`s incl. `.toggleRecording` with `⌥Space` chord default |
| `Sources/Recording/Hotkeys/SingleKey.swift` | 258 | `SingleKey` enum (`.capsLock`, `.fn`, `.rightOption`, …), `TriggerType`, `Action`, `TriggerMode` |
| `Sources/Recording/Hotkeys/SingleKeyMigration.swift` | 223 | First-launch migration, `effectiveBinding`, `effectiveTriggerType`, `storedSingleKey` |
| `Sources/Recording/Hotkeys/SingleKeyHotkey.swift` | 144 | NSEvent `flagsChanged` listener that powers single-key bindings |
| `Sources/Recording/Hotkeys/HotkeyRouter.swift` | 564 | `setToggleRecordingOverride` / `clearToggleRecordingOverride` route the wizard's press into a closure instead of `recorder.toggle()` |
| `Sources/Settings/Shortcuts/ShortcutSingleKeyChip.swift` | 78 | Reusable single-key Menu chip — **not yet used by TestStep** |
| `Sources/Settings/Shortcuts/ShortcutChordChip.swift` | 33 | Reusable chord recorder chip — **not yet used by TestStep** |
| `Sources/Settings/Shortcuts/ShortcutBadge.swift` | 36 | "When this fires" pill (green / purple / gray) — **not yet used by TestStep** |
| `Sources/Settings/Shortcuts/ShortcutsRowModel.swift` | 185 | View model for the Settings rows; defines `Group` + `FiringContext` |
| `Sources/Permissions/PermissionsService.swift` | (header excerpt only — `statuses[.inputMonitoring]`, `requiresRelaunch` semantics) |
| `Sources/Permissions/Capability.swift` | 8 | `microphone`, `inputMonitoring`, `accessibilityPostEvents`, `accessibilityFullAX` |

### 2.2 What the current TestStep renders, top-to-bottom

The body (TestStep.swift:68–93) is a `VStack(spacing: 16)` of six children:

1. **Title block** (lines 70–77)
   * `Text("Your dictation shortcut")` 22 pt semibold
   * Sub-copy: "Press your hotkey from any app to start and stop recording. Change it if you want, then test it below."
2. **Binding controls** (`bindingControls`, lines 116–156)
   * Segmented `Picker` labelled "Trigger type" with options `Single key` and `Chord`.
   * When `triggerType == .singleKey`: a labelless `Picker` of `[.none, .capsLock, .fn, .rightOption, .rightCommand, .rightShift, .rightControl]`. Max width 220 pt.
   * When `triggerType == .chord`: a `KeyboardShortcuts.Recorder(for: .toggleRecording)` with an `onChange` that bumps `bindingsRefreshToken`.
   * Sub-caption: "Change anytime in Settings → Shortcuts." 11 pt tertiary.
   * Container: 10 pt corner radius rounded rectangle, control background opacity 0.5, hairline border.
3. **Remediation banner** (`remediationBanner`, lines 176–208)
   * Conditional. Renders only when microphone is **not** granted OR the selected Parakeet model is not yet downloaded.
   * Orange warning icon + bold one-liner + a `controlSize(.small)` button back to the relevant earlier step (Permissions or Model).
4. **Hotkey card** (`hotkeyCard`, lines 213–246)
   * Centre-aligned `VStack(spacing: 14)`.
   * 28 pt rounded-display title showing `shortcutDisplay` (e.g. "⇪" or "⌥Space"). Background tint switches on phase: red while recording, accent-blue while transcribing, neutral otherwise.
   * Callout text under the chip: switches per phase. "Press it now to start recording." → "Listening… press the same hotkey to stop." → "Transcribing…" → "Press the hotkey again to run another test."
5. **Timeout hint** (`timeoutHint`, lines 298–321)
   * Conditional. Renders only when `showTimeoutHint == true && phase == .waitingForStart`.
   * Armed by `armTimeoutHintIfNeeded()` on appear — 12 second silent timer. Cancelled the moment any press fires.
   * Orange warning + paragraph about Input Monitoring + a "Go back to Permissions" button.
6. **Transcript block** (`transcriptBlock`, lines 326–381)
   * Switches on `phase`:
     - `.waitingForStart` / `.recording` → `EmptyView`
     - `.transcribing` → small spinner + "Transcribing…"
     - `.done` with empty transcript → "Didn't catch anything — try again and speak a little louder."
     - `.done` with non-empty transcript → green ✓ + "Your hotkey, mic, and model all work." + caption "YOU SAID" + the transcript in a tinted rounded box
     - `.failed` → red error text

### 2.3 State surfaces, mapped

| State | Source | Visible feedback |
|---|---|---|
| `phase: TestPhase` | local `@State` | colour of hotkey card + callout copy + transcript block |
| `transcript: String` | local `@State` | bottom transcript box (only when `.done`) |
| `errorMessage: String?` | local `@State` | red error in transcript block (only when `.failed`) |
| `hotkeyDidFire: Bool` | local `@State` | suppresses timeout hint after first fire |
| `showTimeoutHint: Bool` | local `@State` | conditional render of timeout hint |
| `bindingsRefreshToken: Int` | local `@State`, bumped from chord recorder `onChange` | forces `shortcutDisplay` re-evaluation |
| `toggleSingleKey: SingleKey` | `@AppStorage` `jot.hotkey.toggleRecording.singleKey` | drives chip + the single-key Picker selection |
| `toggleTriggerTypeRaw: String` | `@AppStorage` `jot.hotkey.toggleRecording.triggerType` | drives the segmented Picker selection |
| `PermissionsService.shared.statuses[.microphone]` | observed via `PermissionsService` singleton | banner #3 |
| `ModelCache.shared.isCached(selectedModel)` | observed | banner #3 |
| `PermissionsService.shared.statuses[.inputMonitoring]` | **not directly observed in TestStep** — only surfaced indirectly via the 12 s timeout hint | this is the user-experience bug |

### 2.4 Sequence (fresh-install user with default Caps Lock binding)

```
appear
  ├─ HotkeyRouter.setToggleRecordingOverride { handleHotkeyPress() }
  ├─ armTimeoutHintIfNeeded() → 12 s task scheduled
  └─ updateChrome() → coordinator footer enables "Continue"
user presses Caps Lock
  ├─ SingleKeyHotkey.handle() detects flag transition
  ├─ HotkeyRouter routes to override → handleHotkeyPress()
  ├─ phase = .recording, hotkeyDidFire = true, showTimeoutHint = false
  ├─ timeoutTask.cancel()
  ├─ chip turns red, callout becomes "Listening…"
  └─ Task: transcriber.ensureLoaded() + audioCapture.start()
user speaks "Hello world"
user presses Caps Lock again
  ├─ same routing path
  ├─ stopCaptureAndTranscribe() → phase = .transcribing
  ├─ chip turns accent blue, callout becomes "Transcribing…"
  └─ Task: capture.stop(); transcriber.transcribe(samples)
transcribe completes
  ├─ phase = .done; transcript = "Hello world"
  ├─ chip returns to neutral
  └─ transcript block renders ✓ + "YOU SAID" + box
user hits Continue → coordinator advances to .done
disappear
  └─ HotkeyRouter.clearToggleRecordingOverride()
```

### 2.5 Failure modes the current step handles

1. **Mic not granted** — top banner pre-empts the test; "Go back to Permissions" button.
2. **Model not downloaded** — top banner pre-empts the test; "Go back to Model" button.
3. **Input Monitoring not granted** — *not directly detected*. Surfaces only after the 12 s silent timer.
4. **Capture fails to start** (e.g. CoreAudio device disappeared) — `.failed` phase, red error text.
5. **Transcription fails** — `.failed` phase, red error text.
6. **User presses hotkey during transcribing** — no-op (`case .transcribing: break` at line 426).
7. **Empty transcript** — phase reaches `.done` with empty text → "Didn't catch anything — try again and speak a little louder."

### 2.6 Concrete UX critiques

**Critique 1 — Two pickers in a row before the user has even seen the hotkey.** The segmented "Trigger type" Picker plus the inner key Picker (or chord recorder) sit *above* the giant hotkey chip. A fresh-install user reading the page top-to-bottom encounters a choice ("Single key | Chord") before they have any reason to make it. The default trigger type for fresh installs is `.singleKey` with `.capsLock` (`SingleKeyMigration.runIfNeeded()` at SingleKeyMigration.swift:64–72), so the right behaviour is already pre-selected. Exposing the Picker as the first interactive control violates progressive disclosure.

**Critique 2 — "Trigger type" is not user language.** The segmented Picker label reads "Trigger type" with options "Single key" and "Chord." Neither label is teachable in this context. A first-time user does not know:
- That a chord is technically a key with modifiers (versus a single key without).
- That single-key bindings require `Accessibility` permission to listen to `flagsChanged`.
- That Caps Lock is a single key that turns into a recording indicator LED.
The label imposes a vocabulary lesson before the binding decision can be made.

**Critique 3 — The hotkey chip's role is ambiguous.** Visually the 28 pt rounded chip is the focal point of the page. Functionally it's a label — it displays `shortcutDisplay`, which is derived from whatever the binding controls above have set. A user who reads top-to-bottom never realises the chip is downstream of the Picker. A user who looks at the page in z-order (centre-first, peripherally) sees the chip and asks: "Is that what I press? Can I click it to change it?" The chip is non-interactive but it visually looks like the primary affordance.

**Critique 4 — The remediation banner for Input Monitoring is reactive.** Input Monitoring is the single most common reason a Jot hotkey fails to fire. Yet the page has no proactive surface for it — it appears only after a 12 s wall-clock silent timer. The wizard's Permissions step (PermissionsStep.swift:28–35) does request Input Monitoring upstream, but the user can defer that decision and return to it later. By the time they reach TestStep with Input Monitoring still un-granted, the wizard owes them a clear "this is why your press did nothing" surface from the moment they appear on the page, not 12 s later.

**Critique 5 — No first-vs-returning differentiation.** A v1.12 upgrader who has happily been using `⌥Space` for months arrives at TestStep and sees:
- "Trigger type: Chord" pre-selected
- The chord recorder showing `⌥Space`
- The big chip showing `⌥Space`
- No "you're already set up" affordance — they have to either press their hotkey or hit Continue.
For these users the wizard step is essentially a smoke test of their existing setup. The page does not acknowledge this; it presents the same instructional copy as for a fresh install.

**Critique 6 — Esc-to-cancel is invisible.** Jot's global `Esc` cancellation (HotkeyRouter.swift:96–107) becomes active the moment the wizard's recording starts. The page does not mention this. A user who panics mid-recording (e.g. "I started but I don't want to test now") has no documented escape.

**Critique 7 — Caps Lock toggling system Caps Lock state.** When a fresh install lands on Caps Lock as the default, the user's machine is now in a mode where pressing Caps Lock turns Caps Lock ON, then OFF (toggling the LED). Jot intercepts both edges as start/stop. But to the user, pressing Caps Lock just typed `HELLO WORLD` in any app behind the wizard. The page does not mention that Jot has redefined Caps Lock; the user discovers it by surprise.

**Critique 8 — Trigger-type plumbing is exposed identically to the Settings pane.** The shipped Settings → Shortcuts pane (v1.13) tucks the chord-vs-single-key choice behind a small `slider.horizontal.3` overflow menu on hover (ShortcutRowView.swift:117–134). The wizard exposes the same choice as a top-of-page segmented Picker. These two surfaces showing the same data with different prominence is the literal "things are all over the place" the owner felt.

**Critique 9 — The merge was right; the rendering is wrong.** The file header rationale (TestStep.swift:9–13) explains the merge: users were setting bindings on a separate Shortcuts page and not verifying them on the Test page. The merge fixes a real problem — but the solution co-located two concerns vertically without re-thinking layout. A horizontal split, a state-driven progressive disclosure, or a single primary affordance with editing tucked behind a secondary tap would have served the merged semantics better.

**Critique 10 — The transcript block is the only "victory" surface and it sits below the fold for many window sizes.** The "Your hotkey, mic, and model all work." green check is the moment the user knows they're done. It renders as a child of the 6-element VStack at the bottom of the page; for default wizard windows (~700 × 540 pt with chrome), the transcript block can sit just at or below the visible viewport, hidden behind the page's own scroll edge insets. The success moment shouldn't require a glance downward.

---

## 3 · External design research

I surveyed six comparable Mac apps' onboarding-hotkey or first-run binding flows. For each I describe how they handle (a) the binding affordance, (b) the live confirmation that the binding works, and (c) any permission gating, then call out one thing they do better than Jot's current step and one tradeoff.

### 3.1 Raycast

Raycast's hotkey is the centrepiece of the entire product — without a global hotkey there is no Raycast. The first-run flow opens with a full-bleed welcome screen, advances through one screen for "Pick your hotkey," and assumes Accessibility permission was already granted at install. The hotkey screen presents a single huge keycap mock (Raycast defaults to `⌥Space`) and a Raycast-styled "Record Hotkey" button. Pressing the button puts the chip into a live recording state — a soft red pulse + "Hold any combination" copy. The user holds their preferred modifiers + key; the chip updates live as keys are pressed. Releasing the last key commits the binding. There is no separate "test" page; the flow goes straight to "you're set, try summoning me with ⌥Space" with the chip pinned at the top as a constant reminder. If Accessibility is missing, Raycast shows an inline orange callout *under* the hotkey chip and a "Grant in System Settings" button.

- **Better than Jot:** the binding affordance is the focal point, not a downstream label. The Record button is unambiguously the thing-to-click.
- **Tradeoff Jot wouldn't want:** Raycast skips the live test step entirely. They rely on the next screen being a "use it now" demo. Jot needs a verified end-to-end test because the transcription path has more failure modes than Raycast's command palette.

### 3.2 Alfred

Alfred is the elder statesman. Their onboarding is workmanlike and rectangular — a multi-page modal with a sidebar of categories. The hotkey lives under "General → Alfred Hotkey." It's a click-to-record field labelled "Set as Alfred's hotkey." Clicking opens a recording state; the field shows ⌃ ⌥ ⌘ ⇧ + key as the user holds them; commit on release. There is no live test in onboarding — users just dismiss the prefs and try summoning Alfred with their chosen combo. If the combo conflicts with another app (Alfred has a built-in registry of common conflicts), the field tints orange and shows the conflict app's name underneath.

- **Better than Jot:** orange-tinted conflict warning is *part of the recorder field itself*, not a separate banner. Jot's chord recorder relies on the framework's deduping behaviour but doesn't visually warn at the recorder.
- **Tradeoff Jot wouldn't want:** no live test means a user can leave the prefs window believing they're set up when (in Jot's case) their model isn't downloaded or their mic isn't granted. The merge in TestStep is right for Jot's stack; copying Alfred's "just trust it" flow would regress.

### 3.3 Rectangle

Rectangle is a window manager. Each window-management action (snap left, snap right, maximise, …) has its own chord. Their onboarding does *not* ask the user to bind anything up front — it presents a default set ("Recommended" or "Spectacle" preset chosen on first launch) and a single-page checklist for granting Accessibility. The user is then dropped into the menu bar; the prefs window only opens if the user later wants to customise. Rectangle's prefs window itself is a long table of "Action → Shortcut" rows, each click-to-record.

- **Better than Jot:** does not force a binding decision in onboarding. New users get a sensible default and can change later. This is closer to what Jot already does for upgraders (the v1.12 user's chord stays put) but Jot still surfaces the Picker for fresh installs.
- **Tradeoff:** Rectangle's per-action binding density is high. Jot's wizard has ONE binding to nail down, not twenty — Rectangle's "punt the binding decision" pattern works because they hide it inside a long table the user opts into.

### 3.4 CleanShot X

CleanShot X's onboarding is a horizontal-scrolling wizard with five steps. Step 2 is "Set your screenshot shortcut" with three options pre-rendered as keycap chips (`⌘⇧4`, `⌘⇧5`, `Custom`). The user clicks one of the three; the Custom card opens an inline recorder. Crucially, the success path has a tiny animated "Try it now: Press ⌘⇧4" callout at the bottom that disappears the moment the system shortcut fires. There's no separate test page; the test is woven into the same card.

- **Better than Jot:** preset choices reduce decision friction. "Most users want one of these three" is honest and faster than forcing every user into a recorder.
- **Tradeoff:** the preset approach assumes there's a meaningful small set. For Jot's case the meaningful small set is Caps Lock vs `⌥Space` vs `Right Option`. A "pick one of three" pattern fits well; we'll borrow this in Direction C.

### 3.5 macOS System Settings → Keyboard → Shortcuts (Apple's own)

This is Apple's pattern and the one users already know. It's a sectioned list (Mission Control, Display, Spotlight, Input Sources, Screenshots, …). Each row is `Action title — current chord — toggle on/off`. Clicking the chord opens an inline recorder right where the chord was displayed. Pressing keys updates the chord; pressing Esc cancels; clicking out commits. There is no "test" affordance; Apple assumes the user will try it themselves. Conflicts are visible only through strikethrough on the affected row.

- **Better than Jot:** clicking the chord directly to re-record is the most intuitive affordance possible. Jot's wizard separates the chip (display-only) from the recorder field — the user can't click the chip to edit.
- **Tradeoff:** Apple's flat-list pattern doesn't scale to onboarding; it's a reference-pane idiom, not a guided-flow idiom. Borrow the "click chip to edit" gesture but keep the wizard's guided shape.

### 3.6 Loop (window manager) and Shortcat (keyboard navigator)

These are small indie apps that share a pattern: the binding *is* the onboarding. Loop's first launch shows a giant illustration of the loop gesture (hold a key, draw a direction) with the hotkey as the only interactive thing on the page. Press the recorder field, hold the key, release. The next page shows the user trying it live against a fake desktop. Shortcat is similar — first launch presents the trigger key (default `⌘⇧Space`) as the centrepiece with a "Press to test" affordance inline.

- **Better than Jot:** the binding step itself is the live-test surface. The user binds, then immediately tries it on the same page, with the same chip as the visual anchor.
- **Tradeoff:** these apps have lighter permission stories. Jot's mic + model + input-monitoring stack means we can't trust "press to test" without prior gating; the wizard has to keep its remediation banner.

### 3.7 Observation — what's Mac-native vs app-specific

| Pattern | Mac-native | App-specific |
|---|---|---|
| Click-to-record chord field with live keycap updates | Yes (Apple's recorder is the prior art) | – |
| Big keycap chip as a static display | – | Yes (Raycast / Loop / CleanShot) |
| Single-key (modifier-less) bindings as a first-class option | – | Yes (Jot, Karabiner; rare elsewhere) |
| Inline live test on the binding page | – | Yes (Loop, CleanShot, Shortcat) |
| 12 s silent-timer remediation | – | Yes (Jot's current TestStep is the unusual one here) |
| Conflict surfacing as part of the recorder | Yes (Apple's strikethrough), Yes (Alfred's orange tint) | – |
| Presets ("Pick from 3 defaults") | – | Yes (CleanShot, also Rectangle's snap preset) |
| Permission denial inline on the binding page | – | Yes (Raycast, CleanShot) |

The redesign should pull the click-to-record gesture from Apple, the focal-chip-with-live-edit pattern from Raycast / Loop, the proactive permission surface from Raycast / CleanShot, and the preset pattern from CleanShot. It should *drop* Jot's currently-loud trigger-type segmented Picker and the 12 s silent timer.

---

## 4 · Constraints — what the redesign cannot break

1. **Two trigger modes for `.toggleRecording`** — chord (e.g. `⌥Space`) and single key (`.capsLock`, `.fn`, `.rightOption`, `.rightCommand`, `.rightShift`, `.rightControl`). Storage shape is unchanged from v1.11+. The redesign may hide the choice from the primary surface but must keep the user able to switch.
2. **Only `.toggleRecording` is bound in the wizard.** `.pushToTalk` is unbound by default and a Settings-only concern. Other actions (`.pasteLastTranscription`, `.rewrite`, `.rewriteWithVoice`) ship with chord defaults and are not exposed in the wizard.
3. **Input Monitoring is the relevant permission.** A bound hotkey will not fire without it. The wizard step must surface this proactively, not reactively.
4. **Live press-to-test is required.** The wizard cannot ship without the user pressing their real hotkey and seeing a transcript come back, end-to-end. The merge rationale (TestStep.swift:5–13) is still correct.
5. **Existing v1.12 upgraders keep their binding.** `SingleKeyMigration.runIfNeeded()` leaves chord settings alone for `setupComplete == true`. The wizard step cannot disturb their binding unless they explicitly change it.
6. **Esc is the global cancel.** Pressing Esc mid-recording is the documented escape hatch and must be surfaced.
7. **`HotkeyRouter.setToggleRecordingOverride` is the wizard's plumbing.** The redesign uses the same routing — wizard appears, registers an override; wizard disappears, clears it. The production recorder pipeline never runs during the test.
8. **No new external dependencies.** Stay on KeyboardShortcuts + the existing `SingleKeyHotkey` listener.
9. **macOS Sonoma 14+, Apple Silicon only.** SwiftUI + AppKit interop allowed; `NSVisualEffectView` materials, SF Symbols, system semantic colors.
10. **No telemetry, no accounts.** All state is local to UserDefaults / `@AppStorage`.
11. **Wizard chrome.** The footer continues to render `WizardStepChrome` (Back / Continue / Skip). The redesign cannot move the binding affordance into the footer; it has to live in the step body.
12. **Harmony with Settings → Shortcuts.** The shipped Settings pane (v1.13) hides the trigger-type behind an overflow menu. The wizard should *not* be louder about trigger type than Settings is. They should feel like the same product.

---

## 5 · Design directions

Four directions, sketched as ASCII mockups. Each ends with a score grid + a brief commentary.

### Direction A — Two-pane "bind left, test right"

A single page split into a left column (binding controls) and a right column (the live-test surface). The two columns are sized roughly 40 / 60. The right column is visually muted until the binding is set, then comes "alive" with a coloured background and the press-to-test prompt.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Your dictation shortcut                                                  │
│  Pick a key (or combo) to start a recording. Test it on the right.        │
│                                                                            │
│  ┌────────────────── BIND ───────────────────┐  ┌───── TRY IT ──────────┐ │
│  │                                            │  │                       │ │
│  │  Press a key or combo to bind:             │  │      ╔════════╗      │ │
│  │  ┌────────────────────────────────────┐    │  │      ║   ⇪    ║      │ │
│  │  │  Caps Lock                ✎ edit  │    │  │      ╚════════╝      │ │
│  │  └────────────────────────────────────┘    │  │   Press it now to    │ │
│  │                                            │  │   start recording.    │ │
│  │  Recommended:                              │  │                       │ │
│  │  ⇪ Caps Lock                               │  │                       │ │
│  │  ⌥ Space                                   │  │                       │ │
│  │  ⌥ Right Option                            │  │                       │ │
│  │                                            │  │                       │ │
│  │  Advanced ▾                                │  │                       │ │
│  │   ◯ Use a custom chord                     │  │                       │ │
│  │   ◯ Use a single modifier (Fn, Right ⌘…)   │  │                       │ │
│  │                                            │  │                       │ │
│  └────────────────────────────────────────────┘  └───────────────────────┘ │
│                                                                            │
│  Tip: press Esc to cancel a recording at any time.                         │
└──────────────────────────────────────────────────────────────────────────┘
```

**Journey (fresh install):**
1. User lands on page. Binding is preset to Caps Lock (the migration default). The left column shows "Caps Lock" as the active binding plus three recommended chips below.
2. User looks left, sees Caps Lock is selected, then looks right and sees the press prompt.
3. User presses Caps Lock. The right column transitions to a recording state (chip turns red, callout becomes "Listening…").
4. User speaks, presses Caps Lock again, sees a green ✓ + transcript appear in the right column.
5. Continue advances.

**Pros:** clear spatial separation of "what's bound" vs "what happens when I press it." Multiple recommended chips reduce decision friction without forcing the trigger-type picker. The right-column-comes-alive transition gives the user a strong "I'm ready to test" signal.

**Cons:** two columns in a small wizard window (~700 pt wide) leaves each column cramped. The Advanced disclosure is awkward in narrow space — it expands the left column and pushes the right column out of alignment. Permission-denied state is hard to place in this layout: where does the orange banner go without breaking the symmetry?

**Score:**
| Axis | Score | Why |
|---|---|---|
| Cognitive load | 4/5 | Two columns is a learnable pattern; "bind left, test right" reads cleanly |
| State clarity | 4/5 | Right column transitions are very visible; left column states (selected / editing) less so |
| Single-key discoverability | 3/5 | "Caps Lock" sits in the recommended chips; Fn/Right⌘ live under Advanced — discoverable but two clicks deep |
| Permission-denied surface | 2/5 | No natural slot; would have to be a top banner that breaks symmetry |
| Harmony with v1.13 Settings | 3/5 | Different overall layout from the Settings rows; chip styles can be unified but the two-column flow is wizard-specific |
| Implementation cost | Moderate | New two-column container, recommended-chip component, Advanced disclosure |

### Direction B — Vertical step-list with progress dots

Single scroll, three numbered sub-steps inside the wizard step body. Sub-step dots show as filled / unfilled / current. Completed sub-steps collapse to a one-liner; the current sub-step expands.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Set your dictation shortcut                                              │
│  A quick three-step flow to bind your hotkey and prove it works.          │
│                                                                            │
│  ● 1. What's a hotkey?                                          collapse ▴ │
│      A global key (or combo) you press from any app to start and stop     │
│      dictation. Jot's default is Caps Lock — your keyboard's LED becomes  │
│      your recording indicator.                                            │
│                                                                            │
│  ● 2. Bind it                                                  collapse ▴ │
│      Current: ⇪ Caps Lock                                                 │
│      [ Change… ]                                                          │
│      Recommended alternatives: ⌥ Space   ⌥ Right Option                   │
│                                                                            │
│  ○ 3. Test it                                                             │
│      Press your hotkey now. You'll see "Listening…" then a transcript.    │
│      ┌─────────────┐                                                      │
│      │      ⇪      │   Press it now.                                      │
│      └─────────────┘                                                      │
│                                                                            │
│  Tip: press Esc to cancel a recording at any time.                         │
└──────────────────────────────────────────────────────────────────────────┘
```

**Journey (fresh install):**
1. User lands on page. All three steps visible. Step 1 ("What's a hotkey?") is current, expanded with a one-paragraph explainer. Step 2 is collapsed showing the current Caps Lock binding. Step 3 is unfilled.
2. User reads Step 1, hits "Got it" (or auto-collapses on scroll). Step 2 becomes current.
3. User accepts Caps Lock (or hits Change to swap). Step 2 marks complete. Step 3 becomes current.
4. User presses Caps Lock. The chip in step 3 lights up red. Test runs. Step 3 marks complete with green ✓ + transcript.
5. Continue advances.

**Pros:** very didactic — guides the user through the conceptual progression. Pre-checking step 2 for upgraders is trivial (their existing binding satisfies it). Permission-denied has an obvious slot: a fourth conditional row at the top.

**Cons:** the vertical stack of three sub-steps eats wizard window height. The "collapse on completion" pattern requires careful animation discipline or the page jumps. For Jot's audience — Mac power users — the Step 1 explainer can feel patronising; they already know what a hotkey is.

**Score:**
| Axis | Score | Why |
|---|---|---|
| Cognitive load | 3/5 | Lower per-step load but more total page elements |
| State clarity | 5/5 | Dots are unambiguous; collapsed steps are clearly "done" |
| Single-key discoverability | 3/5 | Caps Lock is the named default in Step 1's explainer; Fn/Right⌘ surface only via Change |
| Permission-denied surface | 4/5 | Natural slot as a pre-step "0. Grant permission" row |
| Harmony with v1.13 Settings | 2/5 | Settings is a flat row list; this is a numbered checklist — different idiom |
| Implementation cost | Moderate-High | Numbered step component, expand/collapse animation, three states per row |

### Direction C — Single big invitation with inferred trigger type

The page collapses to one giant interactive affordance: the bound-or-bind chip in the centre. If a binding exists (fresh install: Caps Lock; upgrader: their existing chord), the chip displays it and pulses gently with "Press it now." If the user clicks the chip, it enters recording mode and they can press a new key or combo — the trigger type is inferred from what they pressed (tap a single modifier → single-key; hold modifiers + key → chord). Recommended alternatives sit small below.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                            │
│         Press the key you want to use to start a recording                 │
│                                                                            │
│                                                                            │
│                       ╔════════════════════╗                              │
│                       ║                    ║                              │
│                       ║         ⇪          ║   ← click to change          │
│                       ║                    ║                              │
│                       ║      Caps Lock     ║                              │
│                       ╚════════════════════╝                              │
│                                                                            │
│                     Press it now to start recording.                       │
│                                                                            │
│         Or pick one of these:    ⌥ Space    ⌥ Right Option   …more         │
│                                                                            │
│  Tip: press Esc to cancel a recording at any time.                         │
└──────────────────────────────────────────────────────────────────────────┘
```

**Journey (fresh install):**
1. User lands. The chip shows "⇪ Caps Lock" and pulses softly. Sub-copy reads "Press it now to start recording."
2. User presses Caps Lock (or clicks the chip and presses a different key). If they pressed Caps Lock, recording starts (chip turns red, "Listening…"). If they pressed a different key/combo in *click-to-edit* mode, the chip re-binds — the next press starts recording.
3. Test plays out: speak, press again, see transcript.
4. Continue advances.

**Journey (upgrader):**
1. Chip shows their existing chord (e.g. `⌥ Space`). Sub-copy reads "Looks like you've already got a hotkey bound. Press it to make sure it still works."
2. User presses `⌥ Space`. Test runs. Green ✓. Continue.

**Inferred-trigger-type logic:**
- User clicks chip → chip enters "Press a key or combo" state.
- Key down with no modifiers, key up within ~250 ms → single-key binding for whichever side-modifier they pressed.
- Key down with modifiers held → chord binding (committed on release of all keys).
- Tap on Caps Lock → single-key Caps Lock binding.
- Tap on Fn → single-key Fn binding.
- Esc inside the recorder cancels the edit (does NOT bind Esc).

**Pros:** maximum focus — one chip is the page. The trigger-type Picker disappears entirely (inferred). Discoverability of single-key is high because Caps Lock IS the default for fresh installs. Upgraders see their existing chord with a welcoming "still works?" framing.

**Cons:** requires writing a custom NSEvent-driven recorder that handles both modes — KeyboardShortcuts' framework recorder rejects modifier-less inputs. (Note: this is also the deferred polish item under `features.shortcuts-pane-polish` in the backlog — building it for the wizard pulls that work forward.) Recommended chips below the main chip can confuse users into clicking them instead of pressing — needs careful copy.

**Score:**
| Axis | Score | Why |
|---|---|---|
| Cognitive load | 5/5 | One affordance, no Picker, no choice friction |
| State clarity | 5/5 | The chip IS the state: idle / pulsing / recording-edit / listening / transcribing / done |
| Single-key discoverability | 5/5 | Caps Lock is the literal default and the chip shows it as the headline |
| Permission-denied surface | 4/5 | A banner above the chip (or under the sub-copy) reads cleanly |
| Harmony with v1.13 Settings | 4/5 | Same chip-as-affordance gesture as Apple's Keyboard pane and the v1.14 polish target for Settings |
| Implementation cost | High | Custom NSEvent recorder, three recorder states, inferred-trigger-type logic |

### Direction D — Split back into two screens (revisit the merge)

Re-evaluate the merge. The merge rationale was "users were setting bindings on screen A and not testing on screen B." But the merge collapsed two simple screens into one busy one. An alternative fix: keep two screens, but make the relationship explicit — the test screen actively says "this is the binding you set on the previous screen; press it now" with the same chip, and the Continue button on the binding screen is disabled until the user has at least seen the test prompt on the next screen.

Persisting a "this binding has been tested" flag (`@AppStorage` bool keyed on the binding hash) would let the wizard remember that an upgrader has already tested their existing binding and short-circuit the test screen for them.

```
SCREEN A — Bind                              SCREEN B — Test
┌──────────────────────────────────┐         ┌──────────────────────────────────┐
│  Your dictation shortcut         │         │  Try your shortcut               │
│  Pick a key or combo.            │         │  Press the hotkey you just set.  │
│                                  │         │                                  │
│         ╔════════╗               │         │         ╔════════╗               │
│         ║   ⇪    ║  ← click to   │         │         ║   ⇪    ║               │
│         ╚════════╝     change    │         │         ╚════════╝               │
│                                  │         │     Press it now.                │
│  Recommended:                    │         │                                  │
│  ⇪ Caps Lock                     │         │  ✓ Already tested — skip ahead?  │
│  ⌥ Space                         │         │                                  │
│  ⌥ Right Option                  │         │                                  │
│                                  │         │                                  │
│  Continue →                      │         │  Continue →                      │
└──────────────────────────────────┘         └──────────────────────────────────┘
```

**Pros:** each screen has one job. The Bind screen is uncluttered; the Test screen is uncluttered. The "skip ahead" short-circuit for upgraders is honest. The two-screen flow is easier to instrument with "have they tested?" state.

**Cons:** the original merge problem returns in a softened form. Even with a "you must test before continuing" affordance, a user can hit Skip on the Test screen (if Skip is shown) and proceed without verifying. The wizard chrome's Skip button would need to be hidden on the Test screen, which is its own decision.

**Score:**
| Axis | Score | Why |
|---|---|---|
| Cognitive load | 4/5 | Per-screen low; total burden across two screens is similar to merged |
| State clarity | 4/5 | Per-screen states are clear; cross-screen continuity needs a tiny "you bound X on the previous screen" reminder |
| Single-key discoverability | 4/5 | Same recommended-chip pattern as A and C |
| Permission-denied surface | 5/5 | Each screen has its own banner slot; Test screen can hard-block if Input Monitoring is denied |
| Harmony with v1.13 Settings | 3/5 | Settings is a single pane; two-screen flow is wizard-specific but the Bind screen can mirror the Settings row idiom closely |
| Implementation cost | Moderate | Splits the existing TestStep back into two views; adds `bindingTestedHash` persistence for the short-circuit |

### Score summary

| Axis | A · Two-pane | B · Step list | C · Big invitation | D · Two screens |
|---|---|---|---|---|
| Cognitive load | 4 | 3 | 5 | 4 |
| State clarity | 4 | 5 | 5 | 4 |
| Single-key discoverability | 3 | 3 | 5 | 4 |
| Permission-denied surface | 2 | 4 | 4 | 5 |
| Harmony with v1.13 Settings | 3 | 2 | 4 | 3 |
| Implementation cost (rough) | Moderate | Moderate-High | High | Moderate |
| **Sum (higher = better, cost not summed)** | **16** | **17** | **23** | **20** |

---

## 6 · Recommendation — Direction C, with two borrowings

**Pick C (single big invitation, inferred trigger type) as the headline interaction**, and borrow two pieces from D:

1. **D's "you've already got a hotkey bound — make sure it still works" framing** for upgraders. Don't render the wizard step as if every user is a fresh install.
2. **D's persisted "this binding has been tested" flag** so future re-runs of the wizard (e.g. a v1.13 → v1.14 install that re-runs onboarding for a new permission) can short-circuit the test when the binding is unchanged from a previously-verified state.

The reasoning: Direction C scores highest on cognitive load, state clarity, and single-key discoverability — the three axes the owner's "all over the place" critique maps to most directly. Its implementation cost is the highest of the four (custom recorder), but that cost is amortised across the v1.14 Settings polish work (`features.shortcuts-pane-polish` already plans to build this same component). The wizard's `TestStep` is the highest-stakes surface for the binding decision; investing in a real recorder there and reusing it in Settings later is a net win.

### 6.1 Detailed mockup, all states

Below is the full state-by-state mockup of the recommended design. The page is wallpapered with the existing wizard's per-step illustration (the shipped Bold pass under `Setup Wizard Bold §4.8`), so the chip floats in the centre over a soft watercolor background. Padding is the wizard's standard `40 pt` horizontal × `32 pt` vertical.

#### State 0 — Fresh install, Caps Lock pre-bound, idle

```
                                                                          
        Your dictation shortcut                                            
        Press Caps Lock to start recording. Press it again to stop.        
                                                                          
                                                                          
                       ╔══════════════════════════╗                       
                       ║                          ║                       
                       ║            ⇪             ║                       
                       ║         Caps Lock        ║                       
                       ║                          ║                       
                       ╚══════════════════════════╝                       
                                                                          
                       (chip pulses softly every 1.8s)                    
                                                                          
                  Press it now to start recording.                        
                                                                          
                                                                          
          Want something else?   [⌥ Space]  [⌥ Right Option]  [Custom…]   
                                                                          
                                                                          
    ⓘ  Pressing Caps Lock now will start Jot — your keyboard's            
       Caps Lock light becomes your recording indicator while it's on.    
                                                                          
                                                                          
                              Tip: Esc cancels at any time.                
```

Notes:
- The big chip is the focal point. It displays the active binding using the same glyph style as the Settings chips.
- The pulse is a 1.8 s scale animation (1.00 → 1.04 → 1.00), opacity unchanged, respecting `accessibilityReduceMotion`.
- The three alternative chips below are clickable to switch binding in one click — no recorder open required for the "Pick one of these" path.
- The "Custom…" chip opens the recorder over the main chip.
- The ⓘ callout educates the Caps Lock behaviour BEFORE the user presses it, addressing Critique 7.
- Esc reminder lives in the footer, not buried.

#### State 1 — Upgrader, existing chord, idle

```
                                                                          
        Try your dictation shortcut                                        
        Looks like you've already got a hotkey — let's make sure it works.
                                                                          
                                                                          
                       ╔══════════════════════════╗                       
                       ║                          ║                       
                       ║         ⌥  Space         ║                       
                       ║                          ║                       
                       ╚══════════════════════════╝                       
                                                                          
                  Press it now to start recording.                        
                                                                          
                                                                          
          Or change to:   [⇪ Caps Lock]  [⌥ Right Option]  [Custom…]      
                                                                          
                                                                          
                              Tip: Esc cancels at any time.                
```

Notes:
- Title shifts to "Try your dictation shortcut" — acknowledges the user is not fresh.
- The "Or change to" alternatives include Caps Lock for users who want to migrate to the new default.
- The Caps Lock ⓘ callout is suppressed because they haven't picked Caps Lock.

#### State 2 — Binding-in-progress (custom recorder open)

```
                                                                          
        Your dictation shortcut                                            
        Press the keys you'd like to use.                                  
                                                                          
                                                                          
                       ╔══════════════════════════╗                       
                       ║                          ║                       
                       ║    Press a key or combo  ║                       
                       ║   ┌────────────────────┐ ║                       
                       ║   │ Listening for keys │ ║                       
                       ║   └────────────────────┘ ║                       
                       ║                          ║                       
                       ╚══════════════════════════╝                       
                                                                          
                  Press Esc to cancel, or click outside.                  
                                                                          
                                                                          
```

Notes:
- The chip fills with a faux-recorder mini-field. Pressed keys appear as keycaps inside it in real time.
- A 1.5 s idle timer commits the binding after the last key-up.
- Esc inside the recorder cancels the edit (does NOT bind to Esc).
- Click outside also cancels.

#### State 3 — Recording

```
                                                                          
        Your dictation shortcut                                            
        Caps Lock is on — Jot is listening.                                
                                                                          
                                                                          
                       ╔══════════════════════════╗  (chip is red-tinted) 
                       ║                          ║                       
                       ║            ⇪             ║                       
                       ║         Caps Lock        ║                       
                       ║                          ║                       
                       ╚══════════════════════════╝                       
                                                                          
                              ●  Listening…                                
                                                                          
                                                                          
                  Press Caps Lock again to stop.                          
                  Press Esc to cancel.                                    
                                                                          
                                                                          
```

Notes:
- Chip background tints red (same as current TestStep).
- Sub-copy moves from "Press it now" to "Caps Lock is on — Jot is listening."
- Pulsing red dot to the left of "Listening…" same as the existing overlay pill.
- Alternative chips and ⓘ callout collapse to keep the chip the focal point.

#### State 4 — Transcribing

```
                                                                          
        Your dictation shortcut                                            
        Got it. Working on the transcript…                                 
                                                                          
                                                                          
                       ╔══════════════════════════╗  (chip accent-tinted) 
                       ║            ⇪             ║                       
                       ║         Caps Lock        ║                       
                       ╚══════════════════════════╝                       
                                                                          
                              ↻  Transcribing…                            
                                                                          
                                                                          
```

#### State 5 — Test passed

```
                                                                          
        Your dictation shortcut                                            
        Your hotkey, mic, and model all work. Continue when ready.        
                                                                          
                                                                          
                       ╔══════════════════════════╗                       
                       ║            ⇪             ║                       
                       ║         Caps Lock        ║                       
                       ╚══════════════════════════╝                       
                                                                          
                              ✓  Test passed                              
                                                                          
                  YOU SAID                                                
                  ┌───────────────────────────────────────────────┐       
                  │  Hello world.                                 │       
                  └───────────────────────────────────────────────┘       
                                                                          
                  Press the hotkey again to run another test.             
                                                                          
                                                                          
```

Notes:
- Chip returns to neutral on success.
- Transcript renders directly under the chip, NOT below the fold.
- The "press again to re-test" affordance stays so users can repeat without manual recovery.
- A persistent "this binding has been tested" flag (`UserDefaults` key `jot.wizard.bindingTested.<hash>` where the hash is a stable digest of the binding's storage shape) flips to true.

#### State 6 — Test failed (capture error)

```
                                                                          
        Your dictation shortcut                                            
        Something went wrong starting the recording.                       
                                                                          
                                                                          
                       ╔══════════════════════════╗                       
                       ║            ⇪             ║                       
                       ║         Caps Lock        ║                       
                       ╚══════════════════════════╝                       
                                                                          
                              ⚠  Test failed                              
                  Error: Couldn't start recording — device busy.          
                                                                          
                  Press the hotkey to try again.                          
                                                                          
                                                                          
```

#### State 7 — Permission denied (Input Monitoring) — *proactive*, not 12 s wait

```
                                                                          
        Your dictation shortcut                                            
        Caps Lock is bound, but Jot can't hear it yet.                    
                                                                          
                                                                          
        ┌──────────────────────────────────────────────────────────────┐   
        │  ⚠  Input Monitoring is required                              │   
        │  macOS won't deliver global key presses to Jot until you      │   
        │  grant Input Monitoring.                                      │   
        │  [ Open System Settings ]    [ Go back to Permissions ]       │   
        └──────────────────────────────────────────────────────────────┘   
                                                                          
                       ╔══════════════════════════╗  (chip is muted gray) 
                       ║            ⇪             ║                       
                       ║         Caps Lock        ║                       
                       ╚══════════════════════════╝                       
                                                                          
                  Pressing your hotkey now won't work.                    
                                                                          
                                                                          
```

Notes:
- Banner pre-empts the press prompt — chip is greyed out, callout reads "won't work" not "press it now."
- Banner has two CTAs: "Open System Settings" (deep-links via `SystemSettingsLinks.swift`) and "Go back to Permissions" (returns to the wizard's Permissions step).
- Once permission flips to `.granted`, the banner disappears and the chip returns to its idle pulse.
- For `.requiresRelaunch` (the post-deny → grant flip), the banner adopts the same "Restart Jot" affordance as the PermissionsStep.

#### State 8 — Mic denied or model missing

Same banner pattern as State 7, but with mic / model copy. These banners already exist in the current TestStep's `remediationBanner` (TestStep.swift:176–208) — reuse the pattern, restructure the layout to live above the chip rather than between the binding controls and the chip.

### 6.2 Where the trigger-type concept goes

Hidden but reachable. The "Custom…" chip in the recommended-alternatives strip opens the recorder. The recorder infers trigger type from input:

- Single tap-and-release of a modifier (Caps Lock, Fn, Right Option, …) within ~250 ms → single-key binding.
- Hold one or more modifiers + non-modifier key, release → chord binding.
- The user does not see the words "trigger type" anywhere in the wizard.

Power users who want to switch trigger type without using the recorder gesture can do so in Settings → Shortcuts (where it's already a hover-revealed `slider.horizontal.3` menu per `ShortcutRowView.swift:117–134`).

### 6.3 Coordinator chrome — Continue rules

The wizard footer's Continue button is enabled whenever the binding is in a known-valid state (i.e. not "Not set"). Tested state is *not* a prerequisite for Continue — the user can advance without pressing — but the green ✓ + transcript provides positive reinforcement that they've completed the page. This preserves the current step's `canAdvance: true` chrome.

Optional refinement: if the user reaches Continue without having tested, render a small unobtrusive "Press your hotkey to make sure it works" reminder near the Continue button (footer-adjacent, not blocking). This is a polish item, not required for v1.

---

## 7 · Edge cases — explicit answers

### 7.1 Caps Lock toggling system Caps Lock state

The recommended design preempts this with the ⓘ callout under the chip in State 0: *"Pressing Caps Lock now will start Jot — your keyboard's Caps Lock light becomes your recording indicator while it's on."*

In addition, the wizard's test phase already runs against the override (HotkeyRouter.swift:235–248 + TestStep.swift:96–98), so pressing Caps Lock during the test does NOT type into the wizard window. But the user's *next* press in their day-to-day use will toggle Caps Lock on every Jot session. The Help → Basics deep-link from the chip's small "?" icon explains the long-form behaviour for users who want details.

### 7.2 Fn key conflicts with Apple's Globe / "show emoji" default

If the user picks Fn via "Custom…", the recorder commits but the wizard surfaces an inline orange tip under the chip: *"macOS may also use Fn for Globe / Emoji — check System Settings → Keyboard if it doesn't fire."* The tip uses the same `InfoPopoverButton` style as Settings rows. This is the same warning the v1.13 Settings pane shows when the user selects Fn (Settings/Shortcuts/ShortcutSingleKeyChip.swift is the canonical spot to mirror copy from).

### 7.3 User binds a conflicting chord another app already uses

The custom recorder leans on `KeyboardShortcuts.Recorder`'s built-in conflict logic for the chord path — it already detects system conflicts and refuses the binding. The wizard surfaces this as a transient red message under the chip: *"That combo is in use by another app. Try a different one."* For single-key bindings the conflict detection is internal to Jot (e.g. if the user picks Right Option as Toggle Recording while Push to Talk is also on Right Option in `@AppStorage`), surfaced by the existing `ShortcutsRow` conflict snapshot pattern.

### 7.4 User binds, then permission is denied

Two flavours:

- **Permission was denied before binding:** chip is greyed out, State 7 banner shows. The user can still rebind (clicking the alternative chips or Custom… works); pressing the hotkey just does nothing until permission is granted.
- **Permission was granted, user toggles it off mid-wizard:** `PermissionsService` poll catches the change; the page transitions to State 7. The binding persists; only the live-test surface is degraded.

In both cases the banner has an "Open System Settings" CTA. After grant, the user returns to the wizard and the banner self-clears.

### 7.5 User is happy with the default and wants to skip

The Continue button is always enabled when a binding is set (which is the default for both fresh installs and upgraders). No press is required. A user can hit Continue immediately. Encouragement to test is via the chip's visual pulse, not via blocked Continue.

### 7.6 User wants Push-to-Talk but the wizard only binds Toggle

The wizard does not expose PTT — keeping the wizard focused on the headline interaction. The Help tab's Basics → Dictation card explains PTT and links to Settings → Shortcuts. A small "More shortcut options →" link can sit in the wizard step's footer (under the Esc tip) to surface PTT discoverability without cluttering the main flow. This is a one-line affordance, not a multi-control panel.

### 7.7 The "what if they never test the hotkey" failure mode

The merge fix relied on co-locating bind + test. The recommended design preserves that by making the chip both the binding display AND the test target — the user cannot interact with one without seeing the other. The `bindingTested` flag (key `jot.wizard.bindingTested.<bindingHash>`) is persisted so future wizard re-runs can short-circuit. If the user advances without testing, no special state is recorded; they simply progress and we trust the steady-state flow (Permissions step → Test step) caught the most likely failure (Input Monitoring) via the proactive banner in State 7.

### 7.8 Hot-swappable binding mid-test

If the user is in State 3 (Recording) and clicks one of the alternative chips, two reasonable behaviours:

- **Option a:** Reject the swap with a tooltip "Stop the recording first." Force a clean state.
- **Option b:** Auto-stop the recording, swap binding, return to idle State 0.

Recommendation: Option b. The user's intent is clear (they want a different binding); forcing them to stop manually is friction. The implementation cancels the in-flight capture via the same path as Esc, then applies the new binding. The page returns to State 0 with the new chip.

### 7.9 Fresh-install user who's never seen a Mac shortcut concept

The chip's headline (e.g. "⇪ Caps Lock") plus the sub-copy ("Press it now to start recording.") plus the ⓘ callout about the LED indicator together carry the explainer load. The Help tab's Basics card is one click away via the wizard's persistent help affordance (sparkle icon in the shipped Bold pass) for users who want more.

---

## 8 · Open questions for the owner

Numbered, with proposed defaults. The defaults are what the design assumes if no clarification arrives.

1. **Should the recommended alternatives strip show 2 or 3 chips by default?**
   *Proposed default:* 3 chips (Caps Lock / ⌥ Space / ⌥ Right Option) + Custom. For upgraders the chip showing their current binding is suppressed from the strip.

2. **Does the wizard step rename to drop "Test" from the title?**
   *Proposed default:* The step header reads "Your dictation shortcut" (fresh) or "Try your dictation shortcut" (upgrader). The internal `WizardStepID.test` case name stays — it's a code-level identifier and the merge rationale comment already explains it.

3. **Does the persisted "this binding has been tested" flag actually need to ship in v1?**
   *Proposed default:* No. The chip pulses regardless; the test is always available; the green ✓ is feedback enough. Persistence is a v1.5 nice-to-have for cross-version wizard re-runs.

4. **The custom recorder — build it ourselves or wait for the `features.shortcuts-pane-polish` v1.14 work?**
   *Proposed default:* Build a wizard-specific lightweight version now. Share the `NSEvent` listener with the future Settings polish; ship the wizard step on the simpler version. If the polish item is already in flight, fold the work together.

5. **Should the "More shortcut options →" footer link to Help or to a wizard sub-step?**
   *Proposed default:* Help → Basics → Dictation. The wizard sub-step idea (per `features.wizard-prompts-panel-step` for prompts) is a different shape and would deserve its own design pass.

6. **The pulse animation — 1.8 s loop or quieter?**
   *Proposed default:* 1.8 s loop, 1.00 → 1.04 → 1.00 scale. Respects `accessibilityReduceMotion` (becomes a static chip).

7. **The Input Monitoring proactive banner — show whenever the permission is not `.granted`, or only after the user has been on the page for >2 s without pressing?**
   *Proposed default:* Show whenever not `.granted`, immediately. The 2-second delay is the kind of optimisation that hides a real problem.

8. **The "Already tested — skip ahead?" affordance from Direction D — do we want it in C?**
   *Proposed default:* No. The chip is fast enough to test that a skip affordance adds clutter for marginal benefit. Cross-version re-runs are rare.

9. **Should the chip be tappable to start recording (in addition to pressing the bound key)?**
   *Proposed default:* No. Tapping the chip opens the recorder (binding edit), per State 2. A button-driven test would defeat the merge rationale (proves only the in-app path, not the global tap + Input Monitoring path).

10. **Esc handling — bind to wizard window only, or trust the global cancel?**
    *Proposed default:* Trust the global cancel — `HotkeyRouter.cancelRecording` dynamically enables Esc whenever a cancellable pipeline runs. The wizard does NOT need its own Esc handling.

---

## 9 · Implementation plan (pseudocode only)

This section is intentionally non-Swift. Phases below are sized for an owner to read and reason about.

### Phase 1 — Reusable chip component (`WizardShortcutChip`)

Goal: build the focal chip + its states.

- New file: `Sources/SetupWizard/Steps/Components/WizardShortcutChip.swift` (concept only — Swift file not written here).
- Owns rendering for: idle (pulsing), recording-edit (custom recorder open), listening (red), transcribing (accent), passed (neutral + ✓ adjacent), failed (neutral + ⚠ adjacent).
- Inputs: a binding to the effective `SingleKeyMigration.EffectiveBinding` for `.toggleRecording`; a phase enum; closures for `onBeginEdit` and `onSwapTo(SingleKey | Chord)`.
- Outputs: visual.
- Sized to read from the existing `SingleKeyMigration` helpers — no new storage shape.

### Phase 2 — Lightweight inferred-trigger-type recorder

Goal: when the user taps the chip, capture either a single-key or chord binding without exposing trigger type as a control.

- New helper: `WizardInferredRecorder` — an `NSEvent` monitor that captures key down/up sequences and classifies them.
- Classification rules (encoded as text-only pseudocode):
  ```
  begin recording
    keyDown e:
      if e.key is a modifier-only key (CapsLock/Fn/RightOpt/RightCmd/RightShift/RightCtrl):
        store candidate single-key = e.key
        start 250ms tap-vs-hold timer
        on timer elapsed AND key still held: cancel candidate, switch to chord-mode
      else:
        store chord = (e.modifiers, e.charactersIgnoringModifiers)
    keyUp e:
      if candidate single-key matches AND tap-timer not elapsed:
        commit single-key binding
      else if chord stored:
        commit chord binding
    1.5s idle:
      if nothing committed: cancel recording (chip returns to idle)
  Esc:
    cancel recording (does NOT bind Esc)
  ```
- Writes through to `SingleKeyMigration.setTriggerType(...)` + `KeyboardShortcuts.setShortcut(...)` + `UserDefaults` single-key key, same as the existing Settings flow.

### Phase 3 — Rewrite `TestStep` body

Goal: replace the current top-to-bottom stack with a centred chip-driven layout.

- Drop:
  - `bindingControls` (segmented Picker + inner Picker / Recorder).
  - The 12-second silent-timer mechanism (replaced by State 7's proactive banner).
- Keep:
  - `setToggleRecordingOverride` / `clearToggleRecordingOverride` (the wizard's plumbing, lines 96–105).
  - `startCapture` / `stopCaptureAndTranscribe` (the test pipeline, lines 433–477).
  - `remediationBanner` (mic + model gating, lines 176–208) — restructure as the new banner above the chip.
- Add:
  - `WizardShortcutChip` + the recommended-alternatives strip.
  - Proactive `Input Monitoring` banner (observe `PermissionsService.shared.statuses[.inputMonitoring]` directly).
  - The Caps Lock LED ⓘ callout, conditional on the current binding being Caps Lock.
  - The Esc tip in the footer area.

### Phase 4 — Upgrader differentiation

Goal: render the upgrader headline + alternative chips correctly.

- Read `FirstRunState.shared.setupComplete` once on appear (or pipe through the existing `WizardState`).
- If true and the user has a non-default binding, render the State 1 framing.
- Otherwise render the State 0 framing.

### Phase 5 — Test-passed persistence (optional)

Per Open Question 3 — defer.

### Phase 6 — Help anchor + tests

- Update `Sources/Help/Basics/` to ensure the wizard's `Tip: Esc cancels` and the `Caps Lock LED` callouts deep-link cleanly.
- Run `HelpInfraTests.runAll()` in DEBUG to confirm anchors resolve.
- Add a snapshot-style harness assertion that `TestStep` renders State 0, State 3, State 7 without crashing under representative `PermissionsService` mocks.

### Phase 7 — Settings harmony cross-check

- Visually diff the wizard chip and the Settings chip in side-by-side screenshots. Adjust padding / corner radius so they look like siblings.
- Confirm the "Custom…" recorder behaves the same as the future Settings popover (or shares code).

### Files that would change (rough)

| File | Nature of change |
|---|---|
| `Sources/SetupWizard/Steps/TestStep.swift` | Rewrite body; keep override plumbing + capture/transcribe |
| `Sources/SetupWizard/Steps/Components/WizardShortcutChip.swift` | New |
| `Sources/SetupWizard/Steps/Components/WizardInferredRecorder.swift` | New |
| `Sources/SetupWizard/Steps/Components/WizardAlternativesStrip.swift` | New |
| `Sources/SetupWizard/Steps/Components/WizardPermissionBanner.swift` | Extracted from existing `remediationBanner` |
| `Sources/Help/Basics/...` | Confirm anchors, add Caps Lock LED + Esc tip wording if missing |
| `Sources/Permissions/PermissionsService.swift` | No change (already publishes `inputMonitoring` status) |
| `Sources/Recording/Hotkeys/*.swift` | No change |
| `docs/features.md` | Update wizard description once the redesign ships |

### Rough order of magnitude

- ~250–350 LOC of new SwiftUI in the components folder.
- ~120 LOC trimmed from `TestStep.swift` (the binding-controls and timeout-hint sections).
- ~80 LOC for the inferred recorder, plus its NSEvent monitor lifecycle.
- 0 LOC of migration — storage shape unchanged.
- ~40 LOC of test scaffolding for the recorder's classification rules.

**Not a major rewrite.** Mostly presentation-layer; the routing (HotkeyRouter), storage (SingleKeyMigration, KeyboardShortcuts), and test pipeline (audioCapture + transcriber) are unchanged.

---

## 10 · Summary — how this harmonises with the v1.13 Settings → Shortcuts pane

The shipped Settings pane (v1.13, under `Sources/Settings/Shortcuts/`) chose:
- One row per action.
- Trigger type hidden behind a hover-revealed `slider.horizontal.3` overflow menu.
- Chord recorder + single-key Menu chip as alternative right-column affordances, switched by the overflow menu.

The recommended wizard redesign extends that idiom into onboarding:
- One focal chip (analogous to one row in Settings).
- Trigger type entirely inferred (analogous to "hidden behind a menu" in Settings, but pushed further to "invisible").
- The same chip glyph + the same single-key vocabulary across both surfaces.

The wizard pulls the Settings polish item (`features.shortcuts-pane-polish`) forward by needing a custom NSEvent-driven recorder. Building it for the wizard first and then using it in Settings is the right sequencing; the wizard is the higher-stakes surface and the v1.14 Settings polish becomes a paste-in.

What the redesign does NOT do:
- Does not change storage. `SingleKeyMigration` and the `@AppStorage` keys stay.
- Does not change `HotkeyRouter` routing. The override mechanism is the wizard's plumbing.
- Does not change the test pipeline. Audio capture + transcription stay on the same Coordinator-owned instances.
- Does not introduce telemetry, accounts, or any new network call.

The result is a wizard step that reads as one decision, has one focal control, surfaces the most common failure (Input Monitoring) proactively, and treats fresh installs and upgraders with different copy without forking the layout. It harmonises with the shipped Settings pane and points the way to the v1.14 Settings polish.
