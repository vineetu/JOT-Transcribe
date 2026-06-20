# In-pill feedback UX for custom vocabulary — Design

> Status: **REVISED after adversarial review round 1** (see §12). UX design only;
> no implementation code. Sits downstream of `docs/vocabulary-gate/design.md` (the
> functional gate). This doc answers a narrow question: when the `VocabularyGate`
> **APPLIES** ≥1 vocab correction to a finished dictation, how — if at all — does
> the recording pill tell the user about it? Decisions needing the user are marked
> **[DECIDE]**; **[VERIFY]** facts were confirmed in code in round 1.
>
> **Round-1 headline:** the view-layer design (chip on `.success`, `.help` hover,
> `errorPillWidth` reuse, Option A over B/C) is sound and verified against code.
> The blockers were all in the **data contract**: (1) the gate has **no `earned`
> flag** — replaced with a real `Proposal`-derived `notable` predicate (§3, §6);
> (2) the success pill is **delivery-driven** (`delivery.$lastDelivery`), NOT
> result-driven — so corrections must ride the `DeliveryEvent`, not the
> `lastFallbackNotice` channel (§3); (3) §11 rescoped — this needs gate-return +
> Transcriber + delivery plumbing, not "one payload extension."

---

## 1. Overview

The vocabulary gate corrects words on the **final transcript pass** (e.g.
`vikram → Vikram`, `cloud code → Claude Code`). By the time the gate runs the
text is already being delivered — the user sees the `.success(preview:)` pill
~2.4 s and the corrected text lands at the cursor. Today there is **zero signal**
that vocabulary did anything. That has two costs:

1. **Trust / discoverability.** A user who just set up custom vocabulary has no
   confirmation it's working. Silent success feels like "did it even use my
   term?" The first few wins are exactly when reassurance matters most.
