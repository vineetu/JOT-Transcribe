# Movable streaming pill — Design

> Status: **SUPERSEDED IN PART (v2, 2026-06-21).** The **v2 implementation plan below**
> (§A–§G) is authoritative. It replaces the v1 SwiftUI-`DragGesture` mechanism — that
> approach shipped and produced two confirmed bugs (choppy ~1/3-distance motion; draggable
> only while recording). The product decisions in the original header (tap-opens /
> drag-moves, drag-from-anywhere, native slop, session-only) STILL HOLD; only the
> *mechanism* changes. The original §1–§11 are kept below as historical context — where
> they specify `coordinateSpace: .global`, a SwiftUI `pillDragGesture`, or "drag only in
> already-interactive states," they are **DEAD** and overridden by §A–§G.
>
> **v2.1 revision (2026-06-21, post adversarial review).** §A–§G below were revised to
> resolve two BLOCKERs and three HIGH/MEDIUM findings from design review. The two
> structural changes vs. the first v2 draft:
> 1. **Drag layer moved BELOW the hosting view (container background), `hitTest` is
>    geometry-only.** The first draft's "overlay ABOVE hosting + control-probe `hitTest`"
>    is **DEAD** — `pillBody`'s `.contentShape(Capsule)` (`:267`) makes the hosting view
>    hit-test as a SwiftUI view across the *entire* capsule, so the `sub !== h` probe
>    returned `nil` everywhere and the pill would not drag in `.recording`/`.repairingModel`/
>    expanded (the most-used states). The robust shape is: SwiftUI controls sit ABOVE and
>    win taps by Z-order; only pixels SwiftUI declines reach the drag view below; the drag
>    view's `hitTest` decides drag-vs-margin by capsule *geometry alone*, never by probing
>    SwiftUI's internal view identity. `performDrag`'s own system threshold supplies
>    tap-vs-drag slop on the capsule-background pixels. (§B.)
> 2. **Clamp now folds its correction back into `committedDelta`.** The first draft's
>    "clamp must NOT mutate the stored delta" directly contradicts the no-jump invariant: a
>    `performDrag` near a screen edge drops the window where `clampOnScreen` would never
>    place it, so the next `updateFrame()` would snap it. Capture and apply now share one
>    `naturalWindowFrame(for:)` helper, and clamp's correction is written back so the stored
>    delta and the on-screen position stay consistent. (§D.2, BLOCKER 1.)
> Also added: a global-monitor drag guard (HIGH 2), `pillRectProvider`-before-
> `ignoresMouseEvents` ordering (HIGH 1), `panel.screen`-based display reset (MEDIUM 1), and
> an explicit "does `performDrag` move THIS panel at all" first runtime check (MEDIUM 2).

---

# v2 — Authoritative implementation plan (2026-06-21)

## A. The two bugs and the principle

**Bug 1 — choppy, ~1/3-of-cursor motion.** `PillView.pillDragGesture`
(`PillView.swift:196-217`) uses `DragGesture(minimumDistance: 4, coordinateSpace: .global)`,
and `OverlayWindowController.updateFrame()` calls `panel.setFrame(..., animate: false)`
live on every `$userDragOffset` emission (`:341`). `.global` is **window-relative**, and we
move the window mid-drag, so each `.onChanged`'s `translation` is measured against an origin
we just shifted — a feedback loop that nets a fraction of the real cursor delta. There is no
SwiftUI coordinate space that stays fixed while its host window moves under it. **Verified in
source.**

**Bug 2 — draggable only while recording.** `applyClickThrough(for:)`
(`OverlayWindowController.swift:443-468`) sets `panel.ignoresMouseEvents = true` in all
passive states. A panel with `ignoresMouseEvents == true` receives **no** mouse events, so
the SwiftUI gesture never fires outside the few interactive states (`.recording`+streaming,
`.success`, `.error`, `.savedToRecents`, `.repairingModel`, `.askCorrection`). **Verified.**

**Principle:** *Dragging a window is an AppKit window-server operation, not a SwiftUI layout
operation.* The fix lives at the AppKit container layer using screen-space input that is
invariant to window motion. Chosen mechanism: **`NSWindow.performDrag(with:)`** — AppKit's own
title-bar/`isMovableByWindowBackground` drag loop. It gives window-server-driven 1:1 motion
with zero coordinate feedback, and a **built-in click-vs-drag threshold** (the system drag
threshold): a press that never crosses it is delivered normally (tap), a press that crosses it
moves the window (drag). That is the tap-vs-drag slop, for free, tuned to the same threshold
the rest of macOS uses. Reject SwiftUI-only and `isMovableByWindowBackground` (the latter is
all-or-nothing on `ignoresMouseEvents`, can't be reconciled with per-pixel click-through, and
its background hit-detection is unreliable over an `NSHostingView` of controls).

## B. The reconciliation problem (the subtle part) — REVISED for BLOCKER 2

We need, simultaneously:
- **Passive-state click-through preserved** when NOT dragging: a click on the empty region
  around a transient `.notice` must pass to the app behind the pill.
- **Press-and-drag on the pill moves it** in EVERY visible state.
- **Sub-slop taps still reach SwiftUI** content (expand/collapse, savedToRecents `Button`,
  repair `.onTapGesture`, the two ask `Button`s).

`panel.ignoresMouseEvents` is all-or-nothing, so it cannot express "transparent here, grab
there." Selectivity moves to a custom `hitTest`, with two layers at the AppKit container:

1. **Panel-level:** `ignoresMouseEvents = false` for every **visible** state, `true` only for
   `.hidden`. The panel can now always receive a press.
2. **Per-pixel click-through via `hitTest` returning `nil`.** A pixel whose `hitTest` returns
   `nil` is transparent to the mouse — the click falls through to the window below.

### Why the first draft's "overlay ABOVE hosting + control-probe" is DEAD

The first draft put a transparent drag overlay **above** the `NSHostingView` and had its
`hitTest` probe `hostingView.hitTest(point)`, returning `nil` (let the tap through) when the
probe resolved to a SwiftUI view (`sub !== h`). **This is backwards for the most-used states.**
`pillBody` applies `.contentShape(Capsule)` (`PillView.swift:267`) — and the expanded bodies
apply `.contentShape(RoundedRectangle)` (`:286,306`) — so `NSHostingView.hitTest` resolves to a
SwiftUI-backed descendant for **every pixel inside the capsule**, control or not. The
`sub !== h` rule is therefore true across the whole capsule, the overlay returns `nil`
everywhere, `performDrag` never runs, and the pill is undraggable in `.recording`,
`.repairingModel`, and expanded recording. There is also no reliable way to ask an
`NSHostingView` "is this pixel a `Button` vs. background" — SwiftUI `Button` is not an
`NSButton` subview; it renders into the hosting view's single backing layer. **Confirmed in
source.** Any approach that reverse-engineers SwiftUI's internal hit-testing is rejected.

### Chosen resolution — drag view BELOW the hosting view, `hitTest` decides by GEOMETRY ONLY

Invert the Z-order. The drag `NSView` is the **container itself** (or a sibling pinned to the
container edges, added *before*/below the `NSHostingView`). SwiftUI controls are above it, so
**they win taps purely by Z-order** — AppKit hit-tests top-down, the hosting view's controls
resolve first, and only pixels the hosting view declines fall through to the drag view below.
This removes the need to probe SwiftUI at all.

