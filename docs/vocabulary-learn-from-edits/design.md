# Learn from transcript edits

Status: design, 2026-09-28. Brainstormed with Vineet; decisions below are his calls unless marked "proposed".
Builds on `docs/plans/vocabulary-evidence-and-decode-bias.md` (evidence-typed gate + Nemotron Multilingual decode-time bias).

## Feature overview

When the user edits a transcript (Recents → Edit → Done), Jot learns from it. Each word the user replaced becomes a learned correction, the new word is added to the vocabulary (exactly as the "Add to Vocabulary" button does), and that term's decode-time bias strength goes up. Editing it back, or keeping the original when Jot asks, pushes it down. The goal: the bias moves toward what this user means, fast — **one edit should be enough**.

## Background

- Motivating case: owner says "Claude", Jot writes "cloud" every time, even after repeated hand edits.
- Root causes found (2026-09-27/28):
  1. Hand edits teach nothing. `commitEdit()` (`RecordingDetailView.swift`) only saves and reloads the review model; `editedAt` is a timestamp.
  2. "cloud" is an everyday word, so the correction store refuses text rules for it (by design) and the owner's "stop asking" put it in `suppressedBlocks`.
  3. The vocabulary term is lowercase `claude`.
  4. The fixed bias (start 3.5, continuation ×1.5 = 5.25) is too weak at the vowel: on the owner's voice the model prefers "ou" over "au" by ~9–10 logits. Needs a start weight ≈ 7.
- The fork's own note: applying 6.0 to *every* term produced artifacts ("build today" → "build to day"), which is why weights above `maxBoost` 6.0 currently fall back to 4.5. High strength is only defensible per term, earned by the user's own corrections.

## Assumptions

- A1. A hand edit in the transcript pane is a deliberate "next time, write this" signal (Vineet: "they are making a deliberate change for the next time").
- A2. Users give up after one failed correction, so the first edit must already change the next dictation (Vineet: 3 is too much; at most 2).
- A3. Sound alone cannot separate near-homophones for a given voice; the up/down loop settles at the user's real usage mix.
- A4. Only Nemotron Multilingual has decode-time bias today. The learning layer is model-independent; other decoders consume the strength when they gain bias.
- A5. Ceiling and step values are chosen on public data (LibriSpeech), never on owner recordings (owner clips = held-out check only).

## Investigation findings (code)

- Edit surface: `TranscriptEditor(text: $recording.transcript)` edits the canonical transcript directly — the same path for plain and speaker-labelled recordings (labelled view is read-only; edit mode always shows the plain editor). So one hook covers both.
- `transcript` = post-cleanup (and post-AI-cleanup if enabled); `rawTranscript` = what the model produced. Edit diff baseline = a snapshot of `transcript` taken when Edit is pressed.
- Re-transcribe replaces both texts and clears `editedAt`; it never runs in edit mode, so it can't trigger learning.
- `CorrectionStore` (jot-shared) already stores per-term `(originalWord → term)` mappings with `confirmations`, `reverts`, `alwaysReplace`, `suppressedBlocks`. Strength can be *derived* from these counts — no new stored number that can drift.
- `VocabularyStore.addMapping(heard:term:)` is what "Add to Vocabulary" uses (term + optional alias, sanitized, deduped, ≤ 4 words).
- Bias path: `NemotronMultilingualStreamingTranscriber.applyVocabulary` sends every canonical term at fixed weight 3.5; `NemotronVocabularyBias.effectiveBoost` sends any weight > 6.0 back to 4.5.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Learn on edit commit (Done, and the durability flush on navigate-away/quit), diffing the Edit-start snapshot against the saved text. | Vineet |
| D2 | Only **substitutions** teach (1–3 words replaced by 1–4 words). Added or removed sentences/words teach nothing. Punctuation-only changes are ignored. | Vineet |
| D3 | The new word is added to the vocabulary the same way the "Add to Vocabulary" button does (term, with the heard word as alias when useful). Nothing is a transcript-only fix. | Vineet |
| D4 | Strength moves both ways: an edit toward the term raises it; an edit back, or "keep original" on an ask, lowers it. | Vineet |
| D5 | **One edit is enough** on models with bias: the first correction sets the term to the learned strength (the measured safe ceiling), not a small step. A reverse edit drops it back. | Vineet ("after first itself") |
| D6 | Models without bias (Parakeet, Nemotron English, iPhone): rare/misspelled originals ("claud") keep today's text rule, armed after 1 edit. A common original ("cloud") gets a text rule after **2** same-direction edits with no reverse; one reverse edit disarms it. Strength stored the same way, so these models pick it up as bias when they get it. | Vineet (≤ 2), mechanism proposed |
| D7 | Stop-asking (`suppressedBlocks`) only silences asks; it never blocks edit learning. (The real blocker was `refusesLearning` in `confirm()`, not suppression — edits use their own counters.) | Vineet |
| D8 | Both-common swaps ("a"→"the", "their"→"there") are not learned — biasing "the" would hurt every dictation. | proposed, no objection |
| D9 | One count per term per edit session, however many occurrences were fixed — a long meeting can't jump a term twice. | proposed, no objection |
| D10 | Case-only edits ("claude"→"Claude") fix the vocabulary term's casing; they are not a mishearing. | proposed, no objection |
| D11 | If the replaced word isn't in `rawTranscript` (AI cleanup introduced it), add the vocabulary term but don't raise bias — the model didn't mishear. | proposed, no objection |
| D12 | Ceiling measured on LibriSpeech: one term at 5/6/7/8, count false insertions and splits corpus-wide. If the safe ceiling is below what "Claude" needs on the owner's voice, report that honestly — no owner-data tuning. | proposed, no objection |

