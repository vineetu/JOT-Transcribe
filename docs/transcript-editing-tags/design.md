# Editable Transcripts + Tags — Design

Status: **IMPLEMENTED 2026-06-24** (uncommitted, awaiting user test + approval). Core decisions locked; the pre-impl review findings are folded in below; an implementation review pass + a real migration test ran before install. Images remain a separate/deferred feature.

## As-built notes (deviations + verification)

- **Edit mode binds the `TextEditor` directly to `$recording.transcript` — NO draft buffer.** This improves on the doc's draft+explicit-save: the detail view is pushed fresh per `.navigationDestination(for: Recording.self)`, but even under reuse the model stays the source of truth, so the m2 "re-seed draft on id change" and M1 "lost draft on nav-away" hazards simply don't exist. Durability via explicit `context.save()` on Done + `.onDisappear`; `.task(id:)` resets `isEditing` defensively.
- **`editedAt` is stamped once on first hand-edit** (`onChange(of: transcript)` gated on `editedAt == nil`, not per keystroke) and **cleared on Re-transcribe** (fresh machine output). **Re-transcribe is disabled while editing** (impl-review fix) so it can't clobber an in-flight edit.
- **Migration verified on the real library (2,547 recordings):** implicit lightweight migration with NO `VersionedSchema` added `ZTAGS`/`ZEDITEDAT` to the on-disk store, the count was preserved, and no "ModelContainer failed to open" was logged. The on-disk schema change confirms the real container migrated (not the in-memory fallback). Backup taken first at `/tmp/jot-store-backup-*`.
- **Tag filter** chip bar is derived from the windowed `recordings` for cheapness (an unlimited fetch every render would scan all 2.5k rows on every scroll); the filter itself routes through the unlimited fetch so selecting a tag finds every match. Accepted limitation: a tag only on a not-yet-loaded old recording isn't shown as a chip until scrolled to (still findable by typing it in search).
- **New file** `Sources/Library/TagChipsEditor.swift` (TagChipsEditor + TagChip + a small isolated `FlowLayout`). Sources/ is a synchronized group → no pbxproj edits.

## Review corrections (read these first — they change earlier assumptions)