The drag view's `hitTest(point)`:
- **Outside the pill capsule rect** (the transparent shadow/padding margin — window is 24pt
  wider, 24pt taller than the pill): return `nil`. The hosting view's clear background there is
  also non-hit (SwiftUI `contentShape` only claims the capsule), so the click falls through to
  the app behind. **True click-through.** (§D.2 supplies the rect via `pillRectProvider`.)
- **Inside the capsule rect:** return `self`. `mouseDown` runs `window.performDrag(with: event)`.

Tap-vs-drag arbitration on capsule pixels is handled by **two independent mechanisms that do
not fight**, because they live on different Z-layers:
- A **sub-threshold press on a SwiftUI control** (a `Button`, an `.onTapGesture` surface):
  the hosting view is above the drag view, so AppKit delivers the `mouseDown` to the hosting
  view FIRST. SwiftUI's gesture system processes it. The drag view never sees that press at
  all — its `hitTest` is only reached for pixels the hosting view's responder chain declined.
  So **all existing `.onTapGesture`/`Button` handlers keep working unchanged.**
- A **press on capsule pixels the hosting view declines** (the dead capsule background — most
  of the recording pill is the timer/equalizer chrome wrapped in `.onTapGesture`, but
  `contentShape` makes the whole capsule a tap target, see the caveat below): reaches the drag
  view → `performDrag`. `performDrag` honors the **system drag threshold**: a press that never
  crosses it is delivered as a normal click (not a drag), and a press that crosses it moves the
  window. That threshold IS the tap-vs-drag slop, for free.

**Caveat — `.contentShape(Capsule)` claims the whole capsule for SwiftUI taps (`:267`).** This
means the *recording* pill's `.onTapGesture { togglePillExpanded() }` (`:109`) currently owns
EVERY capsule pixel, so with the drag-view-below approach the hosting view would consume every
press and **the recording pill would not drag** (the inverse of the dead-overlay bug). We
resolve this deliberately, NOT by reverse-engineering hit-testing:

**Adopt the SwiftUI-side escalation as the tap-vs-drag arbiter ON THE CAPSULE, AppKit only for
motion.** Keep ONE SwiftUI gesture on the pill body — but it does NOT compute any offset (that
was Bug 1). Its only job is: when the press crosses the slop threshold, call into AppKit to
start the window-server drag, and otherwise let the existing `.onTapGesture`/`Button` win.
Concretely, attach to `pillSurface` a
`DragGesture(minimumDistance: <slop>, coordinateSpace: .local)` whose `.onChanged` (fired only
once the slop is crossed — sub-slop taps never start it, so they fall through to the inner
`.onTapGesture`/`Button` exactly as today) calls a closure the controller installs, which runs
`panel.performDrag(with: panel.currentEvent ?? NSApp.currentEvent!)`. Using `.local` (not
`.global`) and never reading `translation` for placement means there is **no coordinate
feedback loop** — the gesture is used only as a threshold detector, the window is moved by the
window server. The `minimumDistance` gives SwiftUI's gesture arbitration the slop: a quick tap
resolves to the `.onTapGesture`/`Button`; a press-and-move resolves to this drag gesture, which
hands off to `performDrag`.

This keeps **every existing tap handler authoritative for taps** (BLOCKER 2 resolved) and uses
AppKit only for the actual window motion (Bug 1 resolved by construction — the window server
moves the window, not `setFrame`-during-`.global`).

**`performDrag` event-validity note (MEDIUM 2 dependency).** `performDrag(with:)` wants the
initiating mouse-down `NSEvent`. By the time SwiftUI's `DragGesture.onChanged` fires,
`NSApp.currentEvent` may be a `.leftMouseDragged`, which `performDrag` accepts on macOS
(AppKit's window drag loop seeds from a drag or down event and then runs its own tracking
loop). If runtime shows `performDrag` ignoring a dragged event on this OS, the fallback is the
**drag-view-below `mouseDown` path**: the geometry-only `hitTest` above already routes
capsule-background presses to the drag view, and for the capsule pixels SwiftUI claims we
instead make the recording pill's tap-target explicit (replace the whole-capsule
`.onTapGesture` with a tap target scoped to the visible chrome, freeing the surrounding capsule
pixels to reach the drag view's `mouseDown`, which has the real `.leftMouseDown` event).
**Implementer: start with the SwiftUI-escalation arbiter (keeps all taps working with zero
SwiftUI surgery); fall back to the explicit drag-view `mouseDown` only if §F.1 shows
`performDrag` won't start from the gesture's event.** Both share the geometry-only `hitTest`
for margin click-through (§D.1) and the `committedDelta` machinery (§D.2).

## C. `acceptsFirstMouse` is mandatory (necessary, not sufficient — see HIGH 1)

The panel is `.nonactivatingPanel` with `canBecomeKey == false` (`OverlayPanel.swift:16,59`).
For a press to register on a non-key window WITHOUT first consuming a click to activate, the
drag view (the container, and the `NSHostingView` for taps) must override
`acceptsFirstMouse(for:) -> true`. Without it, the first click on the pill is eaten as an
activation click and the drag silently won't start until Jot is frontmost. `NSHostingView`
already returns `true` for `acceptsFirstMouse` by default in recent SDKs, but make the
**container/drag view** override it explicitly so the geometry-only `hitTest` path also accepts
the first press.

**HIGH 1 — `acceptsFirstMouse` is necessary but NOT sufficient: order the state-sink writes.**
The `$state` sink (`:133-138`) flips both `panel.ignoresMouseEvents` AND the overlay's
`pillRectProvider`-backing capsule rect. If `ignoresMouseEvents` is set to `false` *before* the
rect is refreshed, there is a window where the panel is hittable but `hitTest` reads a stale (or
`.zero`) rect → either margin presses are grabbed as drags, or capsule presses fall through. In
the `$state` sink set the **capsule rect first, then `ignoresMouseEvents`**, in the same
synchronous block, so the two never disagree. (§D.2.)

## D. File-by-file plan (all within `Sources/Overlay/`)

### D.1 `OverlayPanel.swift` — add the geometry-only drag layer BELOW hosting
- **Add `final class OverlayDragView: NSView`** added to the container **before/below** the
  `NSHostingView` so SwiftUI controls hit-test first (§B). `hitTest` is geometry-only — it
  never probes the hosting view:
  ```
  final class OverlayDragView: NSView:
      var pillRectProvider: () -> CGRect = { .zero }   // capsule rect in this view's coords (controller-installed, [weak self])
      var isDraggingProvider: (Bool) -> Void = { _ in }  // notify controller drag start/end (HIGH 2)

      override var acceptsFirstMouse(for:) -> Bool { true }     // §C

      override func hitTest(point) -> NSView?:
          // SwiftUI controls are ABOVE this view → AppKit already gave them
          // first refusal. We only see pixels they declined.
          if pillRectProvider().contains(point) { return self }   // capsule bg → drag
          return nil                                              // margin → click-through

      override func mouseDown(event):
          isDraggingProvider(true)
          window?.performDrag(with: event)   // window-server drag; honors system slop
          isDraggingProvider(false)          // performDrag is synchronous: returns when the drag loop ends
  ```
  Note `mouseDown` is the **fallback** capsule-background path; the **primary** tap-vs-drag
  arbiter for the capsule is the SwiftUI escalation gesture in `PillView` (§B, §D.3), which
  calls `panel.performDrag` directly. Both share this view's `hitTest` for margin
  click-through. `performDrag(with:)` is documented as synchronous (it runs AppKit's modal drag
  tracking loop and returns when the mouse is released), so toggling `isDraggingProvider`
  around it is safe; for the SwiftUI-escalation path the controller sets/clears the same flag
  around its `performDrag` call.