## Options explored

- **Fixed global bias raise** (all terms to 6–7): rejected — measured artifacts on neutral speech.
- **Text find/replace rules for everything**: rejected as the default — blind to audio and context ("cloud storage" → "Claude storage"). Kept only as the D6 fallback for decoders without bias.
- **Gradual step (+1 per edit)**: rejected — needs 3+ edits to flip "Claude"; users give up (A2).
- **Context-aware disambiguation via AI cleanup prompt** (pass vocabulary to the cleanup LLM): the only thing that truly separates "Claude Code" from "cloud storage"; separate future feature.

## Selected design (revised after design review, 2026-09-28)

Learning layer in JotVocabCore (jot-shared), so Mac, iOS and Windows share it.

### Edit diff

```
EditLearner.learn(before, after, raw, vocabulary, isCommon) -> [EditLesson]
  hunks = wordAlign(before, after)             // word-level, punctuation-insensitive
  for each changed hunk:
    skip if pure insert/delete                  // D2
    skip if hunk sizes outside 1–3 → 1–4 words  // D2
    skip if only punctuation differs            // D2
    if only case differs → .recase(term)        // D10
    if before-side is a vocabulary term and after-side is a known original
       of it → .reverse(original, term)         // checked FIRST (review #5):
                                                // editing "Claude" back to "cloud"
                                                // must never add "cloud" as a term
    skip if every word on both sides is common  // D8
    .substitute(original, term, heardByModel: original ∈ raw)   // D11
  dedupe by (original, term)                    // D9
```

### Store: separate edit counters (review #2, #3, #4, #9)

`confirm()` refuses common originals and `revert()` can lock a common pair at net −1, so edits do NOT go through confirm/revert. New per-mapping counters, written only by the edit path (and an explicit "keep original" tap):

```
Mapping += editsToward, editsAway, editStreak     // Codable, default 0 (old files load)
recordEdit(original, term, .toward) → editsToward += 1; editStreak += 1
recordEdit(original, term, .away)   → editsAway += 1;  editStreak = 0; alwaysReplace = false
```

