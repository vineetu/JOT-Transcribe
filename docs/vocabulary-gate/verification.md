# Vocabulary gate — multilingual empirical verification plan

> Status: **ACTIVE — verification in progress.** Goal added per user (2026-06-19): before
> committing the full iPhone vocabulary port to macOS, **empirically verify it works across
> all ~25 supported languages** using synthesized + real audio, and produce a concrete
> go/no-go + per-language plan. This doc is the harness + experiment design and the results
> log. Pairs with `design.md` (the port) and `feedback-ux.md` (the UX).

## 0. Why this is genuinely new work (not just a port)
The jot-mobile exploration (folded into `design.md`) found the iPhone's common-word brake is
**English-only** — a single `common-words.txt` (24k English words). The rest of the gate
(confidence ceiling, plausibility/Levenshtein, earned-margin, learned overrides) is
language-agnostic. So **"vocabulary across all languages" has not been solved on iPhone** —
macOS would be first. That makes empirical verification essential, not optional.

## 1. The load-bearing risk — SETTLED (P1, 2026-06-19): CTC is multilingual ✅
**Verdict: the CTC 110M rescorer works acoustically across scripts (Latin/Cyrillic/CJK).**
Real CLI output: "Vikram" surfaced for Spanish (`Bikram`→`Vikram`, margin -6.69), Russian
(`Викрамом`→`Vikram`, -2.33), and Japanese (`viramusanto`→`Vikram`, -3.45). So we proceed
toward a **full per-language port**, not brake-only. **But two pieces are now MANDATORY new
work, gating any per-language "SHIP full":**
1. **Script-native + romaji aliases.** Matching is string-similarity against the *Latin-
   rendered* TDT output, so a bare Latin vocab term matches nothing when v3 decodes native
   script (RU Cyrillic) or romaji (JA). Non-Latin languages need script-native/romaji
   aliases auto-generated or user-provided. (Latin-script languages are fine as-is.)
2. **Per-language common-word brake — empirically required.** Confirmed overcorrection:
   vocab `["Lisa"]` clobbered the real Spanish word **`lista`→`Lisa`** (margin -8.2). The
   rescorer's only built-in guard is a hard-coded **English** stopword list — it does not
   protect ES/RU/JA common words. This validates the per-language-dictionary decision (Q3).
Also: **confidence is language-sensitive** (EN ~1.0, ES/JA ~0.25–0.88) → the gate's
confidence-ceiling needs **per-language calibration**, not one global 0.95.