- **Expose a window-level drag entry** so `PillView`'s escalation gesture can start the drag
  without touching `hitTest`: add `func beginUserDrag()` on `OverlayPanel` that reads
  `self.currentEvent ?? NSApp.currentEvent`, sets the controller's drag flag, calls
  `performDrag(with:)`, clears the flag. The controller wires `PillView`'s escalation closure
  to this.
- **Wire it in `init`:** create `OverlayDragView`, `addSubview(dragView, positioned: .below,
  relativeTo: hosting)` (or add it before `hosting` so it is lower in Z-order), pin to the
  container edges with the same 4 constraints, `wantsLayer = true`, clear background. Expose
  the drag view (and a `beginUserDrag()`) so the controller can install `pillRectProvider` /
  `isDraggingProvider`.
- **Leave alone:** `styleMask`, `level`, `collectionBehavior`, `isMovable=false`,
  `isMovableByWindowBackground=false` (do NOT flip it on — it would double-handle drags),
  `isFloatingPanel`, `hidesOnDeactivate`, `becomesKeyOnlyIfNeeded`, `canBecomeKey/Main=false`
  (load-bearing — the panel must never steal key/main), `backgroundColor=.clear`, the hosting
  view + its constraints. `ignoresMouseEvents = true` stays as the *initial* default (the
  controller sets it per-visibility, §D.2).

### D.2 `OverlayWindowController.swift` — own a committed delta, drop the offset math
- **Delete** the SwiftUI-offset machinery:
  - the `$userDragOffset` Combine sink (`:172-176`) and the `dragOffsetCancellable` property
    (`:38`) — `performDrag` moves the window directly; there is no offset to observe.
  - the `userDragOffset` center-anchor block inside `updateFrame()` (`:324-339`:
    `desiredCenterX`, the `offset`-shifted `windowFrame`).

- **Add `naturalWindowFrame(for state:) -> NSRect`** — the single source of truth for the
  pre-clamp, pre-delta window frame, used at BOTH capture and apply so they're symmetric by
  construction (BLOCKER 1). Extract it verbatim from today's `:310-339` geometry MINUS the
  offset and MINUS clamp:
  ```
  func naturalWindowFrame(for state) -> NSRect:
      screen = OverlayPlacement.currentScreen()         // idle path screen
      pillSize = pillSize(for: state)
      windowSize = (pillSize.w + horizontalPadding*2, pillSize.h + bottomPadding)
      pillRect = OverlayPlacement.frame(for: pillSize, on: screen)
      return NSRect(x: pillRect.midX - windowSize.w/2,
                    y: pillRect.maxY - windowSize.h,
                    width: windowSize.w, height: windowSize.h)
  ```

- **Add a stored center delta** (in-memory, session-only — NOT persisted):
  `private var committedDelta: CGSize = .zero`. Keep `dragOffsetScreenNumber: NSNumber?` and
  `screenNumber(of:)` (`:46,361-363`) — still needed for the multi-display reset, re-keyed to
  `committedDelta`.

- **Capture on drag end (BLOCKER 1).** Become the panel's `delegate` (or observe
  `NSWindow.didMoveNotification` for the panel). On move-end:
  ```
  committedDelta = panel.frame.center − naturalWindowFrame(for: model.state).center
  // do NOT clamp here — performDrag already let the user drop anywhere on-screen
  landedScreen = panel.screen ?? NSScreen.screens.first { $0.frame.contains(panel.frame.center) }
  dragOffsetScreenNumber = screenNumber(of: landedScreen)   // MEDIUM 1: use panel.screen, NOT currentScreen()
  ```
  A **center** delta (not top-left) preserves today's center-anchor semantics so a later width
  change re-centers around the dragged position.

- **Apply in `updateFrame()` — clamp folds back into `committedDelta` (BLOCKER 1).** This is the
  deliberate behavior change vs. the first draft ("clamp must NOT mutate the delta"), because
  that rule produced a visible jump on the first state change after an edge-near drag. New
  sequence:
  ```
  var f = naturalWindowFrame(for: state)
  f.origin.x += committedDelta.width
  f.origin.y += committedDelta.height
  let clamped = clampOnScreen(f, screen: screen)
  if clamped.origin != f.origin {
      // fold the clamp correction back so stored delta == on-screen position
      committedDelta.width  += clamped.origin.x - f.origin.x
      committedDelta.height += clamped.origin.y - f.origin.y
  }
  panel.setFrame(clamped, display: true, animate: false)
  ```
  Because the delta is measured against the natural origin for the *current* size (not
  accumulated), widening 360→480→640 and collapsing back returns to the same spot — no ratchet.
  Because clamp's correction is written back, a state change after an edge drag does NOT snap.
  > **Product decision flagged for the lead:** folding clamp into the delta means a pill dragged
  > hard into a corner, then widened, can settle a few px from its raw drop point (it must, to
  > stay on-screen). This is the only self-consistent resolution of "drop anywhere" +
  > "stay on screen" + "no jump on resize." The alternative (don't fold) reintroduces the
  > corner-jump. Folding is chosen.

- **Multi-display reset (keep, re-key, MEDIUM 1).** Two triggers:
  - In `updateFrame()`: keep the `:291-308` shape but gate on `committedDelta != .zero` and
    reset `committedDelta = .zero` + clear `dragOffsetScreenNumber` when the resolved screen's
    `NSScreenNumber` differs from where the drag was committed.
  - On `didMoveNotification`: derive the landed screen from **`panel.screen`** (the screen
    containing the window frame), NOT `OverlayPlacement.currentScreen()` — the panel can never
    be `keyWindow` (`canBecomeKey == false`, `:59`), so `currentScreen()` tracks some *other*
    window's screen and would mis-detect the landing display. If the landed screen differs from
    `dragOffsetScreenNumber`, zero the delta. Keep `currentScreen()` only for the idle
    placement path inside `naturalWindowFrame`.

- **Simplify `applyClickThrough(for:)`** (`:443-468`) to two cases — **set the capsule rect
  BEFORE `ignoresMouseEvents` (HIGH 1):**
  - `.hidden` → set the drag view's capsule rect to `.zero` (fully transparent `hitTest`),
    THEN `panel.ignoresMouseEvents = true`.
  - any visible state → set the drag view's capsule rect to the current capsule rect (below),
    THEN `panel.ignoresMouseEvents = false`. The drag view's geometry-only `hitTest` governs
    per-pixel click-through.
  - **Capsule rect geometry (MEDIUM 3).** AppKit views are **non-flipped by default** (origin
    bottom-left). The pill is pinned to the window TOP with 12pt horizontal padding and 24pt of
    shadow room BELOW it (`:315-322`), so in the drag view's coords the pill occupies high-y:
    ```
    pillSize = pillSize(for: state)              // same function the window sizing uses
    rect = NSRect(x: horizontalPadding,          // 12
                  y: viewHeight - pillSize.height, // top-pinned in non-flipped coords
                  width: pillSize.width,
                  height: pillSize.height)
    ```
    Source `pillSize` from the SAME `pillSize(for:)` so `.askCorrection`/expanded use their
    `expandedAskWidth/Height` / `expandedRecordingWidth/Height`. In DEBUG, log the rect for the
    first few frames and eyeball it against the rendered capsule. The drag view is full-window,
    so `viewHeight` is the window content height (`pillSize.height + bottomPadding`).
  - The `$state` and `$isPillExpanded` sinks must refresh the capsule rect (it changes with
    width/expansion). `$isStreamingSessionActive` no longer drives interactivity (drag works in
    all states) — it can stop calling `applyClickThrough`, though leaving it is harmless. Keep
    the sink wiring that calls `updateFrame()`.

- **Drag-active guard for the outside-click monitors (HIGH 2).** The plan's §E.8 claim that
  the `event.window === panel` guard protects against self-dismiss covers ONLY the **local**
  monitor (`:254`). The **global** monitor (`:246-251`) has NO window guard and fires for
  events routed to other apps — and a nonactivating panel that `acceptsFirstMouse` can receive
  the drag-initiating `mouseDown` while another app is frontmost, which the global monitor may
  see → `handleOutsideClick()` → `acceptAsk()`/`collapse` the instant you start dragging an
  expanded/awaiting-ask pill. Fix: add `private var isDraggingWindow = false`, set `true` from
  the drag view's `isDraggingProvider` / `beginUserDrag()` BEFORE `performDrag` and cleared
  after it returns. **Both** monitor closures early-return when `isDraggingWindow` is set:
  ```
  outsideClickGlobalMonitor: { if self.isDraggingWindow { return }; handleOutsideClick() }
  outsideClickLocalMonitor:  { if self.isDraggingWindow { return event }; ...existing... }
  ```

- **Retain-cycle (LOW 1).** The drag view's `pillRectProvider` / `isDraggingProvider` closures
  the controller installs must capture `[weak self]` (controller → panel → contentView →
  dragView → closure → controller would otherwise cycle). The hosting view stays untouched.

- **Leave alone:** `updateFrame()` as the **single `setFrame` caller** — `performDrag` moves
  the window via the window server, not `setFrame`, so the single-writer guarantee for the
  *programmatic* path holds and the streaming-tick snap-back race can't occur (the tick
  recomputes natural frame + the now-stable `committedDelta`). Keep `clampOnScreen`,
  `OverlayPlacement`, the screen-change observer, the outside-click monitor install/remove
  wiring, `animate: false`.