- Not guarded by `refusesLearning` — common originals ("cloud") are allowed here; the gate's own safety (`snapshot()` clamps common nets, `alwaysReplace` is the only common arm) is untouched.
- `suppressedBlocks` is irrelevant to this path (it only filters asks) — D7 holds for free.
- `dropCommonOriginalRules` is a one-time migration (flagged), so it will not erase these counters later.
- Existing confirm/revert/adjust verdicts do NOT feed strength → a user who never edits sees no change on upgrade (review #9).

### Strength (derived, no stored scalar)

```
strength(term) =
  max over term's mappings with heardByModel lessons:
    editsToward > editsAway → learnedCeiling      // D5: one edit is enough
    otherwise               → base (3.5)
```

A timeout or outside-click on an ask never lowers strength; only a reverse edit or an explicit "keep original" does (review #8). Once the bias makes the decoder write "Claude" itself, no ask exists, so a reverse edit is the down path.

### Text rule fallback for decoders without bias (D6)

```
common original: editStreak ≥ 2 and editsAway == 0 → set alwaysReplace (edit path only)
                 any .away edit clears it
rare original:   today's rule (arms at net ≥ 1) via a normal confirm
```

### Vocabulary add (review #6)

- Rare/misspelled original → `addMapping(heard: original, term)` (alias, same as the button).
- Common original → add the term WITHOUT the alias. An alias "cloud" would make the CTC gate hold pastes and ask on genuine "cloud"; it adds nothing to bias (aliases are not sent to the decoder).
- `.recase` → new `VocabularyStore.recase(term)` (addMapping dedupes case-insensitively and cannot change case); also update the stored `Mapping.term` casing.

### Mac wiring (review #1, #7, #11)

```
on Edit pressed: editSession = (recording, snapshot: recording.transcript)
finishEdit(session):             // single funnel, idempotent
  called from Done, onDisappear, and the TOP of .task(id:) before its reset
  (sidebar navigation reuses the view; must use the captured recording, not `recording`)
  diff synchronously, then hand lessons to the stores
review section hidden while editing (a pick there would double count)
on commit: close any open review record for a learned (original, term) pair
  via setVerdict instead of a separate count
```

Quit mid-edit: best effort; a lost lesson on quit is accepted.

### Decoder

- `vocabularyProvider` returns `(term, weight)`; canonical terms only, never aliases (the fork boosts aliases as themselves).
- `applyVocabulary` compares `(term, weight)` pairs, not just term strings, or a weight-only change never reaches the decoder.
- Fork: `effectiveBoost` clamps to the ceiling instead of falling back to 4.5.

## Verification plan

1. LibriSpeech single-term sweep → pick `learnedCeiling` (D12).
2. LibriSpeech full run with no corrections → B-WER/U-WER unchanged (users who never edit see no change).
3. Owner's 7 "Claude" clips at the learned strength (held-out check), plus owner recordings containing a genuine "cloud" to see the cost.
4. In-app: edit cloud→Claude once, dictate again; edit back, confirm it drops. Replay suite with 0 dropped callbacks.

## Design review log

2026-09-28, second agent against the code: 11 findings, all accepted and folded into the selected design (nav-away lesson loss; `confirm` refusing common originals; no mechanism for a 2-edit common arm; reverse edit locking a pair; reverse edit adding the wrong term; common aliases triggering asks; review pane double count; timeouts lowering strength; upgrade changing strength for non-editors; weight-only change not re-applied; recase needing a new API; quit path best effort).

## Open

- iOS/Windows adoption notes after the jot-shared change lands.

## Ceiling measurement (2026-09-28, LibriSpeech test-clean, N=100 lists, one learned term at X, rest 3.5)

| X | U-WER (first / hash distractor) | false insertions of 2620 | learned-term recall (control 92.0%) |
|---|---|---|---|
| 3.5 control | 1.982 | 0 | 92.0% |
| 5 | 1.987 / 1.984 | 0 / 0 | 94.1% |
| 6 | 2.019 / 1.997 | 8 / 5 | 95.1% (term starts repeating: "lecture lecture") |
| 7 | 2.200 / 2.038 | 56 / 19 | 95.6% |
| 8 | 3.089 / 2.264 | 251 / 81 | 96.1% (B-WER worse) |

Decision: whole-word learned strength ceiling = **5** (indistinguishable from control). 6 already shows user-visible repeats. Raw files: scratchpad `ceiling/`.

Consequence: whole-word strength alone cannot flip "Claude" on the owner's voice (needs ≈ 7). Next: prototype **pair-targeted** learned bias — the edit gives the exact pair (cloud → Claude), so the extra push applies only at the point where the decoder is spelling the original word and diverges from the term; everywhere else the term stays at its normal weight. Harm is confined to genuine uses of the original, which the up/down edit loop handles. P chosen on LibriSpeech natural misrecognition pairs (tune/test split); owner clips held out.

## Pair-targeted push — first results (2026-09-28)

LibriSpeech natural misrecognition pairs (390 pairs / 327 utts, hash-split TUNE 155 / TEST 172; each utterance given its own pair = "user corrected this before"). Mode `both` (+P on the term's continuation, −P on the original's diverging piece), fires only at the point of divergence, never re-fires right after its own term.

- `both` P=10: TEST recall of the corrected word 0.5% → **45.7%**, 0 over-emissions, 0 collateral false insertions over 2620 utts, U-WER 1.982 → 1.987.
- Cost (by design): a genuinely spoken original becomes the term ~34% of the time — the up/down edit loop corrects this.
- `follow` (keep pushing the term after the flip) rejected: echoes ("seating sitting"), false insertions.

Owner "Claude" clips (held out): still 1/7. The vowel flips on 6/6, but the word never completes: the spoken form is "claud" and the term's silent final "e" is 16–20 logits below blank, so the speculation rewinds to "cloud". Next experiment: near-completion acceptance for pair-pushed speculations only (commit the term when the written word is the term minus ≤ 1 trailing letter / edit distance ≤ 1).

### Near-completion acceptance — result

Pair-pushed speculations only: at a word boundary, if the written word is the term minus ≤ 1 trailing letter (never the pair's own original), commit the term in its own casing.
- `both` P=10 + near-completion: TEST recall 49.5% (vs 45.7% without), 0 over-emissions, U-WER 1.989 (control 1.982), 0/640 word-count changes; one collateral ("honour" → "honors" for pair honours → honors).
- Spoken original converted 41.6% (by design; edit back to lower).
- Owner "Claude" clips (held out): **7/7 clean "Claude"** (was 1/7).
Selected: `both`, P = 10, near-completion variant A.
