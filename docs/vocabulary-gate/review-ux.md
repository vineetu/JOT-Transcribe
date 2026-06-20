# Slice C — macOS confirm→learn correction-review UX (design)

> Status: **designed (read-only plan), ready to build MVP.** Engine (Slice A) + per-language
> dicts (Slice B) are in. This is the UI where the user reviews vocabulary corrections and
> confirms/teaches them, feeding `CorrectionStore` learning. Grounded in the jot-mobile flow
> + the macOS `RecordingDetailView`.

## 0. The make-or-break: provenance is orphaned today
- The gate records proposals in `rescore()` (`VocabularyRescorerHolder.swift:320`,
  `CorrectionProvenance.record(...)`) into the actor's transient `pending` slot.
- **`commit(transcriptID:)` is NEVER called in `Sources/`** (only in jot-mobile) — so nothing
  is persisted and the next dictation overwrites `pending`. No link from a `Recording` to its
  corrections exists.
- Fix (no SwiftData migration): key provenance by **`Recording.id`** (already a unique stable
  UUID, `Recording.swift:12-13`). Three wiring points:
  1. **Commit:** in `RecordingPersister.persist` right after `context.save()`
     (`RecordingPersister.swift:71`) → `await CorrectionProvenance.shared.commit(transcriptID:
     recording.id)`. The anchor machinery then reconciles the gate-time `gatedText` baseline
     against the saved transcript, absorbing the post-gate transform chain + AI rewrite
     (`RecorderController.swift:307-317`) exactly once — this is what the anchors are for.
  2. **Clear:** `await CorrectionProvenance.shared.clearPending()` at the top of
     `Transcriber.transcribe(...)` (~`:156`) so Ask/Rewrite voice paths (which don't create
     `Recording`s) can't leak pending proposals into the next real recording.
  3. **Discard:** in `RecordingStore.delete` (`:98-102`) → `discard(transcriptID: recording.id)`
     so orphan JSON doesn't accumulate; also commit on the retranscribe completion path
     (`RecordingDetailView.swift:307`).
- **Do NOT** add the applied-set to the `Recording` `@Model` (avoids migration). Provenance
  side-JSON keyed by `Recording.id` is the single source of truth for review; the pill's
  lightweight `{from,to,notable}` set rides the pill channel (feedback-ux.md), not the row.
  (Resolves the open `[DECIDE]` at feedback-ux.md:366 → don't attach to the row.)

## 1. Review surface in `RecordingDetailView`
Reuse the existing GroupBox idiom. The macOS body is today a plain `Text` with
`.textSelection` (`RecordingDetailView.swift:194-201`) — no per-word tap target.

- **MVP = a `DisclosureGroup` review section** below the transcript GroupBox, shown only when
  the recording has corrections (`!model.records.isEmpty`). Label: "Jot guessed on N words" /
  "All reviewed ✓". Inside: one row per correction occurrence — context line + CHANGED/KEPT
  badge + two chips ("original" / "term", one tagged IN TEXT) + Undo on resolved rows. This
  alone delivers confirm→learn for both directions, with **no AppKit text work**.
- **Later = inline marks:** port `MarkedTranscriptText` to an `NSViewRepresentable`
  (read-only selectable `NSTextView`): solid-blue underline = applied, dashed-grey = kept;
  click a mark (`NSClickGestureRecognizer` + `layoutManager.characterIndex/boundingRect`) →
  native SwiftUI `.popover` (its own arrow — drops the iPhone caret math) with the same chips;
  flash wash on edit (CALayer). Discoverability polish; not required for MVP.

## 2. Port `CorrectionReviewModel` (engine seam, mostly mechanical)
New `Sources/Vocabulary/CorrectionReviewModel.swift`, ported from jot-mobile verbatim except:
- `Transcript` → `Recording` (`transcript.id`→`recording.id`, `.text`→`.transcript`).
- **Drop** the iPhone keyboard-sync lines (`CorrectionReviewModel.swift:191-192`,
  `TranscriptHistoryMirror`/`CrossProcessNotification`) — no macOS analogue.
- Keep `reconciledPayload`/`setVerdict`/`clearVerdict`/`noteSelfEdit`/`marks()`/`context(for:)`
  unchanged — the ported macOS provenance actor supports them identically.
- Own it as `@State` in `RecordingDetailView`, seeded with `recording` + `modelContext`;
  `await model.reload()` in `.task(id: recording.id)`.

## 3. Confirm→learn call flow (logic already in the engine; macOS just calls it)
```
click chip → CorrectionReviewModel.pick(record, choice)
  → reload()                                  // reconcile anchors
  → editText(...)                             // mutate recording.transcript + context.save() + flash
       → CorrectionProvenance.noteSelfEdit    // deterministic anchor shift
  → CorrectionProvenance.setVerdict(recording.id, …) → MappingDelta   // net ±1
  → CorrectionStore.adjust(by: delta)         // learning
  → reload()
```
"Undo" reverses symmetrically (`model.undo`). The common-word net≥2 / rare net≥1 *arming*
thresholds live on the gate's read side (`CorrectionStore.snapshot()` consulted at
`VocabularyRescorerHolder.swift:274`) — write path is identical on macOS, thresholds honored
automatically. Blocked-keep calls are keyboard-only (inert on macOS) — keep for file parity,
no UI.