### D.3 `PillView.swift` — replace the offset gesture with an escalation-only gesture
- **Replace** `pillDragGesture` (`:196-217`) with an **escalation-only** drag gesture that does
  NOT compute any offset (that was Bug 1) — its only job is to cross the slop threshold and hand
  off to AppKit's window-server drag:
  ```
  // installed by the controller as a closure: () -> Void that calls panel.beginUserDrag()
  var onDragEscalate: () -> Void

  private var pillDragGesture: some Gesture {
      DragGesture(minimumDistance: dragSlop, coordinateSpace: .local)
          .onChanged { _ in
              guard !didEscalate else { return }
              didEscalate = true        // once per drag; performDrag owns the rest
              onDragEscalate()          // → panel.beginUserDrag() → performDrag(with: currentEvent)
          }
          .onEnded { _ in didEscalate = false }
  }
  ```
  - `coordinateSpace: .local` and **never reading `translation` for placement** → no coordinate
    feedback loop (Bug 1 fixed by construction; the window is moved by the window server).
  - `minimumDistance: dragSlop` is the tap-vs-drag slop. A quick tap never starts this gesture,
    so SwiftUI gesture arbitration delivers it to the inner `.onTapGesture`/`Button` exactly as
    today. A press-and-move starts this gesture, which escalates to `performDrag`.
  - Keep one gesture-local `@State private var didEscalate = false` (replacing `dragStart`/
    `isDragging` `:29,33`); it gates the single `onDragEscalate()` call per drag.
  - The `.gesture(pillDragGesture)` attachment (`:188`) stays on `pillSurface`.
- **Pass the escalation closure in.** `PillView` gains `let onDragEscalate: () -> Void` (or an
  `@ObservedObject` hook on the model the controller drives). The controller, when building
  `PillView` in `install()` (`:91`), wires it to `panel.beginUserDrag()` (§D.1).
- **Delete** the old `dragStart` / `isDragging` `@State` (`:29,33`) and `model.userDragOffset`
  reads (`:202,207`).
- **Leave alone:** every `.onTapGesture` (recording expand/collapse `:99,109`, repair `:154`),
  every `Button` (savedToRecents `:139`, ask confirm/dismiss `:167-168`), all `.contentShape`
  calls, and the capsule/rounded-rect backgrounds. These keep working: SwiftUI gesture
  arbitration gives quick taps to them, and the escalation gesture only wins once the press
  moves past `dragSlop`. Do **not** add `.allowsHitTesting(false)` to any capsule background.
  Confirm the expanded transcript `Text` stays non-selectable (no `.textSelection(.enabled)`),
  else click-drag would select text instead of moving — it is currently non-selectable; keep it
  that way.

### D.4 `PillViewModel.swift` — remove the offset property
- **Delete** `@Published var userDragOffset: CGPoint` (`:87`) and its doc comment, once
  `PillView` and the controller no longer read it. `transition(to:)` never touched it, so no
  state-machine change is needed.
- **Do NOT add or remove any `PillState` case.** This keeps the out-of-target harness mappers
  (`Tests/JotHarness/*` — outside `Sources/Overlay/`, do not edit) compiling. No `PillState`
  switch changes anywhere.

## E. Invariants this plan must hold (and how it does)

1. **Resize/expand re-anchor (360→480→640 no jump / no ratchet).** Preserved by storing a
   **center delta** measured against the *current-size* `naturalWindowFrame(for:)` (one helper
   used at both capture and apply) and re-applying it in `updateFrame()` (not accumulating).
   Clamp's correction is **folded back** into the delta so a state change after an edge-near
   drag does not snap — §D.2 (BLOCKER 1).
2. **Single programmatic `setFrame` writer.** `updateFrame()` stays the only `setFrame` caller;
   the drag path uses `performDrag` (window server), not `setFrame`. No second writer, no
   streaming-tick snap-back — §D.2.
3. **Multi-display reset.** Kept, re-keyed to `committedDelta` + `NSScreenNumber`. The
   on-move re-check derives the landed screen from **`panel.screen`**, not the non-key-window
   `currentScreen()` — §D.2 (MEDIUM 1).
4. **Session-only persistence.** `committedDelta` is an in-memory property, lost on relaunch.
   Do not write it to `UserDefaults` — §D.2.
5. **Passive-state click-through when not dragging.** Preserved per-pixel via the drag view's
   **geometry-only** `hitTest` returning `nil` over the transparent margin (and SwiftUI
   controls win the capsule by sitting above) — §B. Never a permanent click-stealer.
6. **Position survives hide→show.** `.hidden` is high-frequency; `committedDelta` is NOT reset
   on `.hidden` (only the capsule rect collapses to `.zero`). Reset only on relaunch and a
   resolved-screen change — §D.2.
7. **Esc / cancel, level, collectionBehavior, notch-flush top placement** — untouched; no
   `styleMask`/`level`/`collectionBehavior`/`canBecomeKey` changes — §D.1.
