# Transcript consistency — one text, everywhere

Status: approved 2026-09-29 (Vineet). Triggered by: the "Did you mean…?" picks were pasted but not saved to Recents. Blast-radius audit (read-only agent, file:line evidence) found 17 places where the pasted / saved / reviewed / searched / learned text can disagree.

## Principle

A recording's text changes through **one Library helper** (`RecordingTextMutation.apply`): sets `transcript`, syncs speaker segments, recomputes an auto-title (never a user rename), saves, re-indexes search, and notifies an open detail view to reload its review list. Every writer — ask pill, review pick/undo, Add to Vocabulary, Edit → Done, re-transcribe — goes through it. The dictation's row id travels with the text from save to paste (like `originApp`), so nothing guesses "the last recording".

## Fixes

| # | Problem (severity) | Fix |
|---|---|---|
| A1 | Popup picks pasted but not saved (High) | One `$lastResult` sink: persist → row id → delivery. Ask path awaits the provenance commit, then each confirm / keep / alternate writes back through the helper and marks its review record with the receipt. Paste text is derived from the saved row. |
| A2 | Deleted recordings still answer Ask Jot (privacy, High) | Delete a recording's search chunks with the recording (incl. retention purge); retriever ignores chunks whose recording is gone; one-time cleanup of orphan chunks. |
| A3 | Search index stale after any edit (High) | Helper re-indexes; indexer skips a write whose text is no longer the row's (A16 race). |
| A4 | Stop-without-paste flag can stick and eat the next paste (High) | Flag stamped onto the session's result (like `originApp`) and reset at each recording start. |
| A5 | Popup timeout pastes the term but records a revert (Med) | Timeout records nothing (the gate's default is already in the text). |
| A6 | Picking the wider-phrase alternate isn't marked; receipt dropped (Med) | Same write-back + receipt as confirm. |
| A7 | Paste Last / Copy Last give pre-popup text (Med) | Recorder's last text updated to what was delivered. |
| A8 | Popup verdict routed to "whatever committed last" (Med) | Verdicts carry the row id (A1). |
| A9/A10 | Two re-transcribe paths; one keeps old speaker segments; old verdicts reattach to new text (Med) | One shared `retranscribe(recording)`: clears segments, clears verdicts (reversing their counts), recomputes title, marks summary stale, re-indexes, commits. |
| A11 | Esc during AI cleanup pastes the raw text though the code says "discard" (Med) | **Discard entirely** (Vineet): no paste, no Recents row, audio file removed like any cancelled recording. |
| A12 | Speaker segments drift from the transcript after edits; export/summary use segments (Med) | Helper keeps segments in sync. |
| A13 | Add to Vocabulary can replace the wrong words if the text changed since the popover opened (Low-Med) | Verify the range still holds the selected word before replacing; route through helper. |
| A14 | Title never updates after re-transcribe (Low) | Helper recomputes an auto-title. |
| A15 | AI summary silently stale after edits (Low) | Mark stale on text change; offer regenerate. |
| A16 | Two index writes race, older can win (Low) | Staleness guard (A3). |
| A17 | Pill and review list can pick different occurrences of a repeated word (Low) | Paste text derived from the saved row's edit (A1). |

## Code smells fixed alongside

Stale comments describing removed learned auto-apply (`AppDelegate`), "transcript is FINAL" (`RecordingPersister`), "inert on macOS" (`CorrectionReviewModel`), misleading `forceResolvePendingAskKeepOriginal`, no-op `effectiveChoice`, duplicate whole-word matchers, duplicate re-transcribe, duplicate copy fallbacks, Esc comment/behaviour mismatch.

## Decisions

A11 — Esc while AI cleanup is running: **discard entirely** (Vineet, 2026-09-29).

## Verification

Replay harness scenarios asserting saved text == pasted text: popup confirm / keep / alternate / timeout; stop-without-paste then a failing transcription then a normal dictation (paste must happen); delete a recording then Ask Jot (not cited); edit → search finds new text; re-transcribe from list and detail give identical state. Unit tests for the helper and chunk deletion.
