# Slice D — macOS "ask before paste" vocabulary-correction UX (design)

> Status: **designed (read-only plan), pending adversarial review.** Builds on Slice A
> (gate engine) + Slice C (`review-ux.md`, post-hoc review). This is the LIVE moment: when
> the gate is UNSURE about a single-word correction, hold the paste and ask in the pill
> ("Did you mean *X*?") before delivering — the macOS analog of jot-mobile's
> keyboard ask-before-insert, using the surfaces macOS actually controls (paste timing +
> pill). User-requested (2026-06-19).

## 1. Feasibility + timing (the crux)
The correction and the paste are far apart and cleanly separable:
- Gate produces corrections in `Transcriber.transcribeWithAsrManager` (`Transcriber.swift:247-261`,
  `rescore()` → `RescoreResult{text, corrections}`). `unsure` is computed at
  `VocabularyGate.swift:221`, on `Proposal`, and currently **dropped** from `UXCorrection`
  (`VocabularyRescorerHolder.swift:214`).
- Paste happens much later in the **delivery bridge**: `AppDelegate` subscribes to
  `recorder.$lastResult` (`AppDelegate.swift:235`) and calls `delivery.deliver(text)`
  (`:265`) → clipboard sandwich. We already intercept here once (`skipNextPaste`, `:248-264`).
- **The hold goes at the delivery bridge** (not in the actor, not in DeliveryService):
  before `deliver(text)`, check `lastResult.corrections` for an `unsure` single-word entry.
  None → deliver immediately (**unchanged path, zero added latency**). One+ → enter the ask
  flow and deliver once afterward. The recorder is already `.idle` and the recording is
  already saved to Recents (RecordingPersister sink), so nothing is lost if the user ignores.

Engine change needed (small): carry `unsure` (+ the `from`/`to`/span) on `UXCorrection`
(`:341-347`), thread `corrections` onto `TranscriptionResult` (the natural recorder→delivery
carrier), set it where the result is built (`Transcriber.swift:299+`).

**Important nuance — `unsure` is a NARROW band today.** `unsure` is true only when a
*measured* confidence sits in `[0.85, 0.95)` (`VocabularyGate.swift:218-221`). OOV names
often have no measured confidence → `unsure==false` → applied confidently (step 5). And
common-word overcorrections (`lista→Lisa`) are **BLOCKED outright** by the brake, not asked.
So as designed, the ask fires only for the genuine boundary cases — asks stay rare (good for
annoyance), **but** this may be narrower than the user's "ask whenever a heard word might not
be meant." **[DECIDE]** whether v1 asks only on `unsure` (narrow, safe) or widens the
ask-trigger (e.g. also ask before applying low-margin OOV applies). This is the #1 thing the
review must pressure-test.

## 2. The ask flow + pill state
```
gate emits unsure single-word correction (from="vikram", to="Vikram")
 → bridge reverts that span to `from` in the staged text, does NOT auto-apply
 → pill shows: "Did you mean Vikram?  ⏎ apply · esc keep"
 → confirm (⏎): splice `to` into staged text → deliver once → CorrectionStore.confirm(from,to)
 → dismiss (esc / click-away / timeout): deliver staged text with `from` kept (write nothing)
 → paste happens EXACTLY ONCE, after the decision
```
- **New `PillState.askCorrection(original:term:)`** (Equatable); resolve closures
  (`onAskConfirm`/`onAskDismiss`) stored on `PillViewModel` (mirror `savedToRecents`,
  `PillViewModel.swift:38-42, 603-617`), not in the payload.
- **New `AskCorrectionContent`** view with two real `Button`s (works without keyboard →
  accessibility) + ⏎/esc glyph hints; amber accent ("needs your call", distinct from the
  green success dot). Wire width (`OverlayWindowController.pillWidth :269-305`) +
  `applyClickThrough` → `ignoresMouseEvents=false` for the new case (`:336-341`).