8. **Outside-click monitors keep working (HIGH 2).** The local monitor's
   `event.window === panel` guard (`:257`) covers in-process presses. The **global** monitor
   has no such guard, so an `isDraggingWindow` flag (set before `performDrag`, cleared after)
   makes BOTH monitors early-return during a drag — so dragging an expanded/awaiting-ask pill
   never self-dismisses it — §D.2. Must be runtime-verified (drag, not just mouse-down) — §F.7.
9. **`animate: false`** stays on `setFrame`; `performDrag` motion is window-server-smooth.
10. **Tap-vs-drag arbitration without reverse-engineering SwiftUI hit-testing (BLOCKER 2).**
    SwiftUI taps stay authoritative via the escalation gesture's `minimumDistance` slop;
    `performDrag` owns motion. The drag view's `hitTest` is geometry-only — it never probes the
    hosting view — so it cannot break in states whose whole capsule is one `.contentShape`
    tap target — §B, §D.3.

## F. Verification (build + runtime — never claim it works without observing)

Build (per environment): `xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Debug
-derivedDataPath /tmp/jot-pill-build -destination 'generic/platform=macOS' ARCHS=arm64
ONLY_ACTIVE_ARCH=YES build` → trust only `BUILD SUCCEEDED` (SourceKit "cannot find type" is
index noise here). Runtime checklist (must observe each):
0. **`performDrag` moves THIS panel AT ALL (MEDIUM 2 — do this FIRST).** Before checking
   smoothness, confirm a press-and-drag on the capsule moves the borderless `.screenSaver`-level
   `.nonactivatingPanel` with `.stationary` collectionBehavior even one pixel. `.stationary`
   governs Spaces/Exposé, not `performDrag`, but this exact window config is untested. If it
   does NOT move, switch §D.3 to the drag-view `mouseDown` fallback (§B) before proceeding; if
   that also fails, the last resort is manual `setFrameOrigin` in `mouseDragged` — which would
   violate the single-`setFrame`-writer invariant (§E.2) and needs re-design, so flag it.
1. **1:1 smooth drag** in `.recording`+streaming — pill tracks cursor exactly, no choppiness.
2. **Drag in a passive state** — trigger a `.notice`/`.success`/`.error`/`.savedToRecents`
   and confirm press-drag-on-capsule moves it (bug 2 fixed).
3. **Click-through preserved** — with a transient pill up, click an app window *in the margin
   around the capsule* and confirm the click lands on the app behind.
4. **Taps still fire** — savedToRecents `Button` opens Recents; repair tap routes to Settings;
   tap-to-expand/collapse recording; both ask buttons (confirm/dismiss) respond. (Quick taps,
   under the slop — confirm they do NOT escalate to a drag.)
5. **Resize re-anchor + edge-drag no-jump (BLOCKER 1)** — (a) drag the streaming pill off-center,
   expand 480→640 and collapse: must NOT jump/ratchet, returns to the dragged spot. (b) drag the
   pill HARD into a screen corner, then trigger a state change (let it transcribe / show
   success): must NOT visibly snap to a different position.
6. **Multi-display (MEDIUM 1)** — drag the pill ONTO another physical display: the delta resets
   so it lands at the default notch position on the new screen (verify it keys off `panel.screen`,
   not a stale main-screen resolution).
7. **Outside-click ask DURING A DRAG (HIGH 2)** — open an ask / expand the recording pill, then
   **press-and-DRAG** the pill (not just mouse-down): the ask must NOT resolve and the pill must
   NOT collapse mid-drag. Separately, a click OFF the pill still resolves the ask to keep-original.
8. **acceptsFirstMouse (HIGH 1 / §C)** — with another app frontmost, the FIRST press on the pill
   starts the drag (no wasted activation click), and the first sub-slop click on a `Button`/tap
   target fires its action.

## G. What to delete / add / leave alone (summary)

| Action | Item | Location |
|---|---|---|
| **Replace** | `pillDragGesture` (offset-computing, `.global`) → escalation-only gesture (`.local`, `minimumDistance` slop, calls `onDragEscalate()`) | `PillView.swift:196-217` |
| **Replace** | gesture-local `dragStart`/`isDragging` → `didEscalate` `@State` | `PillView.swift:29,33` |
| **Add** | `let onDragEscalate: () -> Void` on `PillView`, wired to `panel.beginUserDrag()` | `PillView.swift` + controller `install()` `:91` |
| **Delete** | `model.userDragOffset` reads | `PillView.swift:202,207` |
| **Delete** | `@Published var userDragOffset` | `PillViewModel.swift:87` |
| **Delete** | `$userDragOffset` sink + `dragOffsetCancellable` | `OverlayWindowController.swift:38,172-176` |
| **Delete** | `userDragOffset` center-anchor block in `updateFrame()` | `OverlayWindowController.swift:324-339` |
| **Add** | `OverlayDragView: NSView` (geometry-only `hitTest`, `mouseDown→performDrag` fallback, `acceptsFirstMouse`) BELOW hosting + `beginUserDrag()` on `OverlayPanel` | `OverlayPanel.swift` |
| **Add** | `naturalWindowFrame(for:)` helper; `committedDelta`; window-move delegate/observer (capture, clamp-fold-back, `panel.screen` reset); `isDraggingWindow` guard on BOTH monitors; rect-before-`ignoresMouseEvents` ordering; `[weak self]` closures | `OverlayWindowController.swift` |
| **Leave alone** | All `.onTapGesture`/`Button`/`.contentShape` + capsule backgrounds | `PillView.swift` |
| **Leave alone** | `styleMask`/`level`/`collectionBehavior`/`canBecomeKey`/`isMovableByWindowBackground=false`/hosting + constraints | `OverlayPanel.swift` |
| **Leave alone** | `updateFrame` as single `setFrame` writer, `clampOnScreen`, screen-change observer, outside-click monitor install/remove, `dragOffsetScreenNumber`/`screenNumber(of:)`, `OverlayPlacement` | `OverlayWindowController.swift` |
| **Leave alone** | `PillState` enum (no case add/remove → harness mappers stay green) | `PillViewModel.swift` + `Tests/JotHarness/*` (do not edit) |

---

# v1 (historical — superseded by v2 above)

> Status: **DECISIONS LOCKED by user** (2026-06-19) + revised after 2 adversarial review
> rounds (see §11). Design only; no code. Grounded in a read of `Sources/Overlay/*`.
> **[VERIFY]** = confirm in code at implementation time.
> **NOTE (2026-06-21):** §4 (drag only in interactive states), §9 (`coordinateSpace: .global`),
> and the SwiftUI `pillDragGesture` mechanism are **DEAD** — see v2 §A–§G.

> **User decisions (final, v1):**
> 1. **Quick tap → opens** (existing behavior); **press-and-drag → moves** the pill.
> 2. **Drag from anywhere on the pill** — no corner/handle/header. Press the pill, drag, it
>    moves (§5).
> 3. **Tap-vs-drag the right way, no hacks** → native pointer **slop threshold**
>    (`DragGesture(minimumDistance:)`), §3/§6.
> 4. **Position is session-only, NOT remembered** across relaunch — ship the simplest thing
>    first; revisit persistence later once this works (§7).

## 1. Overview
Let the user **drag the recording pill** to reposition it (it sometimes covers their
window). v1: **temporary** — the moved position lasts the session, resets to the default
(top-center / under-notch) on relaunch. Persistence is a later option (user-confirmed).

