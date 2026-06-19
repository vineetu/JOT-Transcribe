# Japanese live preview via batch-pseudo-streaming — research note

> Status: **RESEARCH / DEFERRED.** Implementation intentionally left for later
> (user decision). This note captures the figure-it-out so it's ready to pick up.
> Nothing implemented. Grounded in `jot-kap` code; citations point-in-time.

## Question
Japanese (`tdt_0_6b_ja`) is the only shipping language with **no live in-dictation
preview** (batch-only; the pill is silent until the final pass on stop). Can it get
a preview the same way V3/European will — via the `PreviewScheduler`
(batch-pseudo-streaming, re-run the batch model over a trailing window)? Hypothesis:
"should be similar to V3."

## Answer: yes, same architecture — with two JA-specific deltas.

### What's already the same as V3 (no new work)
- **Engine is model-agnostic.** `PreviewScheduler` re-runs the batch model over a
  trailing window via an injected decode call; it doesn't care which model is loaded.
- **`previewTranscribe` already supports the JA model.** `Transcriber.previewTranscribe`
  routes `.tdt_0_6b_ja` through the same `previewWithAsrManager` path as v2/v3
  (`Transcriber.swift:297`). No early-return/skip for JA.
- **Tunables apply uniformly:** 1 s min window, 5 s volatile timer, 15 s cap, RMS
  pause-commit — all language-independent.
- **No script hint needed:** JA hint is `nil` (`LanguageChoice.swift:137`); the JA
  model ignores the FluidAudio `Language` filter anyway.
- **Vocab deferral is the same pattern.** JA's `JapaneseVocabularySubstituter` runs
  on the **final** pass only (`Transcriber.swift:202-207`); preview shows raw JA and
  the final applies vocab — identical discipline to v2/v3 (vocab deferred to final).
  So preview-vs-final divergence on JA is "final adds vocab," same as English.
- **No casing/filler/number post-processing to worry about:** those are v2/English-only
  (`Transcriber.swift:339`); JA is pure pass-through in preview, well-cased by the model.

### Delta 1 — spaceless join (real, small code fix)
`PreviewScheduler.join(_:_:)` glues the committed tail + volatile tail with a literal
space: `lhs + " " + rhs` (`PreviewScheduler.swift:353-358`). Correct for
Latin/Cyrillic; **wrong for Japanese** (and any CJK) — Japanese text has no
inter-word spaces, so the preview would show spurious gaps at each window boundary.

- The scheduler currently has **no notion of language** — `init(transcriber:)`
  (`PreviewScheduler.swift:133`) takes only a `Transcriber`. There is **no**
  `isCJK`/`spaceless`/`writingSystem` property on `LanguageChoice` or `ParakeetModelID`
  today (verified — none found).
- **Fix shape (deferred):** add a "spaceless" signal — e.g. `LanguageChoice.isSpaceless`
  (`true` for `.japanese`; future-proof for Chinese/Korean if ever added) — and thread
  it into the scheduler (init param or via the model/language already known at the
  factory). `join` then skips the separator when spaceless. Contained: one property +
  one param + one conditional. The final batch transcript is unaffected (this is
  preview-only string assembly).

### Delta 2 — decode quality over short windows (the one genuine UNKNOWN)
Whether `tdt_0_6b_ja` produces **sensible partial transcripts** when re-decoded over
1–15 s growing trailing windows every ~2 s is **untested**. This cannot be answered by
the synthetic `SchedulerSim` (a logic harness with a fake oracle) — it needs **real JA
inference**. Risks specific to JA/TDT on partial audio:
- Mid-utterance windows may cut a word/morpheme boundary mid-kana/kanji, producing
  unstable partials that churn more visibly than space-delimited languages.
- TDT decoding on short clips (sub-1 s already guarded out) — confirm the JA model's
  floor and that 1–2 s windows yield usable text, not noise.

**Validation gate (run when implementing):** build a real-inference JA corpus check —
record/synthesize JA utterances (existing `tools/gen-ja-samples.sh` /
`check-ja-punctuation` can seed this), feed growing windows to
`Transcriber.previewTranscribe(.tdt_0_6b_ja)`, and measure: word/char deletions vs
final, divergence, and partial-stability (how much the preview rewrites itself).
Per the project's audio-verification rule, JA preview must NOT be claimed working until
this is observed on real audio.

## Why JA is the clean case
V3/European already have an (imperfect, English-EOU) preview; JA has **none** and no
EOU bundle exists for it — so `PreviewScheduler` is the *only* path to a JA preview.
That also means JA can't regress an existing preview; it's purely additive.

## Deferred implementation sketch (when picked up)
1. Land the base batch-pseudo-streaming wiring first (flag + route v2/v3 through
   `.batchPreview`) — JA rides on top.
2. Add `LanguageChoice.isSpaceless` (+ thread into `PreviewScheduler`); make `join`
   spaceless-aware. (Delta 1.)
3. Route `.tdt_0_6b_ja` through `.batchPreview` in `JotComposition.transcriberFactory`
   (a few lines; `previewTranscribe` already supports it).
4. Run the real-JA validation gate (Delta 2). Ship only on pass.
5. `ParakeetModelID.supportsStreaming` stays `false` for JA (it means "has a paired
   streaming bundle"); the preview now comes from batch-pseudo-streaming instead.

## Open questions for later
- Partial-stability acceptance threshold for a non-space-delimited language (the
  jitter that's tolerable in English may read worse in JA — may want a slightly longer
  min window or commit cadence for JA).
- Korean/Chinese: not shipped, but `isSpaceless` should be defined to cover them if
  the language set grows.