- **esc-key conflict resolved:** the ask only exists POST-pipeline, when `cancelRecording`
  is already disabled (`HotkeyRouter.swift:567-574`). Add **ask-scoped dynamic** ⏎/esc
  shortcuts enabled only while `state == .askCorrection` (reuse the dynamic enable/disable
  machinery). If the user's dictation key IS Return/Esc, suppress global capture and rely on
  the on-pill Buttons + click.
- **Timeout + outside-click → keep original (safe default).** Reuse `scheduleDismiss`
  (`PillViewModel.swift:517`) with an `askLinger` (~6s); its fire action calls
  `invokeAskDismiss()` (paste original). Outside-click monitor (`:191-215`) → `invokeAskDismiss()`.

## 3. Single explicit confirm arms immediately (folds in Q3)
On **confirm**: `await CorrectionStore.shared.confirm(originalWord: from, term: to)`
(`CorrectionStore.swift:143`). For a **rare/OOV** original that takes net→≥1, which **arms the
gate override immediately** (`VocabularyGate.swift:241`) → next time it auto-applies, no ask
(asks decay as the system learns). For a **common-word** original the gate still refuses to
auto-apply (correct — the "every name becomes Jamy" protection), so it keeps asking; the
single confirm still pastes the term this time. On **dismiss/timeout: write nothing** (a
passive ignore is not a rejection; only an explicit revert in the post-hoc review demotes a
pair).

## 4. Multi-correction rule
Can't re-edit text already pasted into another app → every decision precedes the single paste.
**v1: resolve all asks first, then paste once.** Confident corrections stay applied; collect
the unsure single-word ones (**cap 3**, anti-nag, rank by closeness-to-automatic); revert each
to `from`; present **sequentially** in the one ask pill; splice each chosen word into the
staged text as it resolves; when the queue empties, `deliver(stagedText)` once. Overflow (>3,
rare) → keep-original, still visible in the post-hoc review. **[DECIDE]** sequential single-pill
(recommended v1) vs one combined multi-row pill (later).

## 5. Q2 — "add the term I meant" (the ~30% never proposed)
When the gate never proposed a name, there's nothing to ask → recourse is the **recording
detail** view (not the live pill). Add "Add to Vocabulary" on a transcript text selection
(needs a read-only selectable `NSTextView` representable + `NSMenuItem`, the fast-follow
already scoped in `review-ux.md`). Feeds `VocabularyStore` → rescorer rebuild → future
dictations boost it. Optional: "Add *X* (heard as *Y*)" also seeds `CorrectionStore.confirm`.
Purely additive; doesn't retro-edit the already-pasted text.

## 6. Relationship to the post-hoc review (`review-ux.md`)
Two complementary surfaces, **one learning store**: live ask = the moment (held paste, ⏎/esc,
immediate `confirm`); post-hoc review = durable record (all proposals, undo, blocked-keep
teaching, add-term), keyed by `Recording.id`. Both move the same `CorrectionStore` net the
gate reads. **No double-ask:** the live resolve must also stamp the per-occurrence
`CorrectionProvenance.setVerdict` so the review shows it already-resolved (depends on Slice C's
commit-by-`Recording.id`, now in).