## 2. Harness — use FluidAudio's own CLI (no custom build)
FluidAudio ships `fluidaudiocli` (`swift run fluidaudiocli …`), which already has every piece:
- **TTS (Kokoro, multilingual):** `tts "<phrase>" --output x.wav` — synthesize planted test
  phrases per language (the user's "use Kokoro" — it lives here).
- **ASR transcribe:** `transcribe x.wav [--model-version v2]` — run Parakeet; inspect output
  + (verify) per-word confidence / token timings exposure.
- **Real multilingual audio:** `fleurs-benchmark --languages en_us,fr_fr,… --samples N` —
  FLEURS is real human speech per language; avoids TTS-quality bias.
- **CTC keyword spotting / vocab boost:** `ctc-earnings-benchmark` — the CTC rescorer path;
  read its harness to learn how to invoke the rescorer with a custom vocabulary.
- Plus macOS **`say`** (covers ~22/25 app languages, zero setup) as a TTS fallback/breadth.

Building now in `/tmp/fa-cli-build` (`swift build --product fluidaudiocli`).

## 3. Test fixtures (per language)
Each language gets a small fixture set, two kinds:
- **Real:** N FLEURS samples (human speech) → measures transcription quality + confidence.
- **Synthetic, planted:** a phrase containing (a) a **vocab target** likely to be misheard
  (a name/jargon, e.g. "Vikram") and (b) **common words that must NOT be overcorrected**
  (the language's "and/the/name" equivalents). Synthesized via Kokoro and/or `say`.
  - Example EN: *"I met with Vikram about the launch, and the name was on the list."*
  - Example ES: *"Me reuní con Vikram sobre el lanzamiento, y el nombre estaba en la lista."*
  - The vocab list under test seeds the target term + aliases; the eval checks the gate
    APPLIES the target where misheard and BLOCKS swaps of the common words.

## 4. Eval metrics (per language)
1. **Transcription sanity** — WER ballpark on FLEURS (is v3 usable for this language at all?).
2. **Confidence availability** — are `tokenTimings.confidence` populated & meaningful?
   (gate precondition; expected language-agnostic, must confirm).
3. **CTC rescore efficacy** (the §1 risk) — does the rescorer correct the planted target?
   does it emit sensible margins, or noise?
4. **Overcorrection rate (raw, no gate)** — how often does the raw rescorer swap a correct
   common word? (sizes the problem the gate must fix, per language.)
5. **Gate efficacy (with per-language dict)** — apply-good rate ↑, overcorrection rate → ~0.
6. **Verdict per language:** SHIP (full) / SHIP (brake-only) / DEFER, with evidence.

## 5. Languages & TTS/audio coverage
App supports 25: English, Japanese, + 23 European (Spanish, French, German, Italian,
Portuguese, Romanian, Polish, Czech, Slovak, Slovenian, Croatian, Bosnian, Russian,
Ukrainian, Belarusian, Bulgarian, Serbian, Danish, Dutch, Finnish, Greek, Hungarian,
Swedish). Coverage:
- **FLEURS** (real audio): most of these (verify exact codes available).
- **`say`**: ~22/25 (missing Bosnian, Belarusian, Serbian — proxy via Croatian/Russian).
- **Kokoro (FluidAudio)**: a subset (confirm which) — use where available for quality.
Gaps get FLEURS-only or proxy coverage; documented, never silently skipped.

## 6. Phases
- **P0 — harness up (in progress).** Build CLI; smoke-test `transcribe` on the en/es `say`
  clips already generated (`/tmp/vocab-verify/audio/`). Confirm transcribe works + whether
  confidence is exposed via the CLI (else read it via a tiny harness around `AsrManager`).
- **P1 — settle the §1 risk (highest priority).** On 3 probe languages spanning scripts
  (e.g. Spanish=Latin, Russian=Cyrillic, Japanese=CJK): run a planted vocab term through
  the CTC rescorer; does it correct non-English? Decide full-vs-brake-only direction.
- **P2 — confidence + raw overcorrection** across all coverable languages (fan out: one
  subagent per language/group, each runs FLEURS + planted fixtures, logs metrics 1–4).
- **P3 — gate + per-language dictionaries.** Source per-language top-N frequency lists,
  wire a language-parameterized common-word brake, re-run; measure metric 5.
- **P4 — synthesize.** Per-language verdict table → concrete plan: which languages ship
  full, which brake-only, dictionary sourcing list, threshold re-tune, coverage gaps.

## 7. Subagent fleet
Once P0/P1 prove the pattern, fan out P2/P3 with **one agent per language** (≈22 in
parallel batches), each: synthesize/fetch audio → transcribe → rescore → (gate) → emit a
structured metrics row. A synthesis agent reduces rows → the §4.6 verdict table. Adversarial
spot-check on any "SHIP full" verdict for a language where TTS quality is suspect.

## 9. P2 SYNTHESIS + concrete plan (2026-06-19) — 22 languages tested

**Verdict matrix** (real `fluidaudiocli` output, v3 + CTC 110M, `say` TTS fixtures):

| Lang | Script | Apply (name surfaces) | Alias needed | Raw overcorrection observed |
|---|---|---|---|---|
| EN | Latin | ✅ | — | (baseline) |
| ES FR IT PT RO | Latin | ✅ all | none | ✅ all (`lista/liste/listă`→`Lisa`) |
| PL CS SK HR | Latin | ✅ all | none | ✅ (PL/HR `lista`; CS/SK `Včera`→Vikram at 0.50 floor) |
| SL | Latin | ✅ | none | re-check (say audio mis-ID'd as Cyrillic) |
| DE NL DA SV FI HU | Latin | ✅ all | none | ✅ DE/NL/SV/HU (DA/FI escaped only by string distance) |
| RU UK BG | Cyrillic | ✅ (with alias) | **Cyrillic translit** | ✅ all (`имя`→Ima etc.) |
| EL | Greek | ✅ (with alias) | **Latin translit** (v3 decodes names to Latin) | ✅ (`όνομα`→Onoma) |
| JA | CJK/romaji | ✅ (with alias) | **romaji + katakana** | gap real (brake needed) |

Not in `say`: **Bosnian, Belarusian, Serbian** — untested; cover via FLEURS or proxy
(Croatian / Russian / Croatian). 

**Three cross-cutting facts the data nailed down:**
1. **Apply works in every language** → full per-language port confirmed (not brake-only).
2. **Overcorrection is universal and threshold-proof.** Good-apply margins and overcorrection
   margins **overlap** (e.g. Romance good −3…−7 vs bad −4…−10), so margin alone cannot
   separate them. **A per-language common-word brake is mandatory** — the single decisive
   finding.
3. **The rescorer ignores word confidence** — it clobbered words at confidence ≈1.0 (PL
   `listę` 1.00, DE `Kind` 0.999, NL `naam` 1.00). Only the *gate's* confidence-ceiling
   uses confidence, so it's the lever that catches these — but confidence ranges are
   **language-sensitive** (EN ~1.0, RU/UK/BG/EL ~0.95–0.99, ES/JA ~0.25–0.88), so the
   ceiling must be **per-language calibrated**, not one global 0.95.

### Concrete plan — 4 mandatory workstreams (evidence-backed)
- **W1 — Per-language common-word brake (the decisive one).** Bundle per-language top-N
  frequency dictionaries (compress well); `CommonWords(forLanguage:)` loads by the resolved
  `LanguageChoice`. Required for ALL languages. Without it, every language overcorrects.
- **W2 — Per-language confidence-ceiling calibration.** The gate's `confidenceCeiling`
  (0.95) and `lowConfidence` (0.85) must vary by language (or normalize confidence first),
  because the distribution shifts per language. This is what blocks the conf≈1.0 clobbers.
- **W3 — Auto script-appropriate aliases for non-Latin.** At vocab-entry time, auto-generate:
  Cyrillic translit (RU/UK/BG), Latin translit (Greek), romaji+katakana (JA). Latin-script
  languages need none. (Users can still add aliases manually, as on iPhone.)
- **W4 — Raise the min-similarity floor (0.50 → per-language higher).** Catches floor-fires
  like CS/SK `Včera`→`Vikram`. Tune with W2 during calibration.

### Caveats to confirm on FLEURS real speech (synthetic-audio artifacts)
- SL: v3 mis-identified `say` Slovenian as Cyrillic — re-check.
- EL: confirm the Latin-decode-of-names behavior on real Greek speech.
- JA: short clips (<3s) return empty; `--language ja` is unsupported (omit the hint);
  Kokoro JA TTS is broken in this build (use `say -v Kyoko`). JA romaji WER is rough —
  validate transcription quality on FLEURS before committing JA.

**Bottom line:** the iPhone feature ports to macOS and extends to all ~25 languages — gated
on W1–W4. W1 (per-language dictionaries) + W2 (per-language confidence) are the substantive
new engineering beyond a straight port; W3/W4 are bounded. Next: P3 = wire a
language-parameterized brake + dictionaries and re-measure overcorrection→~0; P2-FLEURS to
clear the caveats.

## 10. Name-spotting test — English CTC across Latin languages (2026-06-19)
Hypothesis (user): the English CTC, though English-trained, should still spot **names**
(phonetically portable) inside non-English Latin-script speech. Test: 12 varied names × 5
languages (ES/FR/DE/IT/PT), each name checked v3-native vs `--custom-vocab` recovery.

**Per-language recovery (NATIVE+RECOVERED):** FR 83%, DE 83%, ES 75%, PT 67%, **IT 42%**;
overall **70%** (18 native, 24 recovered, 18 missed). RECOVERED margins −10.4…−5.2.
**Zero collateral in all 60 cells** — every failure is a *silent decline*, never a wrong
replacement. The rescorer is conservative and safe.

**Reading it:**
- Bet **holds for DE/FR/ES** (your German edge case included), **decent for PT**.
- **Italian is the outlier (42%) but largely a TTS artifact:** native Italian `say` re-
  phonemizes foreign names into Italian words ("Lo si"=Lucía), dropping v3 output below the
  0.5 similarity floor → the rescorer gets 0 candidates. A real Italian speaker pronounces a
  foreign name closer to source, so **these numbers are a conservative floor** — needs a
  real-speech / better-TTS re-check before concluding IT is weak.
- **Name *shape* predicts failure more than language:** diacritics/length are fine
  (Małgorzata, Thandiwe 5/5); the failures are exotic phonotactics with no Latin analog
  (Nguyen 1/5, Bjørn 2/5). These are exactly where the **ask/learn loop** earns its keep.
- **Net:** ship name-vocab for the strong Latin languages on the English CTC; the ~30% the
  CTC misses are *safe misses* the user can teach (CorrectionStore), improving per user.

### Expanded to 16 Latin languages + Italian diagnosis (2026-06-19) — BET CONFIRMED
Recovery rates (English CTC, name-spotting): FR 83, DE 83, CS 90, RO 90, FI 90, HR 80,
HU 80, ES 75, PL 70, SK 70, SL 70, PT 67, NL 60, SV 50, IT 42, DA 40. **13/16 ≥ 50%;
7 at ≥80%.** Overall ~72%.
- **The 3 weak ones (IT/DA/SV) are a TTS artifact, proven.** Their native macOS voices
  re-phonemize foreign names *below* the 0.5 similarity gate before CTC ever sees them.
  Diagnosis: lowering the floor (0.35/0.20) recovered nothing real and started false-firing
  on verbs; switching to **Kokoro** audio recovered 4/7 Italian misses with no rescorer
  change. So these scores are a **conservative floor** — real human speech renders foreign
  names more faithfully and will score higher.
- **Name *shape* is the real limiter, cross-language:** fragile = exotic phonotactics
  (Nguyen "Ng-", Bjørn "ø+rn", Joaquín "j=/x/"); bulletproof = long vowel-rich names
  (Małgorzata, Thandiwe, Xiomara ~10/11). Diacritics/length don't hurt.
- **New safety finding at scale:** 3/110 collateral, ALL Slavic, all **short function words
  sharing a short name's consonant skeleton** at the 0.5 floor (`Včera`→Vikram, `sam se`→
  Saoirse). Lowering the floor makes this WORSE → the fix is a **higher floor or a
  function-word guard for short proper-noun vocab** (i.e. the per-language common-word brake,
  W1), not a lower floor (W4 amended: raise, don't lower).

**CONCLUSION:** The English CTC spots names across Latin-script European languages — the bet
holds. Ship English now (full port); extend to Latin languages on the same CTC with W1
(per-language common-word brake, which also kills the short-name collateral) + the ask/learn
loop for safe misses; **no script aliases needed for Latin**. Cyrillic/Greek later via our own
transliteration aliases on the stock CTC. Optional: real-speech re-check of IT/DA/SV.

**CONSTRAINT (user 2026-06-19): stay on STOCK FluidAudio — no fork, no maintaining their
code.** Everything we build (gate, `CorrectionStore`, per-language dicts, aliases, review UX)
is our code in `jot` calling stock FluidAudio APIs — confirmed for 1 & 2. **Japanese native
CTC is DROPPED:** the JA repo publishes a `CtcDecoder.mlmodelc` + `vocab.json` (a real CTC
path exists), but wiring it requires a FluidAudio fork → out of scope. JA vocab would only
ride the stock English-CTC + romaji-alias workaround (marginal) → deferred/limited, no special
JA support.

## 8. Results log

### P0 + P1 — harness up + §1 risk settled (2026-06-19)

**Build.** FluidAudio cloned fresh, checked out at the app-pinned commit
`8048812869b0c7c6fa393e564a4fb6f95126ba23` ("fix(asr): add opt-in v3 no-mel decode
arbitration (#604)"), built with `swift build --product fluidaudiocli` → success in
~15s (models already cached). Binary at
`/tmp/fa-cli-build-1781898327/.build/debug/fluidaudiocli`. Default ASR model is **v3**
(multilingual TDT 0.6B). CTC rescorer model = **Parakeet CTC 110M (hybrid)**, 1024-token
vocab, auto-downloaded to `~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml/`.

**Major harness finding — no custom executable needed.** The stock `transcribe` command
already exposes BOTH pieces the plan needed:
- **Per-word + per-token confidence:** `--word-timestamps` (word-level, conf per word),
  `--metadata` (token-level: token, id, start/end, conf), `--output-json <f>`
  (structured: top-level `confidence` + `wordTimings[].confidence`). Confidence is real and
  populated. `TokenTiming.confidence` is the underlying field.
- **CTC vocabulary rescorer with a CUSTOM vocab on a CUSTOM file:** `--custom-vocab <file>`
  where the file is the simple format (`Term: alias1, alias2, …`, one per line). This runs
  the EXACT production rescorer path: `CustomVocabularyContext.loadWithCtcTokens` →
  `CtcModels.downloadAndLoad(.ctc110m)` → `CtcKeywordSpotter.spotKeywordsWithLogProbs` →
  `VocabularyRescorer.ctcTokenRescore(...)` (term-centric; BK-tree off by default). It logs
  each replacement as `'<orig>' → '<term>' (score: <ctc margin>)`. Tunable via
  `--vocab-min-similarity`, `--vocab-cbw`, `--vocab-margin`. `ctc-earnings-benchmark` is NOT
  needed for this — it's hard-wired to the Earnings22 `.dictionary.txt` fixture layout;
  `transcribe --custom-vocab` is the reusable path for the fleet.

**Reusable commands for the fleet:**
```sh
FA=/tmp/fa-cli-build-1781898327/.build/debug/fluidaudiocli
# transcribe + per-word confidence (JSON)
"$FA" transcribe X.wav --output-json out.json --word-timestamps
# transcribe + per-token confidence (stdout)
"$FA" transcribe X.wav --metadata
# run CTC rescorer with custom vocab (vocab.txt: "Vikram: vikram, Викрам, ヴィクラム")
"$FA" transcribe X.wav --custom-vocab vocab.txt          # replacements logged to stderr
# TTS for fixtures: say -v Milena/Kyoko/Paulina -o x.aiff "…"; afconvert -f WAVE -d LEI16@16000 -c 1 x.aiff x.wav
```

**P1 — THE §1 VERDICT: the CTC 110M rescorer is multilingual (acoustically), NOT English-only —
but it matches via string-similarity on the (Latin-rendered) TDT output, so it needs
script-appropriate aliases, and it has NO non-English overcorrection brake.**

Fixtures: planted phrase "I met with Vikram about the launch, and the name was on the list."
(+ translations) via `say`. Vocab under test: `Vikram` (+ aliases). Probe languages span 3
scripts: Spanish (Latin), Russian (Cyrillic), Japanese (CJK→romaji).

| Lang | TDT baseline (planted name surfaced as) | Vocab (aliases) | Rescorer result | CTC margin |
|---|---|---|---|---|
| EN (clean) | `Vikram` (conf 1.00 — already correct) | `Vikram` | **0 repl** (already exact; no spurious fire) | — |
| ES (Monica, garbled) | `convicram` (con+Vikram fused) | `Vikram` | **`convicram` → `Vikram`** ✅ | -8.59 |
| ES2 (Paulina, clean) | `Bikram` | `Vikram` | **`Bikram` → `Vikram`** ✅ | -6.69 |
| RU (Milena) | `Викрамом` (correct, Cyrillic, declined) | `Vikram` (Latin only) | **0 repl** (Latin↔Cyrillic string-sim fails) | — |
| RU (Milena) | `Викрамом` | `Vikram: Викрам, Викрамом` | **`Викрамом` → `Vikram`** ✅ | -2.33 |
| JA (Kyoko) | `viramusanto` (Vikram-san-to, romaji garble) | `Vikram` (Latin only) | **0 repl** (sim below threshold) | — |
| JA (Kyoko) | `viramusanto` | `Vikram: viramu, ヴィクラム` | **`viramusanto` → `Vikram`** ✅ | -3.45 |

**Interpretation of the §1 risk:**
1. **The CTC 110M model emits real acoustic evidence for non-English audio.** It produced
   sensible (negative-but-passing) CTC margins and correctly surfaced the planted name in
   ES, RU, and JA once the alias bridged the orthography gap. So the rescorer is NOT
   English-only at the model level → the **full-port direction is viable** for these scripts.
2. **The matching layer is orthography-bound, not phoneme-bound.** Replacement only fires
   when string similarity between an alias and the Latin-rendered TDT word clears threshold.
   For Cyrillic/CJK where v3 decodes native script (RU) or romaji (JA), a bare Latin vocab
   term matches NOTHING. **Non-English vocab MUST ship with script-native and/or romaji
   aliases** (this is new work; the iPhone gate has none of this).
3. **Overcorrection brake is the real gap (confirms the §1 fallback concern).** Vocab
   `["Lisa"]` clobbered the legitimate Spanish word **`lista` → `Lisa`** in BOTH the garbled
   AND the clean ES clip (margins -8.22 / -8.31). The rescorer's only protections are
   (a) a hard-coded **English** stopword list in `VocabularyRescorer+TokenRescoring.swift`
   (`the/and/is/…`) and (b) min-similarity. Neither protects common words in ES/RU/JA. This
   is exactly the §1 "gate as a safety brake only" need — and it is **per-language and not
   yet built**. Verdict trends toward: **SHIP full for languages where we can source a
   per-language common-word brake + aliases; otherwise the raw rescorer will overcorrect.**

**Caveats / blockers (none hard):**
- All P1 audio is `say` TTS, which mispronounces foreign names (useful here — it MANUFACTURED
  the misheard-target case for ES/JA). P2 should confirm on FLEURS real human speech.
- `transcribe --language ja` returned EMPTY text for the JA clip (v3+lang-hint path); the
  default (no `--language`) path works and yields romaji. Transcription-quality issue, not a
  rescorer issue — flag for P2's metric-1 (WER sanity), don't block P1.
- Confidence is clearly **language-sensitive**: EN tokens ~1.00, ES/JA tokens ~0.25–0.88.
  The confidence-ceiling lever in the gate will need per-language calibration (P2/P3).

**Net for the plan:** §1 is settled — rescorer is multilingual-capable, so proceed toward a
full per-language port, NOT brake-only-everywhere. But two pieces are mandatory new work and
gate the "SHIP full" verdict per language: (1) **script-native + romaji aliases** for each
non-Latin language, and (2) a **per-language common-word brake** (the English stopword list
does not generalize and the raw rescorer overcorrects common words like ES `lista`).
