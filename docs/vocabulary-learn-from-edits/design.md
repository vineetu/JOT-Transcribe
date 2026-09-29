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

---

## Revision 2 (2026-09-29): one correction, one path

### What went wrong

Owner tested after the 09-28 push: still "cloud". `corrections.json` showed zero edit counts for Claude. Only Edit → Done had been wired to learning; the owner corrected through **Add to Vocabulary** and **picking the guessed word**, which weren't. The 7/7 result was the decoder tested in isolation with the pair injected by hand, never the real loop (correct in the app → saved → next dictation). Deeper cause: one correction lived in three places that disagree:

1. the **sounds-like list** (`vocabulary.txt` aliases): visible, but never sent to the Nemotron decoder;
2. hidden **counters** (`corrections.json`): fed the decoder, invisible;
3. each **surface** wrote to one, the other, or neither.

### Decision (Vineet, 2026-09-29)

- **A correction is one thing**: "when I say X, write Y".
- **Stored once, visibly**, as a sounds-like on the term in the vocabulary. Viewable and deletable in Settings.
- **Every surface calls one shared function** in JotVocabCore. No per-surface logic, nothing copy-pasted. iPhone and Windows call the same function.
- **The decoder gets every sounds-like** as a learned pair, including existing ones (e.g. the owner's `claude: Cloud`).
- **Counters only move it up and down**: an explicit keep/edit-back pauses a pair without deleting what the user taught; deleting the sounds-like removes it.

### Inventory of every correction surface (Mac)

| Surface | Code | Today writes | Becomes |
|---|---|---|---|
| Edit → Done | `RecordingDetailView.finishEdit` → `EditLearning.learn` | counters + vocab (inline rules) | `EditLearner` lessons → `Corrections.apply` |
| Add to Vocabulary (select text) | `TranscriptReader` popover `add()` | `addMapping` only | `.correct(heard, term)` |
| Review list: pick term | `CorrectionReviewModel.pick` | provenance + `adjust` | provenance (unchanged) + `.correct` |
| Review list: keep original | `CorrectionReviewModel.pick` | provenance + `noteBlockedKeep` + away | provenance + `.keepOriginal` |
| Review list: undo | `CorrectionReviewModel.undo` | provenance + retract | provenance + `.undo(previous)` |
| Popup: confirm (incl. merge asks) | `AppDelegate` ask `onConfirm` | `confirm` | `confirm` (gate net) + `.correct` |
| Popup: wider-phrase alternate | `AppDelegate` `onAlternate` | `confirm` | `confirm` + `.correct` |
| Popup: keep | `AppDelegate` `onDismiss` | revert / blockedKeep + away | same gate writes + `.keepOriginal` |
| Popup: timeout / outside click | `AppDelegate` `onAccept` | revert / blockedKeep | unchanged; never teaches (review #8) |
| Settings: add term | `VocabularyPane.addTerm` → store | term | `.addTerm(term)` |
| Settings: add sounds-like | `VocabRow` → `VocabularyStore.update` | alias | `.correct(alias, term)` |
| Settings: remove sounds-like | `VocabRow` → `VocabularyStore.update` | alias removed | `.forget(alias, term)` |
| Settings: delete / rename term | `VocabularyStore.delete` / `update` | term | pairs vanish with the term (derived) |

Provenance bookkeeping (review records, verdicts, undo anchors) stays per surface: it's about *which occurrence* in *which recording*, not about learning. Gate `confirm`/`revert`/`blockedKeep` writes stay where they are: they drive the CTC gate's ask/auto-apply, a separate mechanism.

### The one function (JotVocabCore)

```
enum Correction {
  correct(heard, term, heardByModel = true)   // every "write Y when I say X"
  keepOriginal(heard, term)                   // explicit keep / edit back
  undo(Correction)                            // exact inverse of a prior apply
  forget(heard, term)                         // sounds-like deleted
  addTerm(term)                               // plain add, user casing wins
  recase(term)
}

actor VocabularyLearning(list: VocabularyListWriting, store: CorrectionStore)
  apply(correction):
    correct:
      list.addTerm(term); list.recase(term)
      if heardByModel: list.addSoundsLike(heard, to: term)   // the visible record
      store.recordEdit(heard, term, .toward, heardByModel)    // up
      store.recase(term)
    keepOriginal: store.recordEdit(heard, term, .away)       // down, sounds-like kept
    undo:         store.retractEdit(...)                      // inverse
    forget:       store.forgetEdits(heard, term)             // list already removed it
    addTerm / recase: list + store casing

protocol VocabularyListWriting   // seam: each app's vocabulary store
  terms, addTerm, addSoundsLike, recase
```

`EditLearner.learn` is unchanged (pure diff → lessons); the app maps `.substitute` → `.correct`, `.reverse` → `.keepOriginal`, `.recase` → `.recase`. A hand edit where the model never wrote the word (AI cleanup, D11) → `.correct(heardByModel: false)`: term added, no sounds-like, no strength.

Reversal of review #6 (common words not stored as sounds-like): the sounds-like is now the source of truth, so "cloud" is stored. Cost: the CTC gate may ask on a genuine "cloud"; an explicit Keep lowers it. Accepted — the alternative was the invisible-state bug above.

### Decoder inputs (derived, nothing stored twice)

```
pairs(term)  = every single-word sounds-like of term (≥ 3 letters, Latin script)
               minus those whose counters say paused (editsAway > editsToward)
               plus  edit-learned pairs not (yet) in the list
weight(term) = 5.0 if term has any active pair, else 3.5
```

Multi-word sounds-likes ("Vishnu has been") stay CTC-gate-only: the decoder pair push is single-word.

Behaviour change on upgrade: users who already typed sounds-likes get them on the decoder. Intended: they asked for exactly that. Users with no sounds-likes and no corrections see no change.

### Known gap

A paused pair is invisible in Settings (the sounds-like is still listed). Follow-up: show "paused" on the chip.

### Verification (the check skipped on 09-28)

1. Replay harness (`--jot-replay … --jot-replay-teach cloud=Claude`, DEBUG only, sandboxed copy of the owner's vocabulary): the teach calls `VocabularyLearning.apply(.correct)`, the same function every surface calls. Before: "cloud". After: "Claude". Log line `decoder vocabulary applied` shows `cloud→Claude`.
2. Same replay with the owner's current files and NO teach: must already give "Claude" (existing `claude: Cloud` sounds-like).
3. Unit tests in JotVocabCore for every `Correction` case and the pair derivation.
4. Every surface in the inventory table is a one-line call; a grep for `recordEdit|addMapping|retractEdit|forgetEdits` outside JotVocabCore + the list adapter must return nothing.

### Revision 2 review (2026-09-29) — accepted changes

A second agent reviewed Revision 2 against the code and the owner's real vocabulary. Accepted, and these override the text above where they differ:

1. **The list is the only source of decoder pairs.** Dropped "plus edit-learned pairs not in the list". A one-time migration writes existing edit-learned pairs into the list as sounds-likes. A sounds-like deleted anywhere (Settings or a text editor) is gone from the decoder, because nothing else feeds it.
2. **Pair eligibility = sound-alike.** A single-word sounds-like becomes a decoder pair only if it passes the gate's spelling-distance test against the **term alone** (`VocabularyGate.plausible`, 0.45; aliases don't count). A pair whose first letters differ ("chart"→Jot, "beneath"→Vineet, "Benid"→Vineet) would open a push at every word starting with those letters; that was never measured, so they stay gate-only. On the owner's list: cloud→Claude (0.33) is a decoder pair; chart, beneath, Benid, Venith, Vini, Shrida stay gate-only. Measuring different-first-letter pairs on LibriSpeech is a follow-up.
3. **Only hand edits arm the silent replace rule** (D6, §v2-B). `recordEdit` gets `armsTextRule`, true only for Edit → Done lessons. Popup, review pick, Add to Vocabulary and Settings never arm silent replacement of everyday words.
4. **Pair state = last explicit signal wins.** `.correct` → active; `.keepOriginal` / edit back → paused. No count ties. Stored per pair (`pairPaused`). Strength counters stay for Parakeet's text rule only.
5. **`.undo` reverses exactly what `.correct` did.** `apply` returns a receipt (term added?, sounds-like added?, previous casing, previous pair state); the review verdict stores it; undo replays it backwards.
6. **`.correct` keeps the rare-original text rule:** calls `confirm` for a rare original (D6, Parakeet path), unless an open review record carried the count.
7. **Seam shape:** `@MainActor protocol VocabularyListWriting` with synchronous methods; `@MainActor VocabularyLearning.apply(_:) async -> Receipt` does the list write synchronously first, then one awaited store write, so two applies can't interleave their list writes, and Add to Vocabulary gets `.added / .duplicate / .rejected` back. `Correction` is Codable so a keyboard extension can queue one for the app.
8. **Settings:** the sounds-like chip add/remove calls `apply` directly; `VocabularyStore.update` goes back to a plain write (it fires per keystroke).
9. **Decoder inputs come from the vocabulary list itself,** not the CTC holder (which rebuilds asynchronously and is empty when the boost model isn't prepared). Still off when vocabulary is disabled.
10. **Confirm-learned rare mappings** (e.g. vinit→Vineet, net 3) stay gate-only text rules, separate by design; not migrated.
11. **Platforms:** iOS calls the same Swift function; its keyboard queues `Correction`s for the app (the keyboard can't write the app's vocabulary file). Windows is C#: it ports `apply` against shared JSON fixtures, not the same code.
12. **Weight 5.0** applies only to terms with an active decoder pair; with rule 2 that's few terms. Multi-term 5.0 not measured: noted risk.

### Different-first-letter pairs — measured (2026-09-29)

Owner pushback: sounds-likes like chart → Jot and beneath → Vineet are real misrecognitions and should reach the decoder. Measured on LibriSpeech test-clean (push 10 + near-completion), everyday original → rare term with a different first letter:
- **Harm:** each utterance given such a pair whose original is absent but a word starting with the same two letters is present: 21 / 2620 utterances changed (dropped or garbled neighbours, e.g. "the two methods" → "procededs"), U-WER 1.982 → 2.019, 2 false term insertions.
- **Benefit:** original genuinely spoken: converted in 10 / 2497 (0.4%). Same-first-letter natural pairs: ~42%.

Decision: `LearnedPairPolicy.isDecoderPair` requires the same first letter. Different-first-letter sounds-likes stay honoured by the CTC gate (text level, after transcription). Owner list: cloud→Claude, Shrida→Sriram, Venith→Vineet, Vini→Vineet go to the decoder; chart→Jot, beneath→Vineet, Benid→Vineet stay with the gate.

### End-to-end replay (2026-09-29) — the check that was missing

Real app pipeline (`--jot-replay`, DEBUG, sandboxed copy of the owner's vocabulary), all 7 owner "Claude" clips:
- Owner's current files, no new correction: 7/7 "claude" (lowercase — the owner's term is spelled `claude`); name also now "Vineet Sriram" on every clip (was "Vini Sriram" / "Venite Sri Lank").
- After one correction via `apply(.correct(cloud, Claude))`: 7/7 "Claude".
- Log line confirms the decoder received `cloud→Claude`.

### No learned auto-replace rules (Vineet, 2026-09-29)

"There should be no hidden auto-replace rule." Removed entirely: the `alwaysReplace` grant, the hand-edit streak that armed it (D6), and gate step 0's "confirmed rare pair (net ≥ 1) auto-applies". Existing rules were written by earlier agents, not a product decision to keep. What remains:
- **Decoder pairs** from visible sounds-likes (Nemotron Multilingual).
- **The gate's evidence path**: a word changes only when the CTC spotter hears the term in the audio and the steps (plausibility — where a visible sounds-like counts — confidence, everyday-word ask) allow it.
- The only learned signal the gate honours is a **paused** pair (the user kept the original) → never replace.
Confirmation counts stay only as the ask-ranking prior. D6 is void.