## 4. The two directions
- **(i) Overcorrection (clobbered a word):** applied row → pick **original** → reverts in-text
  AND records a revert (`delta −1`), which at net ≤ 0 disarms the gate's override for that pair.
  So "revert + stop auto-applying" is one gesture. (A hard "never suggest" = iPhone
  `suppressBlock`, keyboard-only; not needed — the gate silently re-blocks. Nice-to-have.)
- **(ii) Missed vocab:**
  - Gate considered but BLOCKED it (a KEPT record exists) → pick **term** → applies + records
    `+1` (arms override: rare immediately, common after 2). Canonical "teach the missed term."
  - Gate never proposed it (no record) → no row to show. Recourse: "Add to Vocabulary" from a
    text selection (port iPhone's selection menu to an `NSMenuItem` on the `NSTextView`) →
    adds the term so *future* dictations boost it. Feasible; MVP-optional fast-follow.

## 5. Relationship to the pill chip (feedback-ux.md §7)
Pill chip = lightweight signal/entry point (`RescoreResult.corrections`, applied-only, deduped,
hover). This detail view = the actual review (full provenance: applied + kept, per-occurrence,
verdicts). Same gate proposals → counts/copy must agree; same applied=blue/kept=grey palette;
`notable` is the bridge. Future "chip → open this recording's detail" deep-link is enabled by
the §0 `Recording.id` linkage — reserve, don't build in C.

## 6. MVP vs later; risks
**MVP:** §0 linkage (3 wiring points) + ported `CorrectionReviewModel` (minus keyboard lines)
+ the DisclosureGroup review section + pick/undo wiring. Delivers confirm→learn for (i) and
(ii-blocked) without any AppKit text work.
**Later:** inline `NSTextView` marks + click→popover; "Add to Vocabulary" from selection;
"Show N more" cap; chip→detail deep-link; explicit "Stop suggesting."
**Don't transfer:** keyboard-extension sync, ask-prompt suppression UIs, `CorrectionBubble`
caret math, `UIScreen`/`uiColor` tokens.
**Risks:** anchor drift through the AI transform — reconcile diffs `gatedText`→saved text,
fails *safe* (missing mark, never wrong edit); test with a paraphrasing transform. Commit
AFTER `context.save()` (text is final by then — `RecordingPersister` sink runs post-transform).
Re-transcribe overwrites text under the same id — commit on that path too, accept stale-row
fail-safe. **No `Recording` `@Model` change → no SwiftData migration** (the tripwire: attaching
the applied-set to the row would force one — rejected here).