## 2. Current architecture (grounded)
- **Window vs pill (load-bearing — drove the round-1 rework):** the panel is sized
  **larger than the pill** — `pillSize.width + 24` × `pillSize.height + 24`
  (`OverlayWindowController.swift:241-244`): 12pt horizontal padding each side, 24pt of
  shadow padding below. The pill is **pinned to the top** of that window; the
  `NSHostingView` fills the whole container (`OverlayPanel.swift:46-51`). SwiftUI hit
  region is limited to the capsule via `contentShape(Capsule)` (`PillView.swift:195`).
  **So the visible pill ≠ the window** — any grab region must be gated to the pill, not
  the hosting view (else we grab transparent shadow margin and swallow click-through).
- **Window:** `OverlayPanel` is an `NSPanel` (`.borderless,.nonactivatingPanel`), `level
  .screenSaver`, `isFloatingPanel`, `collectionBehavior [.canJoinAllSpaces,.stationary,…]`,
  `isMovable=false`, `isMovableByWindowBackground=false`, `ignoresMouseEvents=true` by
  default, `canBecomeKey/Main=false` (`OverlayPanel.swift:13-60`).
- **Position:** `OverlayPlacement.frame(for:on:)` returns the **pill** rect (top-center /
  notch, `OverlayPlacement.swift:14-30`); `updateFrame()` then derives the **window**
  frame from `pillRect.midX` / `pillRect.maxY` (`OverlayWindowController.swift:249-254`).
  `currentScreen()` picks key-window screen → main → first (`OverlayPlacement.swift:37`).
- **Re-centering (the crux):** `updateFrame()` recomputes the window frame centered on
  `pillRect.midX` on EVERY state change, expansion change, and `didChangeScreenParameters`
  (`OverlayWindowController.swift:117-132, 230-256`). It is the **single `setFrame`
  caller** (`:255`); all paths route through it (`:80, :94, :121, :131`) — VERIFIED.
  A manual offset MUST be stored in the model and re-applied **inside `updateFrame()` on
  the window frame**, or it's lost on the next state transition / resize.
- **Click-through machine:** `applyClickThrough()` toggles `ignoresMouseEvents` per state
  (`:321-343`): click-through when idle/status-only; INTERACTIVE (non-click-through) for
  `.recording`+streaming-active, `.success`, `.error`, `.savedToRecents`, `.repairingModel`.
  When `ignoresMouseEvents==true` the panel gets **no events at all** — drag is impossible
  there, which is exactly why drag is restricted to the already-interactive states (§4).
- **Existing gestures / monitors:** `.onTapGesture` (expand recording, repair-tap) in
  `PillView`; outside-click dismissal monitors for the expanded view (`:183-215`). The
  local monitor returns the event (no dismiss) when `event.window === panel` (`:206`); the
  global monitor only sees other-app `.leftMouseDown`. These are installed **only while
  expanded** (`:128-133`).
- **Sizing:** width grows compact 360 → streaming 480 → expanded 640×240
  (`PillView.swift:35,39,42`); window adds 24 to each. Streaming partials tick every 0.5s
  (`PillViewModel.swift:537`) and each partial mutates `state` → fires the `$state` sink →
  calls `updateFrame()`. Expanded recording (640×240) is the case most likely to "cover
  the window."

## 3. The core tension
The pill must be **click-through when idle** (so taps pass to the app underneath) but
**grabbable to drag**. Naive "make it draggable" = make it non-click-through = it starts
eating clicks meant for the app below.

**Resolution (key design idea):** restrict drag to the states that are **already
non-click-through** (§4); within those, the **whole visible pill is grabbable** — you press
*anywhere on the pill* and drag (per user). The only region excluded is the transparent
shadow margin around the pill, so clicks that miss the pill still pass through. We never
forward a click *through* a click-through pill.

**Tap vs. drag — the standard, non-hacky way (per user):** differentiate by *pointer
movement*, not timing or position. A press that moves past a small **slop threshold**
(~4 pt) before release is a **drag** (move the pill); a press that releases within the
threshold is a **tap** (existing expand/collapse/repair). This is exactly the OS-level
definition of a click vs. a drag, and SwiftUI exposes it natively as
`DragGesture(minimumDistance:)` — below the minimum the gesture never starts and the tap
fires; above it, the drag takes over. No timers, no manual hit-math, no hacks (§6).

## 4. When is drag available?
The "covers my window" pain is the **interactive, visible** states — streaming recording
(480 wide) and the expanded transcript (640×240) — which are ALREADY non-click-through
(`applyClickThrough` sets `ignoresMouseEvents=false` for these, `:329-342`). So:
- **v1: enable drag only in the interactive pill states** — streaming `.recording`,
  expanded recording, and the persistent `.error` / `.repairingModel` states. Idle
  click-through states stay untouched (tiny + transient; no drag).
- This sidesteps the hardest part of the tension: drag lives only where the pill is
  already interactive, so no "pass a click through a click-through pill." **VERIFIED sound
  in review — the design's strongest correct call.**

## 5. Grab region — the WHOLE pill (user decision, revised v2)
**User: "wherever I press it and drag it should move" — no corner/handle.** So the grab
region is the **entire visible pill surface**, both collapsed and expanded.
- The window is 12pt wider / 24pt taller than the pill (§2). We still must NOT grab the
  transparent shadow margin (that would start drags in empty space and swallow
  click-through). So the drag surface = the **visible pill shape**, defined by
  `contentShape` — `Capsule` collapsed (`PillView.swift:195`), and the rounded-rect of the
  expanded body. Attach the `DragGesture` at the **root pill content level** (the same view
  that carries `contentShape` and the existing `.onTapGesture`), so it covers the whole
  pill at one layer for both states. No per-subview plumbing, no header overlay.