- **Provenance is SUPPORTED, not broken by edits (review B1).** `CorrectionProvenance.reconciledPayload` (`Sources/Vocabulary/CorrectionProvenance.swift:170-196`) is state-based and its own comment anticipates *"a hand-edit in the detail TextEditor."* So a hand-edit is **reconciled**, not invalidated. Requirement: **after Save, call `reviewModel?.reload()`** (the same call re-transcribe makes, `RecordingDetailView.swift:399`) so the live `CorrectionReviewSection` re-anchors against the edited text. Gating the right-click "Add to Vocabulary" to read-mode is still correct — but because the menu lives on a read-only `NSTextView`, not because provenance breaks.
- **Edit mode is a DISTINCT view, not a mutated reader (review B2).** `VocabSelectableTextView` is hard-wired `isEditable=false` with one-way data flow (`TranscriptReader.swift:71,89-106`). Do NOT retrofit two-way editing onto it. Read mode stays exactly as-is; edit mode is a separate `TextEditor` (or a new editable `NSViewRepresentable` writing back to `draftText`).
- **Persist with explicit `context.save()` + a flush on dismiss (review M1).** The title-rename path relies on autosave only (`RecordingStore.rename` — no `save()`); that is NOT a durability guarantee. Mirror the EXPLICIT-save path (`RecordingDetailView.swift:295,387`): on Save set `transcript`/`editedAt` then `try? context.save()`, and add an `.onDisappear`/dismiss flush so navigating away mid-edit can't drop the draft.
- **Undo story already exists (review m5):** the immutable `rawTranscript` + the existing **"Show original" toggle** (`RecordingDetailView.swift:229`) recover the ASR original — this is what makes the no-warning re-transcribe (decision #3) safe. State it; no separate undo needed.

## Overview

Two related, additive capabilities for a Jot **recording**:
1. **Editable transcript** — let the user edit the transcript text (read⇄edit toggle + Save), persisted on the recording.
2. **Tags** — a dedicated `tags` field (chips UI), independent of the body text, wired into the recordings list search/filter.

**Images are a separate, deferred feature** (the user decoupled "tag images" from tagging). Not in scope here; scope later.

This nudges a recording from a *read-only transcript of audio* toward an *editable note* — but stays additive (no rich-text/attributed-content rewrite; `transcript` remains a `String`).

## Locked decisions

1. **Edit model:** explicit **read ⇄ edit toggle + Save**, not always-editable. Preserves the read-only reader's features (playback, position-based right-click "Add to Vocabulary") when not editing.
2. **Source of truth:** `transcript` is the user-editable field; **`rawTranscript` stays the immutable ASR original** (kept for re-transcribe + provenance).
3. **Re-transcribe:** **overwrites `transcript` freely — NO warning, NO guard.** Per the user: editing happens because ASR isn't perfect; audio/text divergence is expected and acceptable. Re-transcribe is allowed to clobber edits.
4. **Tags:** a separate `tags: [String]` field on `Recording` (additive SwiftData migration), edited as **chips** in the detail view; **filterable/searchable** from the recordings list. NOT inline `#tags` parsed from the body.
5. **Images:** out of scope — separate future design.

## Current state (grounded — file:line)

- `Sources/Library/Recording.swift` (`@Model`): `id, createdAt, title, transcript, rawTranscript, audioFileName, modelIdentifier`. **No tags/images.** `transcript` is already a mutable `var` (so editing needs UI + persist, not a model field for the text).
- **Editable today:** only `title` (inline rename — `RecordingRowView` `isEditingTitle`). The **transcript body is read-only** (`Sources/Library/TranscriptReader.swift` — `VocabSelectableTextView`, a read-only `NSTextView`).
- `RecordingDetailView.swift` hosts the transcript + playback (scrubber, waveform) + actions (Copy, Re-transcribe, Reveal, Delete).
- **Search exists:** `RecordingsListView.swift` (text search) + the semantic-search layer — the integration point for tag filtering.
- **Constraints editing touches:** `CorrectionProvenance` tracks positions in the transcript (invalidated by edits); playback word-context assumes the transcript matches the audio. Both are acceptable to break in edit-mode (decision #3) — we just gate the position-based affordances to read mode.

## Data model changes (additive, safe migration)

```
@Model Recording {
   ... existing ...
   var tags: [String] = []        // NEW — chips; default [] = lightweight migration
   var editedAt: Date? = nil      // NEW (optional) — marks a hand-edited transcript
                                  //   for a subtle "edited" indicator; not load-bearing
}
```
Both are additive with defaults → **implicit lightweight migration** (SwiftData's designed-for additive path). **DECISION REVERSED from review M3's "add a VersionedSchema as insurance":** verification (web search, 2026-06-24) shows introducing an explicit `SchemaMigrationPlan`/`VersionedSchema` to a store that has **never been versioned actually BREAKS additive-default migration** — adding a defaulted property migrates cleanly *without* a plan, but *with* a plan it fails (lightweight or custom). Sources: [hackingwithswift lightweight-vs-complex](https://www.hackingwithswift.com/quick-start/swiftdata/lightweight-vs-complex-migrations), [Apple DevForums 738812](https://developer.apple.com/forums/thread/738812). So the VersionedSchema is a *liability* here, not insurance — it would cause the very silent-empty-library it was meant to prevent (`JotComposition.swift:524-555` logs the failure to `ErrorLog` then falls back to in-memory; `default.store` on disk stays intact).
- **Do:** add the two defaulted fields, NO `VersionedSchema`, NO `SchemaMigrationPlan`. Leave the container model-list as-is.
- **Prove it (still required):** back up the real `default.store`, build with the new fields, launch, confirm existing recordings load AND no "ModelContainer failed to open" entry in `ErrorLog`. `editedAt: Date?` is unconditionally safe; `[String]` is the one to confirm (it's a natively-supported SwiftData primitive array, not a transformable).
- (review m1) The real `Recording` model also has `durationSeconds` and `speakerTimeline: Data?` — the additions sit alongside those.

## UX

**Editable transcript (in `RecordingDetailView`):**
```
Read mode (default):  the existing reader (playback, right-click Add-to-Vocab).
   [ Edit ] button in the detail actions.
Edit mode:            the body becomes an editable text view (TextEditor /
   editable NSTextView) seeded with `transcript`.
   [ Done ] (or auto-save on toggle-off) → persist `transcript`, set editedAt = now.
   While editing: playback + position-based right-click affordances suppressed.
```

**Tags (chips):**
```
A tags row placed BELOW `DetailHeader`, in RecordingDetailView ONLY (review M2 —
   `DetailHeader` is shared with RewriteSessionDetailView, which has no tags;
   do NOT add tags to the shared header). E.g. between header and playbackBlock.
   [ #q3 ✕ ] [ #funnel ✕ ] [ + add tag ]
   add-field: type → Return adds a chip. NORMALIZE ON WRITE (review m3):
   trim + strip leading '#' + lowercase + single-token, so the stored tag is
   canonical and dedupe (`tags.contains`) is exact. Persists to `recording.tags`.
```

**List filter/search (review M4):**
```
RecordingsListView:
 - substring search: add `|| r.tags.contains { $0.contains(needle) }` to the
   existing synchronous filter (composes trivially).
 - tag-filter chip bar (in-use tags) above the list. CRITICAL: an active tag
   filter must route through the UNLIMITED fetch (treat it like a non-empty
   search for `recordingsPool` selection) — otherwise it only sees the
   `visibleLimit`-windowed @Query (~30 rows) and silently misses older tagged
   recordings.
 - tags are SUBSTRING-searchable only, NOT semantically indexed (RecordingIndexer
   embeds transcript text only). Documented + acceptable — tags are exact tokens.
 - LibraryItem list switches on .recording/.rewrite already; rewrite items simply
   have no tags (no special-casing needed beyond the existing kind switch).
```

## Implementation plan (pseudocode — not final code)

```
// 1. Model: add `tags: [String] = []`, `editedAt: Date? = nil`; add a
//    VersionedSchema + lightweight MigrationStage (insurance, M3); RUN the
//    prior→new upgrade test before merging.
// 2. RecordingDetailView edit mode (B2 + M1 + m2):
//    @State isEditing; @State draftText
//    enter Edit → draftText = recording.transcript; show a DISTINCT editable
//      view (TextEditor or new editable representable) — NOT a mutated
//      VocabSelectableTextView; read mode renders unchanged.
//    re-seed draftText whenever recording.id changes (sidebar nav while editing).
//    exit/Save → recording.transcript = draftText; recording.editedAt = .now;
//      try? context.save()  (EXPLICIT — autosave isn't durable); then
//      reviewModel?.reload()  (B1 — re-anchor the correction section).
//    .onDisappear / dismiss → if dirty, flush (save) so nav-away can't drop it.
//    gate playback word-context + the read-only right-click menu to !isEditing.
// 3. Tags UI: a TagChipsEditor bound to recording.tags, placed BELOW DetailHeader
//    in RecordingDetailView ONLY (M2). add: normalizeOnWrite(input) → if
//    non-empty & !duplicate → tags.append → try? context.save(). remove likewise.
// 4. List (M4): add tags to the substring filter; tag-filter chip bar that routes
//    through the UNLIMITED fetch; tags not added to semantic index (documented).
// 5. Re-transcribe: unchanged — overwrites `transcript` (decision #3, no warn).
//    It already calls reviewModel.reload(); leave editedAt (or clear it — minor).
```

## Open questions / to settle in review

RESOLVED by the review:
- ~~Edit persistence~~ → **explicit `context.save()` on exit + a dismiss/quit flush** (M1).
- ~~Tag normalization~~ → **normalize on write** (trim + strip `#` + lowercase + single-token) so dedupe is exact (m3).
- ~~Tag filter UX~~ → **in-use-tags chip bar above the list, routed through the unlimited fetch** (M4).
- ~~Editable body widget~~ → a **distinct edit view**, read mode unchanged (B2).

Still genuinely open (minor, settle during implementation):
1. **Edit affordance shape:** auto-save-on-exit (the toggle is the only control) vs. an explicit Save/Done button in addition. Either is fine given the explicit-save + flush; pick during build.
2. **`editedAt` indicator:** show a subtle "edited" badge, or skip (the "Show original" toggle already exposes the divergence)? Cheap; lean ship-it.
3. **`editedAt` on re-transcribe:** clear it (re-transcribe = back to machine output) or leave it? Minor.
4. **Edit-mode styling parity:** if `TextEditor` is used, accept serif→system styling drift in edit mode only, or invest in an editable representable to match the reader? Lean: accept the drift to start.
5. **Accessibility:** chips need VoiceOver labels + a keyboard remove affordance (review n2).

## Checklist touchpoints (from CLAUDE.md)

- `docs/features.md` (editable transcripts + tags), README/website bullet if headline.
- Help tab prose + a deep-link anchor for tagging/editing (+ `InfoCircleAnchorTests` if a new anchor).
- `Recording` model migration — verify the SwiftData container migrates cleanly with existing recordings.
- Recordings list search/filter; detail view edit + tags UI.
- No new hotkey / pill state / menu item.