2. **Diagnosability.** When the gate *blocks* something the user wanted (or
   applies something they didn't), there's no breadcrumb. (Blocks are out of
   scope for this surface — see §7 — but the applied-corrections signal is the
   seed of the eventual history view.)

This is **informational, trust-building feedback**, not an action. The paste has
already happened; nothing here may block, delay, or alter delivery. The bar is:
*tasteful, glanceable, and quiet enough to survive being shown many times a day.*

**Scope of this doc:** the APPLIED-correction signal only. We do **not** design
the blocked/override surfacing, the full diagnostics history, or any settings
toggle UI beyond noting where the opt-out lives.

---

## 2. What the pill is today (constraints we inherit)

From `PillView.swift` / `PillViewModel.swift` / `OverlayWindowController.swift`:

- **Geometry:** 36 pt tall capsule, pure black, `height/2` corner radius, hugs
  the notch, top-center. Compact width 360 pt; text-driven states (`.error`,
  `.notice`, `.savedToRecents`, `.repairingModel`) measure their string and grow
  up to 600 pt via `errorPillWidth(...)`.
- **Transient terminal states auto-dismiss** via `scheduleDismiss(after:)`:
  `.success`/`.notice` linger **2.4 s** (`successLinger`), `.savedToRecents`
  **5 s**, errors 7–15 s.
- **Success today** = `SuccessContent`: green dot + single-line preview,
  `truncationMode(.tail)`, left-aligned. [VERIFY: `PillView.swift:617-634`]
- **Motion:** content cross-fade `.opacity` ease-out **0.14 s**; pill
  insertion/removal slide-from-notch spring; Reduce Motion → 0.12 s fade, no
  spring. Any new content must reuse these, not invent its own.
- **Materials:** no SwiftUI material — flat `Color.black` + drop shadow. SF
  Symbols + system semantic colors (`systemGreen`, `secondaryLabelColor`, etc.).
- **Click-through (`applyClickThrough`)**: `.success`/`.notice` are currently
  `ignoresMouseEvents = false` for `.success` (it's grouped with error/saved)
  but `.notice` is `true` (pure info, non-interactive). [VERIFY: `.success` is
  in the `false` branch at `OverlayWindowController.swift:336` — it is tappable
  today even though `SuccessContent` has no tap handler. Confirm whether making
  success interactive has any side effect.] **Any tappable affordance we add
  requires the panel to be non-click-through for that state's whole linger.**
- **Exhaustive switches** on `PillState` live in 5+ places (`PillView` body,
  `pillWidth`, `applyClickThrough`, the recorder/rewrite `.idle` branches, the
  hold/repair guards). Adding a case touches every one — the compiler is the
  checklist (per CLAUDE.md).

**Implication:** the cheapest, most consistent change reuses `.success`'s linger,
motion, and width machinery. A whole new pill state is the most expensive
(touches every switch) and should only win if it buys real UX.

---

## 3. Data this UX needs from the gate

**[round-1 BLOCKER 1 — `earned` does not exist.]** The gate's real return is
`Result{text, applied:Int, blocked:[String], proposals:[Proposal]}` with
`Proposal{originalWord, term, decision, outcome, confidence, margin, unsure,
occurrenceIndex, …}` (`VocabularyGate.swift:51-77`). There is **no `earned`
field.** The closest, `unsure`, is *backwards* for our headline case: it's
`measured ?? false` over `[lowConfidence, ceiling)`, and unknown-confidence **OOV
names** (the very "Vikram"/"Jamy" catches we want to celebrate) have no entry in
the confidence map → `unsure == false`. Filtering on `unsure` would hide exactly
the wins we want to show. So we define our own **derived** flag.

This UX requires the gate path to surface, alongside the final text, the list of
**applied** corrections, each carrying:
`{ from: String, to: String, notable: Bool }` — where `notable` is computed in the
macOS adapter (one place; `design.md §6`) from real `Proposal` fields:
`notable = term.contains(" ") || margin >= 4.0 || resolvedConfidence <= 0.85 ||
decision == .override`. (In v1 the gate already BLOCKs trivial high-confidence
single-word swaps, so nearly every *applied* correction is `notable` anyway — the
flag is belt-and-suspenders in v1 and becomes load-bearing once learned overrides
land in v2. `notable` powers the anti-annoyance filter in §6.)

**[round-1 BLOCKER 2 — the channel is delivery, not `lastResult`.]** The success
pill does NOT subscribe to `recorder.lastResult`; it subscribes to
`delivery.$lastDelivery` and builds `.success(preview:)` from `DeliveryEvent`
(`PillViewModel.swift:196-201`, `deliveryEvent(...)` `:476-490`). `DeliveryEvent`
today carries **only `text`** (`DeliveryEvent.swift:8-11`). So the cited
`lastFallbackNotice` mirror does **not** feed success. The applied set must reach
`deliveryEvent`, two viable routes:
- **(a, recommended) extend `DeliveryEvent.pasted`/`.clipboardOnly`** to carry the
  `[Correction]` payload. Type-safe, no cross-object race; cost: the Delivery layer
  must be handed the gate output (wider than "one payload change" — see §11).
- **(b) recorder companion property** read synchronously inside `deliveryEvent`
  (like `consumeFallbackNotice()` at `:213`), set on the recorder **before**
  `DeliveryService` publishes for that transcript. Smaller blast radius; **requires
  verifying the recorder→delivery ordering** (the fallback-notice code sets
  `lastFallbackNotice` immediately before `lastResult`, `RecorderController.swift:324-325`,
  but delivery is a separate publisher — confirm sequencing).
- De-dup is **not free from the gate** (proposals are per-occurrence); collapse
  `proposals.filter{ outcome=="applied" }` by `(originalWord, term)` in the adapter
  (`design.md §6/§7`). Order by source position.

If surfacing the full set proves hard, the graceful fallback is a `count` only
(`"2 terms applied"`) with no `from→to` detail.

---

## 4. Options

### Option A — Annotate the existing `.success` pill (RECOMMENDED)

Add a compact trailing affordance to `SuccessContent` when ≥1 correction was
applied: a small sparkle glyph + count chip, right-aligned, after the preview.
No new pill state. The preview keeps the left two-thirds; the chip claims a fixed
~64–90 pt on the right.

**When:** same moment as success today (delivery `.pasted`/`.clipboardOnly`),
only if applied-corrections is non-empty (and passes the §6 filter).
**Duration:** the existing 2.4 s `successLinger`. No new timer.
**State:** reuses `.success`; payload extends to
`.success(preview: String, corrections: [Correction])` (empty array = today's
look exactly). [VERIFY: every `switch` that matches `.success(let preview)` must
add the new associated value — `PillView.swift:111`, `PillViewModel` call sites
at 470/576/607-style success transitions, `pillWidth` line 302.]
**Interaction:** hover (NSPopover-free SwiftUI `.help(...)` tooltip, like the
error glyph at `PillView.swift:770-773`) reveals the `from→to` list. No click
needed for the common case → **pill can stay click-through** (preserves today's
behavior; we don't force non-click-through just for hover — `.help` works without
mouse capture). [VERIFY: `.help()` fires on a click-through panel; if it needs
mouse events, fall back to the §interaction rules in §8.]

```
single correction, collapsed (default):
┌────────────────────────────────────────────────┐
│ ● Met with Vikram about the launch     ✦ Vikram │
└────────────────────────────────────────────────┘
   green dot   preview (tail-truncated)   sparkle + term

many corrections, collapsed:
┌────────────────────────────────────────────────┐
│ ● Claude Code and Vikram shipped it     ✦ 2     │
└────────────────────────────────────────────────┘
                                          sparkle + count

on hover (tooltip, not a layout change):
        ┌─────────────────────────┐
        │ Vocabulary applied      │
        │  cloud code → Claude Code│
        │  vikram → Vikram        │
        └─────────────────────────┘
```

**Tradeoffs**
- (+) Cheapest that still shows *what* was fixed. One payload change, reuses
  linger/motion/width.
- (+) Degrades to identical-to-today when no corrections (empty array).
- (+) Doesn't add a screen-time beat — no extra pill after success.
- (−) Real estate: the chip eats into preview width on the 360 pt compact pill.
  Mitigate by widening to the streaming width (480 pt) when a chip is present,
  or shrinking preview truncation. [DECIDE: widen, or shrink preview?]
- (−) Sparkle competes with the green success dot for "what changed" attention;
  must stay subordinate (smaller, dimmer).
- (−) Tooltip detail is hover-only → invisible on a click-through pill if
  `.help` needs mouse capture (the [VERIFY] above).

### Option B — Dedicated transient state `.vocabularyApplied(corrections:)`

A second pill shown *after* success: success dismisses (2.4 s), then a distinct
sparkle pill for ~2 s, then hidden.

```
┌────────────────────────────────────────────────┐
│ ✦ Vocabulary caught “Vikram”                    │
└────────────────────────────────────────────────┘
```

**When:** chained after success, like the `.notice` fallback chain
(`PillViewModel.swift:208-222`). **Duration:** own ~2 s linger.
**State:** new `PillState` case → touches every exhaustive switch (§2).
**Interaction:** could be tappable to open the future history view.

**Tradeoffs**
- (+) Can't crowd the preview; full width for its own message; clearest "this is
  about vocabulary."
- (+) Natural tap-target for the future diagnostics deep-link.
- (−) **Adds a second status beat** to *every* corrected dictation. With vocab
  set up, that's most dictations → this is the most likely to become annoying.
  Directly fights the §4 anti-annoyance goal.
- (−) Most expensive: new case in 5+ switches, new linger constant, new
  click-through branch, new width branch.
- (−) Total pill screen-time roughly doubles (2.4 s + 2 s) on corrected runs.

### Option C — Inline marker in the success/streaming preview text

Style the corrected word inside the preview (underline / accent color) so the
user sees `…about **Vikram**…` highlighted.

**Tradeoffs**
- (+) Zero extra chrome, zero extra time; the "what" is shown in situ.
- (+) Feels magical when it lands on a short preview.
- (−) The preview is **tail-truncated to ~40 chars / one line**; the corrected
  word is frequently *off-screen* (truncated away), so the marker is unreliable —
  it'd show sometimes and not others, which reads as a bug.
- (−) Styled runs in a tiny 12 pt single line are hard to notice; on the black
  pill, accent underline has low contrast budget.
- (−) Says nothing in the (common) multi-correction or long-transcript case.
- (−) No path to "what term?" when the word is `Vikram` and the original was also
  visually similar — the *value* (it fixed a mishearing) isn't legible.

### Option D (proposed) — Hybrid: subtle glyph by default, detail on demand

= Option A's collapsed chip as the **default at-a-glance** signal, but make the
chip itself the affordance: it's a small sparkle that, on hover, expands the
tooltip (A), and — *future* — on click opens the corrections history (§7). No
second pill (avoids B's cost), no fragile inline styling (avoids C), and the
detail is opt-in so the default stays quiet.

This is effectively A with an explicit "the chip is the future deep-link
anchor." I fold D into the recommendation rather than treat it as separate.

---

## 5. Recommended design

**Option A (folding in D): annotate `.success` with a subtle, optional sparkle
chip; detail on hover; the chip is the future history anchor.**

Why over B: B doubles status time on the most-common path and is the most
expensive to maintain — the wrong trade for an *informational* signal that fires
constantly. Why over C: the preview truncation makes inline marking unreliable.
A is the only option that is simultaneously cheap, glanceable, degrades to
today's look, and doesn't add a screen-time beat.

**Spec**

1. **Trigger:** on the success transition, if the run produced ≥1 *qualifying*
   correction (§6 filter), render the chip; else render `SuccessContent`
   unchanged.
2. **Collapsed chip (default):**
   - Glyph: `sparkles` SF Symbol, 11 pt, `.white.opacity(0.55)` — quieter than
     the green dot and the preview text. (Tone: "noticed," not "alert.")
   - 1 correction → glyph + the **target** term (`Vikram`), tail-truncated at
     ~14 chars (§6).
   - ≥2 → glyph + count (`2`). Never list multiple terms inline.
   - Right-aligned, after the preview, fixed slot.
3. **Width:** when a chip is present, size the success pill with the text-driven
   path (reuse `errorPillWidth`-style measuring of `preview + chip`) capped at
   600 pt, instead of the fixed 360 pt. Keeps the preview from being squeezed.
   [DECIDE: text-measured width vs. a single fixed "success-with-chip" width
   (e.g. 480 pt streaming width) — fixed avoids churn, measured avoids slack.]
4. **Detail on hover:** SwiftUI `.help(...)` carrying up to N lines of
   `from → to` (cap at 5, then `+K more`). No layout change, no popover.
   **[round-1 RESOLVED — was [VERIFY]]** `.help` works on this panel: the error
   glyph already uses `.help(...)` (`PillView.swift:770-773`) and `.error` lives in
   the **same** `ignoresMouseEvents == false` branch as `.success`
   (`OverlayWindowController.swift:336`). Tooltips need the window to receive
   mouse-moved/tracking events (`ignoresMouseEvents == false`), **not** key/main
   status — and `.success` is already non-click-through. So hover detail is a
   proven, shipping pattern under the exact setting `.success` has. No click-through
   change needed for v1.
5. **Motion / materials / dismiss:** identical to success today — 0.14 s
   cross-fade, 2.4 s linger, flat black, slide-from-notch. The chip fades in
   with the preview (same `.transition(.opacity…)`), not on its own animation.
6. **Reduce Motion:** chip just appears with the pill (the existing 0.12 s
   fade); no sparkle shimmer/animation on the glyph (it's a static symbol —
   do **not** add a pulsing/twinkle effect; that would be novel motion the rest
   of the pill doesn't use).
7. **Accessibility:** `accessibilityLabel` on the success content becomes
   `"<preview>. Vocabulary applied <from> to <to>"` (or `"<N> vocabulary
   corrections"`), so VoiceOver users get the signal the sighted hover gives.

---

## 6. Content rules & anti-annoyance

The central risk: once vocab is configured, corrections happen on *most*
dictations. A signal that fires every time becomes wallpaper at best, nagging at
worst. Rules to keep it tasteful:

1. **No corrections → show nothing extra.** `SuccessContent` is byte-identical to
   today. (Empty `corrections` array.)
2. **Only show `notable` corrections by default. [DECIDE — recommended]** Filter
   the displayed set to corrections where the derived `notable` flag is true
   (multi-word / decisive CTC margin / low-or-unknown confidence — §3). A trivial,
   high-confidence near-exact swap gets **no** chip. Rationale: the chip should mean
   "vocabulary *figured something out*."
   - **v1 reality (round 1):** the gate already BLOCKs the trivial high-confidence
     single-word swaps, so in v1 nearly every *applied* correction is already
     `notable` → the filter rarely subtracts anything. It's belt-and-suspenders now
     and becomes load-bearing once learned overrides (v2) allow confident applies.
     The **real v1 throttle is rule 9 (Settings opt-out)**, not this filter.
3. **1 vs many:** 1 → show the term. 2+ → show the count, never a list inline.
   Full list is hover/history only.
4. **De-dupe by `from→to`:** a term applied at 3 positions is **1**.
5. **Truncate long terms:** target term shown collapsed is capped (~14 chars,
   tail-truncated with `…`). Hover/history shows the full `from → to`.
6. **Never block or delay paste.** The corrections payload is read *after*
   delivery has fired; if it's missing/late, the success pill shows with no chip.
   Computing/formatting the chip must not gate the delivery event.
7. **Direction of arrow / wording:** collapsed chip shows only the *result*
   (`✦ Vikram`) — terse. The "from → to" framing is reserved for hover/history
   where there's room to be honest about what changed.
8. **[DECIDE] Optional frequency damping** (only if rule 2 proves insufficient in
   dogfood): show the chip at most once per N minutes per term, or only on the
   *first* few times a given term is corrected, then go quiet (the user has
   learned it works). Recommend **not** building this for v1 — rule 2 should be
   enough; revisit with real usage.
9. **[DECIDE] Settings opt-out.** A single toggle "Show when vocabulary corrects
   a word" (default **on**) under Settings → Vocabulary (or Transcription). Lets
   power users who find it noisy turn it off entirely. Cheap insurance; recommend
   shipping it. Wire an `info.circle` "Learn more →" per the CLAUDE.md checklist.

**The "learned/override" case:** if/when learned overrides (`CorrectionStore`,
deferred to gate v2) land, an applied learned override is *the most* `notable`
correction there is (`decision == .override` → always `notable`; the user
explicitly taught it). It should always qualify for the chip, and hover/history
could tag it ("you taught this"). No special collapsed treatment for v1 — it just
shows like any `notable` correction.

---

## 7. Future hook — corrections diagnostics / history

jot-mobile logs per-occurrence verdicts (apply/block/override). The eventual
macOS surface is a **Corrections history** view (likely under Settings →
Vocabulary, or a Home detail) listing recent dictations with their applied *and
blocked* corrections — the place a user goes when "it changed a word I didn't
want" or "it missed my term."

This pill UX is the **entry point**, not the history itself:

- The sparkle chip is the natural deep-link anchor. **Future:** make the chip
  tappable → opens the corrections history (scrolled to this dictation). That
  flips the success pill to **non-click-through for its linger** (like
  `.savedToRecents` today) and adds a tap handler stored on `PillViewModel`
  (mirror `onSavedToRecentsTap` / `invokeSavedToRecentsTap`,
  `PillViewModel.swift:115-116, 596-617`). **Not built in v1** — the chip is
  hover-detail only for now; we just reserve the affordance and keep the glyph
  the same so the gesture is discoverable later without a visual change.
- For the history to exist, the gate must **persist verdicts** (the §3 applied
  set, plus blocked verdicts). v1 of the gate logs via `ErrorLog`
  (`design.md §7`). Persisting structured verdicts (e.g. on the `Recording`
  SwiftData row, or a sibling store) is a gate-side prerequisite — flag it so the
  log-only v1 doesn't paint us into a corner. [DECIDE: attach applied/blocked
  verdicts to the `Recording` row now (cheap, future-proofs history) vs. defer.]

---

## 8. Interaction & pill-state changes needed

**v1 (recommended, hover-only):**
- `PillState.success` payload: `success(preview:)` →
  `success(preview:, corrections: [Correction])`. **`Correction` must be
  `Equatable, Sendable`** — `PillState` is `Equatable` (`PillViewModel.swift:14`)
  and that conformance is relied on by `next != state` (`:343`), `tick()` (`:559`),
  and `.animation(…, value: model.state)` (`PillView.swift:65`); a non-Equatable
  associated value breaks synthesis. (Two successes with different arrays compare
  unequal — harmless here.)
- **[round-1 MINOR — corrected switch list].** Adding an associated value forces an
  edit **only at sites that *construct* or *bind* the payload**; bare `case .success`
  (no `let`) keeps compiling. So:
  - **MUST change:** the binding site `PillView.swift:111` (`case .success(let
    preview)`), and the two construction sites `PillViewModel.swift:470`
    (`showRewriteSuccess`) and `:574` (`transitionToSuccessIfNotError`).
  - **No edit needed (bare matches):** `PillViewModel.swift:413` (recorder `.idle`),
    `:443` (rewrite `.idle`), `:295` (`repairStateChanged`), `:366` (`showHoldProgress`),
    and the combined `pillWidth`/click-through cases (`OverlayWindowController.swift:302`,
    `:336`). (The earlier "607" citation was wrong — that's `showSavedToRecents`, not a
    success transition.)
- `SuccessContent`: append the optional chip + `.help(...)` + a11y label.
- `pillWidth(for:)`: `.success` with a non-empty chip uses the **existing**
  text-measured path — `errorPillWidth(for:)` (`OverlayWindowController.swift:307-317`)
  is already shared by `.error/.notice/.savedToRecents/.repairingModel`; wiring
  `.success`-with-chip in is a one-line `case` change. Empty chip stays fixed 360.
- **Click-through: unchanged for v1.** `.success` is already non-click-through
  (`OverlayWindowController.swift:336`) and `.help` works there (§5.4 RESOLVED).
  **[round-1 MINOR — weigh this]** that also means today's success pill *already*
  swallows clicks in its ~360pt footprint for the full 2.4 s linger (pre-existing,
  not introduced here) — but **widening it (up to 600pt) enlarges that inert
  dead-click zone.** So if we adopt the wider width, seriously consider the
  [DECIDE] below *together with* the width change, not as an unrelated future item:
  move inert (no-tap) `.success` to click-through, flipping to non-click-through only
  when a tappable chip ships. [DECIDE: width vs. click-through coupling.]
- No new linger constant, no new dismiss path, no recorder/rewrite switch change
  (it's still `.success`).

**Future (tappable chip → history):** add `onVocabularyChipTap` +
`invokeVocabularyChipTap()` on `PillViewModel` (mirror saved-to-Recents); set
`ignoresMouseEvents = false` for `.success` (already true today) and ensure the
chip is a `Button(.plain)` like `SavedToRecentsContent`.

---

## 9. Edge cases

- **No corrections:** identical to today (the whole point — silent by default).
- **All corrections filtered out by the `notable` rule:** treat as "no
  corrections" → no chip. (Rare in v1 — see §6 rule 2.)
- **Long target term / many terms:** truncate term to ~14 chars; ≥2 → count;
  hover caps at 5 lines + "+K more."
- **Long preview + chip on 360 pt pill:** widen (text-measured/480 pt) so the
  preview isn't crushed; cap at 600 pt; preview still tail-truncates.
- **Rewrite success path** (`showRewriteSuccess`, `PillViewModel.swift:468`):
  **[round-1 RESOLVED]** `showRewriteSuccess` builds `.success` from
  `RewriteController.lastRewrite: String` (`RewriteController.swift:69`) — pure
  rewrite output that **never** passes through `VocabularyRescorerHolder.rescore`
  (only `Transcriber.swift:214` calls the gate). So rewrite success carries no
  corrections → empty array → no chip. **But if the payload rides `DeliveryEvent`
  (§3 route a), rewrite paste also goes through delivery** — so rewrite deliveries
  must explicitly carry an empty corrections array, or a rewrite could inherit a
  stale chip from a prior dictation. Guard that in the rewrite delivery construction.
- **Streaming preview vs final:** the gate runs on the **final** pass only
  (`design.md`), so the live streaming partial in the recording pill is
  *un-gated* — do **not** try to mark corrections in the streaming text (it's not
  final and would flicker). The chip is a success-pill-only concern.
- **`.notice` collision:** the mic-fallback `.notice` chains *after* success
  (`PillViewModel.swift:208-222`). The chip lives *inside* success, so it
  coexists — success-with-chip shows first (2.4 s), then the notice. No conflict,
  but [VERIFY] the chained notice still fires correctly when success carried a
  chip payload.
- **Clipboard-only delivery** (`.clipboardOnly`): still "success" to the user
  (`deliveryEvent` line 482) → chip should still show; the corrections happened
  regardless of paste vs. clipboard.
- **Error path:** if delivery `.failed`, no success pill, no chip (correct — the
  text never landed).
- **Reduce Motion:** static glyph, no twinkle; appears with the pill's 0.12 s
  fade.

---

## 10. Open questions

- [DECIDE] Filter to `notable` corrections only (recommended) vs. show all
  applied — note (§6 rule 2) the filter rarely subtracts in v1; the real throttle
  is the opt-out toggle.
- [DECIDE] Width strategy for success-with-chip: text-measured (`errorPillWidth`
  reuse) vs. fixed wider — **coupled** to the click-through decision below (§8).
- [DECIDE] Settings opt-out toggle in v1 (recommended) + its home (Vocabulary vs.
  Transcription pane) and Help deep-link.
- [DECIDE] Persist verdicts on the `Recording` row now to future-proof history,
  or defer (gate ships log-only).
- [DECIDE] **Data channel (round-1 BLOCKER 2):** ride `DeliveryEvent` (route a,
  type-safe, wider blast radius) vs. recorder companion read inside `deliveryEvent`
  (route b, verify recorder→delivery ordering). §3.
- [DECIDE] Inert `.success` click-through: keep non-click-through (today) vs. switch
  to click-through — weigh **with** the width change (widening enlarges the inert
  dead-click zone), §8.
- **[RESOLVED] `earned`** — does not exist; replaced by a derived `notable` flag in
  the adapter (§3, mirrored in `design.md §6/§7`).
- **[RESOLVED] `.help` on the overlay panel** — works; the error glyph proves it on
  the same non-click-through branch (§5.4).
- **[RESOLVED] Gate surfacing without perturbing timing** — gate returns
  `Result{text, applied, blocked, proposals}`; adapter maps applied proposals to the
  UX payload; `design.md §7` owns the (widened) rescore return + Transcriber thread.
- [VERIFY] Japanese path (`JapaneseVocabularySubstituter`) — unguarded, returns a
  plain `String` (no `Proposal`s) → no `notable` data → **no chip** in v1. Nemotron
  returns `confidence:1.0` and never rescortes → also no chip. Consistent.

---

## 11. Recommendation

Ship **Option A**: a single optional sparkle chip appended to the existing
`.success` pill, shown for `notable` corrections, collapsing to a count when there
are several, with the full `from → to` detail on hover — reusing the success pill's
2.4 s linger, 0.14 s cross-fade, flat-black material, and slide-from-notch motion
so it feels native and adds **zero** new status beats. The **view-layer** change is
genuinely small (`.success` payload extension + a `errorPillWidth` reuse + the chip
view), degrades to today's exact look when nothing was corrected, and the chip
doubles as the reserved anchor for a future tappable deep-link into a corrections
history.

**Honest scope (round-1 MAJOR):** the *cost is not in the pixels — it's the data
contract.* This feature is **blocked on the gate surfacing the applied set
end-to-end**: gate return shape → `Transcriber` thread → and the **`DeliveryEvent`
channel** (success is delivery-driven, not result-driven). That spans
`VocabularyGate`/`VocabularyRescorerHolder` (`design.md`), `Transcriber.swift:214`,
and `DeliveryEvent`/`deliveryEvent`. Treat the UX as a *thin layer on top of that
plumbing*, not a standalone change. The two former [VERIFY]s are now resolved:
`.help` works on the panel (§5.4), and the gate's real `Result` can be mapped to a
`{from,to,notable}` payload (§3) — what remains is the **[DECIDE] data-channel
route** (DeliveryEvent vs. recorder companion) and the **width/click-through
coupling** (§8).

## 12. Review log
- **Round 1 (adversarial, vs code).** Verdict: *not implementable as-is — three
  data-contract issues; the view layer is sound.* Folded in: (BLOCKER) **`earned` is
  fictional** → derived `notable` flag from the real `Proposal` fields, defined once in
  the adapter (§3, §6; `unsure` is backwards for OOV names); (BLOCKER) **success is
  delivery-driven** (`delivery.$lastDelivery`, `DeliveryEvent` carries only text) → the
  payload must ride the `DeliveryEvent` (route a) or a recorder companion read inside
  `deliveryEvent` (route b), NOT the `lastFallbackNotice` channel (§3, §10); (MAJOR)
  **rescoped §11** — blocked on gate-return + Transcriber + delivery plumbing, not a
  UX-only change; (MINOR) corrected the switch-edit list (only bind site `:111` +
  construction `:470/:574` must change; bare matches compile; "607" was miscited) (§8);
  (MINOR) `Correction` must be `Equatable, Sendable` (§8); (MINOR) `.help` **resolved
  yes** — error glyph proves it on the same non-click-through branch (§5.4); (MINOR)
  widening `.success` **enlarges the pre-existing inert dead-click zone** → couple the
  width decision with the click-through decision (§8); (NIT) rewrite via `DeliveryEvent`
  must carry an empty array to avoid a stale chip (§9); (NIT) de-dup lives in the adapter
  (proposals are per-occurrence) (§3). Verified sound: Option A over B/C (code favors it);
  `errorPillWidth` reuse; linger/motion/material reuse; Reduce Motion / VoiceOver / JA /
  Nemotron / clipboard-only handling.
- **Round 2:** not needed — round-1 view layer verified sound; the open items are
  [DECIDE]s (channel route, width/click-through coupling) for implementation time, not
  design holes. The `earned→notable` + delivery-channel fixes are mirrored in `design.md`.