- **Why the earlier "header-strip only" worry is moot on macOS.** Round 2 restricted the
  expanded grab to the header to avoid fighting the transcript `ScrollView`
  (`PillView.swift:349-377`). But on macOS, **scrolling is driven by the scroll wheel /
  trackpad (scroll events), not click-drag** — you don't drag content to scroll it. So a
  click-drag anywhere on the expanded surface is free to mean "move the pill," while the
  wheel still scrolls the transcript independently. There is no drag-vs-scroll collision,
  so the whole surface can be the grab region. (The round-2 concern was a mobile-style
  drag-to-scroll assumption that doesn't apply here.)
- **Caveat to verify:** the transcript text must not be `.textSelection(.enabled)` (default
  SwiftUI `Text` is not selectable), else a click-drag over it would select text instead of
  moving. [VERIFY] transcript is plain non-selectable `Text`; if selection is ever wanted,
  the move-drag takes precedence.
- **Tap still works everywhere** via the slop threshold (§3): a sub-threshold press on the
  pill (collapsed or expanded) still routes to the existing `.onTapGesture`
  (expand/collapse/repair). Same-view tap + `DragGesture(minimumDistance:)` is the standard
  SwiftUI composition. [VERIFY] tap + drag coexistence on the expanded body as well as the
  capsule (they're now the same single-layer pattern, so one verification covers both).

## 6. Mechanism — options & selection
- **Opt-A `isMovableByWindowBackground`** — rejected: global to the panel, conflicts with
  `.onTapGesture`, can't be per-state, breaks click-through.
- **Opt-B custom `mouseDown/Dragged/Up` on the hosting NSView** — rejected as the primary
  approach. Two costs the review surfaced: (1) the hosting view spans the padded window, so
  it would steal `mouseDown` in the shadow margin and, in the expanded state, steal the
  ScrollView's first `mouseDown` (breaking scroll-to-read), forcing awkward AppKit→
  SwiftUI event forwarding; (2) can swallow the SwiftUI accessibility hit region.
- **Opt-C SwiftUI `DragGesture(minimumDistance: ~4)` on the whole pill surface (SELECTED).**
  Attach it at the root pill content level (the view carrying `contentShape` + the existing
  `.onTapGesture`), so it covers the entire visible pill (§5) in both states at one layer.
  `contentShape` bounds the hit region to the pill (not the shadow margin).
  `DragGesture(coordinateSpace:)` yields a running `translation` (delta) — exactly what we
  accumulate into the offset; no AppKit coordinate conversion, no NSHostingView event
  stealing. The `minimumDistance` IS the tap-vs-drag slop (§3): below it the tap fires;
  above it the drag moves the pill.
- **Opt-D dedicated NSEvent drag monitor** — rejected: global event noise + filtering vs
  the dismissal monitors, for no benefit over Opt-C.

**Selected: Opt-C** — native, single-layer, and the slop threshold gives the correct
tap-vs-drag split with no hacks. Because macOS scrolls via the wheel (not click-drag, §5),
the whole expanded surface can be the grab region without fighting the transcript
ScrollView, so Opt-B's NSView event-stealing problems never arise.

## 7. Offset model + frame application (REWORKED — round-1 BLOCKER/MAJOR fixes)
- Add `@Published var userDragOffset: CGPoint = .zero` to `PillViewModel` (session-only;
  NOT persisted in v1 → resets to default on relaunch, per user).
- **Single writer:** the drag gesture updates `model.userDragOffset` on **every
  `.onChanged`** — it does NOT call `setFrame` directly. `OverlayWindowController`
  subscribes to `model.$userDragOffset` and calls `updateFrame()`, so `updateFrame()`
  remains the **only** code that moves the window. This is what prevents the streaming
  0.5s tick / partials from snapping the pill back mid-drag (the round-1 BLOCKER): the
  offset is already committed to the model *before* any tick-driven `updateFrame()` runs.
  No "commit on mouseUp" step.
- **Apply to the WINDOW frame, not the pill rect** (round-1 MAJOR): inject the offset into
  the `windowFrame` computation (`OverlayWindowController.swift:249-254`) and clamp the
  **window** frame. The old pseudo-code added it to `OverlayPlacement.frame` (the pill
  rect) — but the code never calls `setFrame` with the pill rect, so the clamp would have
  been off by the 12/24pt padding on every edge.
- **Tap still works:** a `DragGesture(minimumDistance: ~4)` does not start (and does not
  consume the `.onTapGesture`) until the press moves past the slop threshold, so
  expand/collapse/repair taps are preserved without any manual drag-vs-tap discriminator
  — this is the "right way" the user asked for (§3). [VERIFY] tap + drag coexistence on the
  pill body (one pattern now covers collapsed + expanded, §5).

## 8. Offset-vs-clamp anchor rule (NEW — round-1 MAJOR fix)
Width grows 360 → 480 → 640 and `updateFrame()` recenters on `pillRect.midX` every call.
A naive "store offset, clamp after recompute" makes the pill **jump on expand** near a
screen edge (drag 480 flush-right, expand to 640 → clamp yanks it ~160pt left). Rule:
- Store the offset as a **desired pill-center anchor** in the current screen's coordinates.
- On each `updateFrame()`: `desiredCenterX = defaultCenterX + offset.x`; build the window
  frame around that; **then clamp the window frame to the screen**. Clamping moves the
  pill only as much as the new width actually overflows, and the *stored anchor is
  unchanged* — so collapsing back returns it to the same place (no ratchet).
- Accept edge-snapping as correct behavior: a pill dragged to the edge and then widened
  stays flush to that edge rather than overflowing. Document this as intended.

## 9. Pseudo-code
```
// PillViewModel
@Published var userDragOffset: CGPoint = .zero          // session-only anchor delta (AppKit-up y)

// PillView — gesture on the WHOLE pill, at the root content view that already carries
//   contentShape(...) and .onTapGesture (collapsed: pillBody :93; expanded: the body).
//   minimumDistance:4 IS the tap-vs-drag slop — one layer, both states (§5).
@State private var dragStart: CGPoint = .zero           // seeded from model.userDragOffset on first drag
.gesture(
  DragGesture(minimumDistance: 4, coordinateSpace: .global)
    .onChanged { v in
      // translation.height is positive-DOWN (SwiftUI); AppKit y is positive-UP → subtract.
      model.userDragOffset = CGPoint(x: dragStart.x + v.translation.width,
                                     y: dragStart.y - v.translation.height)
    }
    .onEnded { _ in dragStart = model.userDragOffset }   // session-persist the anchor
)
// .onTapGesture(expand/collapse/repair) stays on the SAME view — sub-slop presses fall
// through to it (§3/§7). Scroll wheel still scrolls the expanded transcript (§5).

// OverlayWindowController — new subscription makes updateFrame the single writer
model.$userDragOffset
  .receive(on: DispatchQueue.main)
  .sink { [weak self] _ in self?.updateFrame(for: /* current */) }

// OverlayWindowController.updateFrame()  (CENTER-anchor on the WINDOW frame, §7/§8)
let pill = OverlayPlacement.frame(for: pillSize, on: screen)   // pill.midX == screen.midX (width-independent)
let desiredCenterX = pill.midX + model.userDragOffset.x        // explicit center anchor
var windowFrame = /* existing derive: size = pillSize + (24,24); top-aligned to pill.maxY */
windowFrame.origin.x = desiredCenterX - windowFrame.width / 2  // center-anchor, not raw origin delta
windowFrame.origin.y = (pill.maxY - windowFrame.height) + model.userDragOffset.y
windowFrame = clampOnScreen(windowFrame, screen)               // clamp the WINDOW, not the pill
panel.setFrame(windowFrame, display: true, animate: false)     // animate:false already (:255)
```
> §8/§9 note: because `pill.midX == screen.frame.midX` (`OverlayPlacement.swift:16`) is
> width-independent, a raw `origin += offset.x` happens to equal a center-anchor today —
> but the code above computes from `desiredCenterX` explicitly so a future non-centered
> placement can't silently break the anchor invariant.

## 10. Edge cases
- **Streaming partials / 0.5s tick:** safe — offset is model-committed before any
  tick-driven `updateFrame()` (§7). No live `setFrame` race.
- **Resize after drag (480→640):** anchor preserved; clamp only nudges for real overflow
  (§8). No jump on collapse back.
- **Expanded ScrollView:** grab = the WHOLE expanded surface (§5); the transcript still
  scrolls because macOS scrolling is wheel/trackpad, not click-drag — no collision. (Ensure
  transcript `Text` is non-selectable so click-drag means "move," not "select.")
- **Dismissal monitors:** a drag's `mouseDown` targets the panel, so the local monitor's
  `event.window === panel` guard (`:206`) already prevents a self-dismiss, and the global
  monitor only sees other-app events. **No new code needed** — the round-1 review
  corrected the earlier "coordinate via hit-test" note: the existing `event.window`
  check is the protective mechanism. [VERIFY] in-process `mouseDown` carries
  `event.window == panel`.
- **Multi-display / screen change:** `currentScreen()` (`OverlayPlacement.swift:36-40`)
  can switch when focus moves to another display; the offset is meaningful only on the
  screen it was set on. **v1: reset `userDragOffset` to `.zero` when the resolved screen
  changes.** [round-2 MINOR] `currentScreen()` returns an `NSScreen`, which has no stable
  identity across reconfiguration — key the comparison on
  `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` (store
  `(screenNumber, offset)`, zero on mismatch), not object identity or index. Cross-display
  drag is out of scope for v1.
- **`.stationary` + Spaces:** **VERIFIED low-risk, no special handling.** `.canJoinAllSpaces`
  draws the panel on every Space at the same coordinates; `.stationary` only affects the
  Spaces-switch animation. A user offset is just a coordinate the panel already supports.
- **Reset on hide:** **do NOT reset on `.hidden`.** `.hidden` is a high-frequency transient
  state (every dictation ends through it, `PillViewModel.swift:416,446`), so resetting
  there would wipe the offset between every dictation. Keep across hide→show; reset only
  on relaunch (session-only `@Published`, not persisted).
- **Accessibility:** Opt-C keeps the SwiftUI accessibility tree intact (unlike Opt-B's
  NSView interception). Existing `accessibilityLabel`s (`PillView.swift:176,701,739`)
  unaffected; no drag a11y action in v1 (pill is decorative status).
- **Animate:** live-move must not animate — `updateFrame` already passes `animate:false`
  (`:255`). (Note: the stale comment at `:124-126` claiming AppKit animates the frame is
  wrong; no change needed.)

## 11. Review log
- **Round 1 (adversarial, vs code).** Verdict: *not implementable as-is*. Folded in:
  (BLOCKER) window ≫ pill → grab gated to capsule / header strip, §5; (BLOCKER) live
  `setFrame` raced the 0.5s streaming tick → drag now writes `model.userDragOffset` and
  `updateFrame()` is the single writer via a `$userDragOffset` sink, §7; (MAJOR) offset
  applied to the **window** frame not the pill rect, §7; (MAJOR) explicit offset-vs-clamp
  anchor rule for 360→480→640 width growth, §8; (MAJOR) ScrollView conflict → grab the
  header strip only, §5, and switched the selected mechanism Opt-B → **Opt-C**, §6;
  (MINOR) screen-change resets the offset, §10; (MINOR) `.stationary` closed as low-risk;
  (MINOR) reset-on-hide rejected (`.hidden` is high-frequency); (NIT) a11y preserved by
  Opt-C. Verified sound and kept: single `setFrame` choke point (§2), interactive states
  already non-click-through (§4), dismissal-monitor coexistence via `event.window` (§10).
- **Round 2 (confirming, vs code).** Verdict: *implementable, but not as-literally-written
  — two MAJORs in the expanded state.* All 10 round-1 fixes **verified sound** against code
  (single `setFrame` writer; offset on window frame; no sink feedback loop; anchor stable
  across collapse-back; y-flip correct; `.hidden` high-freq; dismissal-monitor guard;
  `.stationary` low-risk; header subview exists). Folded in: (MAJOR) the header strip is
  inside the private `ExpandedRecordingContent` struct with no `model` ref → apply drag via
  an `.overlay` at the `expandedRecordingBody` call site, §5; (MAJOR) expanded tap is on the
  whole body not the header → co-locate the collapse-tap onto the header overlay so tap+drag
  are same-view, §5; (MINOR) `NSScreen` has no stable identity → key on `NSScreenNumber`,
  §10; (MINOR) made §9 compute from an explicit `desiredCenterX` so the center-anchor isn't
  incidental to width-independent `midX`; (MINOR) `dragStart` is `@State` seeded from
  `userDragOffset`, §9. **Design is ready to implement** once the two expanded-state items
  are honored.
- **User decisions (2026-06-19) — supersede round-2's expanded-state plumbing.** User wants
  to **drag from anywhere on the pill**, not a header/handle. This *simplifies* the design:
  grab region = the whole visible pill at one layer (§5), and the round-2 "header-strip only
  / `ExpandedRecordingContent` overlay / co-locate tap" complexity is **dropped**. The
  round-2 driver for header-only was a feared drag-vs-scroll conflict in the expanded
  transcript — but on macOS scrolling is wheel/trackpad, not click-drag, so there is no
  conflict and the whole surface can be the grab region. Tap-vs-drag = native
  `DragGesture(minimumDistance:)` slop (user: "no hacky things"). Persistence: session-only,
  confirmed deferred. Net: design is **simpler** than the round-2 version and ready to
  implement; remaining items are [VERIFY]s at build time (tap+drag coexistence on the body;
  transcript non-selectable; expanded-surface drag doesn't fight the wheel).

---

## v3 — Stable canvas (decouple content size from the drag target)

**Problem with v2.** The overlay window was sized to the pill's content bounding
box per state (compact 360 → streaming 480 → expanded 640, etc.), centered. So
the moment the first live-preview word arrived during dictation, `updateFrame()`
resized the window 360→480 and shifted its origin to stay centered — *that origin
shift IS the pill "moving."* Because the same window frame is also what
`performDrag` moves, content-resize and drag mutate the SAME object and collide
(snap-back-during-dictation). v2's fix only *suppressed* the resize during a drag
— a patch; the pill still jumped wider on the first word when not dragging.

**v3 model (user-chosen full rework).** The window is a **fixed-size transparent
canvas** sized to the LARGEST pill state (`canvasContentWidth =
max(expandedPillWidth, expandedRecordingWidth) = 640`; `canvasContentHeight =
max(expandedRecordingHeight, maxAskHeight) = 420`; plus existing
`horizontalPadding`/`bottomPadding`). The visible capsule is sized per-state by
SwiftUI and floats **top-center inside** this canvas. Content changes (live text,
ask growth, expansion) only re-layout the capsule *inside* the fixed canvas —
they NEVER call `setFrame`. The window is the single drag target; text reflows
within it. The two can no longer collide — the bug class is structurally
impossible, not merely suppressed.

**Geometry becomes capsule-based, not window-based.**
- *Default position*: canvas centered at `screen.midX`, top edge at `screenTop`
  (so the top-pinned capsule sits under the notch exactly as before — relies on
  `OverlayPlacement` already centering + top-pinning independent of size).
- *committedDelta*: a window-origin offset from the fixed default. Because the
  capsule is always top-center-anchored in a constant-size canvas, the delta is
  size-independent by construction — the v2 "no ratchet across width change"
  recompute is now trivially satisfied (there IS no width change).
- *Clamp*: `clampCapsuleOnScreen` keeps the VISIBLE CAPSULE on screen; the canvas
  may hang off-screen (transparent + per-pixel click-through). Clamp-fold-back
  into committedDelta is unchanged.
- *hitTest capsuleRect*: now centered horizontally (`x = (viewWidth −
  pillWidth)/2`) instead of pinned at `horizontalPadding`, since the canvas is
  wider than the capsule.

**View layer (`PillView`).** `pillBody` was already intrinsic-width + centered,
so most states need no change. The only coupling was the compact recording
capsule, whose `maxWidth: .infinity` children (streaming text / waveform) relied
on the window width to bound them. Bound it explicitly at the call site
(`compactPillWidth` idle / `streamingPillWidth` streaming) so the capsule sizes
itself, not via the window. The visible 360↔480 grow still animates (pillSpring),
now inside the stationary canvas — the Dynamic-Island behaviour.

**Net.** v2's suppress-during-drag guard is kept (harmless; avoids redundant
`setFrame`) but is no longer load-bearing. The fix is the fixed canvas.