## 7. MVP vs later; risks
**MVP:** `unsure` carried through to `lastResult`; delivery-bridge hold/ask (mirror
`skipNextPaste`); one `.askCorrection` state + view + width/click-through; ask-scoped ⏎/esc;
timeout + outside-click → keep original; `CorrectionStore.confirm` on yes; sequential multi-ask
capped at 3, one paste.
**Later:** live→provenance verdict stamping; Q2 add-term from selection; combined multi-row
pill; asking on BLOCKED overcorrections / broader `worthAsking`.
**Don't transfer from iPhone:** the App-Group/`CorrectionBridge` IPC, proxy re-sync,
`adjustTextPosition` paste machinery — all exist because the iPhone keyboard is a separate
process pasting through a fragile proxy. macOS owns the paste in-process and decides BEFORE
pasting → the cross-process layer collapses to in-memory closures.
**Risks:** confident path untouched (cheap scan); unsure path intentionally delays paste but
recording is already saved → no loss; timeout/outside-click bound the wait; focus-loss = paste
goes to current focus (unchanged from today's deferred paste; outside-click→keep mitigates);
a new recording during a pending ask must cancel it (tie the staged closure to the
`lastResult` identity); Reduce Motion uses the existing fade, amber dot doesn't pulse.

## 8. Review log
- **Round 1 (adversarial, vs code). Verdict: NOT ready to build as written.** Verified sound:
  delivery bridge is the single dictation auto-paste choke point (`AppDelegate.swift:235-267`);
  recording persists independently of paste (no data loss on hold); `cancelRecording`/Esc
  already disabled post-pipeline; `unsure` is exactly the narrow [0.85,0.95) band; pill
  state-machine extension points clean. **Three things must change before building:**
  - **[BLOCKER B1/B2 — Transform invalidates spans] FIX:** corrections are dropped today, and
    the gate's `publishedStart/length` are valid only for `gated.text`. After the gate the text
    goes through segmenter/filler/number AND the async **Transform LLM rewrite**
    (`RecorderController.swift:307-327`); the final pasted text is the *transformed* string, so
    char offsets are meaningless. → **Don't splice by offset.** Carry the correction as a
    structured `{from,to}` pair; at the bridge, **string-match `to` in the final text**: if
    present, it's askable (keep-original = replace `to`→`from`); if Transform reworded/removed
    it, **skip the ask (graceful fallback)** — the correction is moot anyway. Thread the
    correction set from `Transcriber` → `TranscriptionResult` → through the transform task →
    `lastResult`. (Treat this plumbing as the core of the slice, not a footnote.)
  - **[BLOCKER M4/M5 — held paste can be dropped/orphaned] FIX:** do NOT reuse `scheduleDismiss`
    (it sets `.hidden` WITHOUT delivering → the held paste silently never lands) and don't rely
    only on `lastResult`-identity tagging. The ask needs its **own dedicated resolution path
    that ALWAYS ends in `deliver()`**, survives unrelated pill transitions (notice/repair
    chains cancel `dismissTask`), and is **force-resolved to keep-original+deliver when a new
    recording begins** (before the new session claims the pill).
  - **[MAJOR M3 — auto-Enter] FIX:** state that auto-Enter (`DeliveryService.swift:161-164`)
    runs INSIDE `deliver()` after the ask resolves (correct relative to the paste), and the
    confirm-⏎ must be consumed, not forwarded to the focused app.
  - **[MAJOR M1 — the ask-trigger misses the user's intent] → NEEDS A PRODUCT DECISION** (see
    below). `unsure` fires only on the thin measured-confidence band, which the gate's own
    comments say is *atypical* for the OOV names this targets. The cases that match the user's
    intent — **silent OOV applies** ("did you mean Vikram?") and **blocked common-word
    near-misses** ("did you mean Lisa?") — are exactly the ones NOT asked. Fix = a new
    gate-emitted "ask candidate" flag (distinct from `unsure`); WHICH cases to ask is the
    decision in §9.
- **Round 2:** _pending — after the §9 trigger decision + the B1/M3/M4/M5 fixes are folded in._

## 9. [DECISION NEEDED] What should trigger the "ask?"
The annoyance↔intent tradeoff. Options for which corrections pop "Did you mean X?":
- **A — narrow (`unsure` only, as first designed):** asks almost never; misses the cases you
  described. Rejected (doesn't meet intent).
- **B — intent-matched (recommended):** ask on (i) a single-word term applied to an *unfamiliar*
  word the model wasn't confident about (the silent-OOV "did you mean Vikram?"), and (ii) a
  *blocked* common-word near-miss ("did you mean Lisa?"). Mitigate annoyance: ask a given
  `{from→to}` pair **at most once until answered**; a "yes" learns it (→ auto-applies, no more
  asks); never ask pairs already armed or obviously-confident exact matches. Asks decay as it
  learns.
- **C — aggressive:** ask on every correction. Rejected (nags on every name, every time).
This is a gate-shape change (emit "ask candidates"), so it's worth settling before build.
