# Vocabulary that doesn't overcorrect — port jot-mobile's `VocabularyGate` — Design

> Status: **SCOPE = FULL PORT of the iPhone vocabulary system (user 2026-06-19), GATED on
> multilingual verification.** Not a reduced v1 — the gate, learned overrides
> (`CorrectionStore`), and the feedback/learning UX all come over; replicate across all
> languages. Decisions Q3/Q4/Q6 locked (§6). jot-mobile flows mapped (exploration done —
> the iPhone correction-review UX lives in the *transcript-detail* view, which on macOS maps
> to the **recordings detail** surface, not the streaming pill; the pill chip is only the
> lightweight "vocab acted" signal). **Before building, verify the approach works across all
> ~25 languages → see `verification.md`.** Key finding: the iPhone common-word brake is
> **English-only**, so multilingual is genuinely new R&D. Design only; no code.
> `feedback-ux.md` owns the pill signal; the rich review/learn UX surface is TBD (recordings
> detail), grounded in the mapped iPhone flows.

## 1. Problem
macOS custom vocabulary **overcorrects** — it replaces correct words with vocab
terms ("name"→"Jamy", "and"→"Andre", "Vikram"→"Sriram"). Root cause:
`VocabularyRescorerHolder.rescore()` (`Sources/Vocabulary/VocabularyRescorerHolder.swift:210-221`)
calls `rescorer.ctcTokenRescore(...)` and **discards everything but `.text`** —
any term that scores marginally better on CTC becomes a substitution.
`Transcriber.swift:212-218` accepts it blindly. There is **no safety gate**.

## 2. Why jot-mobile works
Same FluidAudio CTC rescorer, but its output passes through a **`VocabularyGate`**
(`jot-mobile/Jot/App/Vocabulary/VocabularyGate.swift`) before being applied — a
pure-value anti-overcorrection layer. The gate is the whole difference. Its guards
(real `decide(...)` at `VocabularyGate.swift:226-273`):
- **Plausibility:** normalized Levenshtein / skeleton similarity ceiling — rejects
  far-off swaps.
- **Confidence ceiling:** never auto-correct a word the TDT model was very confident
  about (≥0.95) unless the CTC margin wins by a large gap (≥4.0).
- **Common-word guard:** a common-word original is **never** auto-replaced (step 4 →
  BLOCK), backed by a ~24k-word English frequency list (`CommonWords`, names stripped).
- **Earned override:** multi-word terms ("Claude Code") auto-apply; single words apply
  only if low-confidence (≤0.85) or the margin is decisive. Short (≤4-char) terms need
  a higher similarity floor.
- **Learned overrides (step 0):** user "when I say X I mean Y" via a `CorrectionStore`
  overrides the gate for that pair. **NOTE (round 1):** step 0 is the *only* path that
  lets a confident, single-word, common-word original become the term — see §6/§11.

## 3. Load-bearing facts — **SETTLED in round 1** (code-cited)
- **V1 — per-word confidence: CONFIRMED AVAILABLE (the crux holds).**
  `TokenTiming.confidence: Float` is non-optional and is a real per-token softmax
  probability (FluidAudio `AsrTypes.swift:142-147`; populated in
  `AsrManager+TokenProcessing.swift:84-89`). macOS already passes `result.tokenTimings`
  into `rescore(transcript:tokenTimings:audioSamples:)` (`Transcriber.swift:212-218`),
  which is exactly what the gate's `perWordMinConfidence` consumes. **Both repos pin the
  same FluidAudio revision `8048812869b0c…` (0.14.7), so confidence semantics are
  byte-identical.** → The earlier "confidence-fallback if V1 unavailable" contingency is
  **struck** (§6). The only residual is a graceful default the gate already has:
  `confidence = measured ?? lowConfidence` (`VocabularyGate.swift:208`).
- **V2 — `RescoreOutput` shape: CONFIRMED, richer than assumed.** `RescoringResult`
  carries `originalWord, originalScore, replacementWord?, replacementScore?,
  shouldReplace, reason`; `RescoreOutput` carries `text, replacements, wasModified`
  (`VocabularyRescorer.swift:140-154`). Margin = `(replacementScore ?? originalScore) -
  originalScore`. **There is NO per-replacement positional range** — the gate
  re-derives position itself via `nthWholeWordRange(of:in:occurrence:)`
  (`VocabularyGate.swift:122, 364-397`). **→ Port the REAL gate, not the §8 sketch**
  (the real one does occurrence counting + whole-word boundary + positional sort +
  overlap-skip).
- **V3 — stopword/common-word source: CONFIRMED; macOS must ship its own asset.**
  The set lives in jot-mobile app code, not FluidAudio: `CommonWords` loads
  `Resources/common-words.txt` (~24k words) via `Bundle.main.url(...)`
  (`CommonWords.swift:21-43`). **macOS has no `common-words.txt` today.** Per memory
  [[Resources/ is not synchronized in Xcode project]], adding it needs the **4 explicit
  `project.pbxproj` edits** or it builds but is silently missing → `CommonWords.load()`
  logs "DISABLED" and the common-word guard becomes a **no-op**. **This is the #1
  "builds but silently broken" trap in the port — call it out in the implementation
  ticket.**
- **V4 — gate is NOT a clean copy; three jot-mobile-only deps to sever.** Core logic is
  `Foundation`-only and portable, BUT `VocabularyGate.swift` references:
  (1) `DiagnosticsLog.record(...)` (`:133`) → remap to macOS `ErrorLog`
  (`Sources/App/ErrorLog.swift`) or drop (v1 is log-only);
  (2) `CorrectionStore.OverrideEntry` in `apply(...)`/`decide(...)` signatures
  (`:92, :200, :226-238`) → **remove the `overrides` param and step (0) entirely** for
  the stateless v1 (this is surgery on `decide(...)`, not a stub);
  (3) `CommonWords` → port the enum + asset (V3). Budget for real edits + re-test;
  do not treat as a file copy.

## 4. Goals / Non-goals
**Goals**
- Stop overcorrection: a vocab term replaces a word ONLY when it's a plausible near-miss
  the model was unsure about (or a decisively-better, multi-word, or user-learned match).
- Reuse jot-mobile's gate (platform-agnostic pure logic) rather than reinvent.
- Preserve current term storage/format (`term: alias1, alias2`) and the CTC rescorer.
- **Surface the applied-correction set** so the pill UX (`feedback-ux.md`) can show
  "vocabulary caught X" — without perturbing delivery timing. **NOTE (round 2):** the gate
  returns `Result{text, applied:Int, blocked:[String], proposals:[Proposal]}` where
  `Proposal{originalWord, term, decision, outcome, confidence, margin, unsure,
  occurrenceIndex, …}` (`VocabularyGate.swift:51-77`). There is **no `earned` field** —
  see §6 for the derived `notable` flag and the real channel.
**Scope = FAITHFUL PORT of the iPhone vocabulary system (user 2026-06-19).** Everything
that works in jot-mobile comes to macOS — the gate **and** learned overrides
(`CorrectionStore`, "when I say X → Y") **and** the correction-feedback/learning UX. Nothing
is deferred to a "v2." The only genuinely-new work is the **macOS UX surface** (the iPhone's
UI doesn't transfer 1:1) and **replicating across all languages** (per-language common-word
dictionaries, §6 Q3). The macOS UX is grounded in the actual jot-mobile flows — see the
exploration findings folded into `feedback-ux.md`.
**Non-goals**
- Re-architecting the rescorer or the CTC model.
- Japanese gating (`JapaneseVocabularySubstituter`, separate + ungated — §9; port later if
  the iPhone gates JA, which it currently does not).

## 5. Options
- **Opt-A (SELECTED): port `VocabularyGate` + gate the rescore output.** Smallest, proven,
  no new deps; the gate is pure value logic copyable into `Sources/Vocabulary/` (after
  the V4 surgery).
- **Opt-B: tune FluidAudio rescorer thresholds only (no gate).** Rejected — a single
  similarity threshold can't express "protect high-confidence common words but allow
  low-confidence near-misses"; that's exactly what the gate adds.
- **Opt-C: LLM-based correction.** Rejected for v1 — heavier, network/provider-dependent;
  the on-device gate already solves the stated problem.

## 6. Selected design + decisions
**Port `VocabularyGate.swift` from jot-mobile** into `Sources/Vocabulary/` (after V4
surgery) and insert it between the rescorer and the applied text.
- **[DECIDED — user 2026-06-19] Port `CorrectionStore` / learned overrides IN FULL** (no
  deferral). Keep `decide()` step (0) — the OVERRIDE path — and its `overrides` param (so
  the V4 surgery is *only* DiagnosticsLog→ErrorLog + CommonWords, NOT removing step 0). This
  is what lets "when I say *Jamie* I mean *Jamy*" auto-apply even for a confident single-word
  name. Port the persistence (`CorrectionStore`) and the propose→confirm→learn loop the
  iPhone uses; the macOS UX for that loop is designed in `feedback-ux.md` (grounded in the
  jot-mobile exploration, not invented).
- **[STRUCK] Confidence-guard fallback** — V1 confirmed available (§3), so the
  "edit-distance + stopword only" degraded mode is removed. Residual: the gate's built-in
  `measured ?? lowConfidence` default if a timing is ever missing for a word.
- **[DECIDED — Q3, user 2026-06-19] Run the gate for ALL languages; common-word guard
  per-language.** macOS routes **all non-JA, non-Nemotron TDT** through `rescore()`,
  including the **multilingual v3** (fresh-install default `.tdt_0_6b_v3_eou_streaming`,
  `TranscriberHolder.swift:132`). The confidence + plausibility + earned-override guards are
  language-agnostic (per-word confidence is the same TDT softmax regardless of language,
  `AsrManager+TokenProcessing.swift`), so the gate runs for every language. The only
  language-specific guard is the **common-word brake** (`CommonWords`), which is English.
  - **Decision:** keep the common-word brake but make it **language-parameterized** — load
    the resolved language's common-word list. **Extend coverage to all languages via
    per-language frequency dictionaries** (user: desktop has the room): either **bundle them
    in the app** (frequency lists compress very well — top-N words per language, gzipped) or
    **download the dictionary alongside the model** when a language is selected. Bundling is
    simpler (no new download path, always present); revisit download-on-select only if app
    size becomes a concern. If a given language's list is missing at runtime, **fall back to
    skipping only the common-word brake for that language** (confidence + plausibility +
    earned-override still protect) — never block the gate.
  - **Plumbing:** thread the resolved language from the `Transcriber` actor
    (`Transcriber.swift:36` `language: LanguageChoice?`) into `rescore()` + the gate's
    `apply`/`decide` (one caller, `Transcriber.swift:214`); `CommonWords` becomes
    `CommonWords(forLanguage:)` loading `common-words-<lang>.txt`. (JA stays out — separate
    ungated substituter, §9.)
  - **Source/maintenance note:** per-language top-N frequency lists are readily available
    (e.g. open frequency corpora); store as one bundled resource set, names stripped, same
    format as today's English list. Each new list needs the Resources/pbxproj inclusion
    (see V3 / [[Resources/ is not synchronized in Xcode project]]).
- **[DECIDED — Q4, user 2026-06-19] Ship behind the master vocabulary toggle, DEFAULT OFF**,
  until a calibration pass. The gate's thresholds are START values
  (`VocabularyGate.swift:28-30`); confidence/margin transfer well (same TDT + FluidAudio rev),
  similarity is orthography-based (transfers). Plan: default-off → validation pass (~20–30
  real Mac dictations; the gate logs every APPLY/BLOCK/OVERRIDE verdict, `:129-142`) →
  eyeball false-block/false-apply → enable. Keep thresholds as named constants in one
  `GateThresholds`.
- **[ADD — round 1 LOW] Port `enrichedAliases`.** macOS `rebuildVocabulary` passes
  `term.aliases` raw (`VocabularyRescorerHolder.swift:144-154`), unlike mobile which
  injects merged-form aliases (`:202, :247-257`). Without it, merged-word plausibility
  ("cloud code" → "ClaudeCode") won't match. Port `enrichedAliases` too.
- **[FIX — round 2 MAJOR] Surface applied set — real shape, real channel.** The earlier
  `{from, to, earned}` + `gated.appliedForUX` was **invented** — the gate has no `earned`
  field and no `appliedForUX`. Real plan:
  - The gate returns `Result{text, applied, blocked, proposals}`. The macOS adapter
    (in `VocabularyRescorerHolder`/`Transcriber`) maps `proposals.filter { $0.outcome ==
    "applied" }` into a UX payload `[{from: originalWord, to: term, notable: Bool}]`,
    **de-duped by `(originalWord, term)`** (proposals are **per-occurrence**, so a term
    applied 3× must collapse to one entry — the de-dup lives in the adapter, not the gate).
  - **`notable` is a derived flag, defined in ONE place** (the adapter): e.g.
    `notable = term.contains(" ") || margin >= earnedMargin(4.0) || resolvedConfidence <=
    lowConfidence(0.85) || decision == .override`. In v1 the gate already BLOCKs the trivial
    high-confidence single-word swaps, so essentially every *applied* correction is already
    `notable` — the flag is belt-and-suspenders in v1 and becomes load-bearing only once
    learned overrides (v2) allow confident applies. (`feedback-ux.md` uses `notable` for its
    anti-annoyance filter.)
  - **Channel [round-2 cross-doc]:** the success pill is **delivery-driven** — it reads
    `delivery.$lastDelivery` and builds `.success` from `DeliveryEvent`
    (`PillViewModel.swift:196-201, 476-490`), NOT `recorder.lastResult`/`lastFallbackNotice`.
    So the UX payload must ride the `DeliveryEvent` (extend `DeliveryEvent.pasted`/
    `.clipboardOnly` to carry it) or be read by `deliveryEvent` from a recorder companion
    set *before* `DeliveryService` publishes. See `feedback-ux.md §3` — that doc owns the
    channel decision; this gate doc only owes the payload mapping above.

## 7. Where the gate plugs in
```
Transcriber.swift:212-218   →  rescore(transcript:tokenTimings:audioSamples:isEnglish:)
VocabularyRescorerHolder.rescore():
    let output = rescorer.ctcTokenRescore(...)        // RescoreOutput (text, replacements, wasModified) — V2
    guard output.wasModified else { return (text, []) }
    let result = VocabularyGate.apply(                // gate INSIDE rescore (like jot-mobile's merge())
        original: transcript,
        output: output,                               // structured — gate re-derives positions itself (V2)
        tokenTimings: tokenTimings,                   // per-word confidence — confirmed available (V1)
        skipCommonWordGuard: !isEnglish)              // §6(b): non-English v3 skips the English guard
    // result: Result{ text, applied:Int, blocked:[String], proposals:[Proposal] }  (real shape)
    log(result.proposals) via ErrorLog                // v1: log-only (each proposal: decision/outcome/conf/margin)
    let ux = result.proposals
        .filter { $0.outcome == "applied" }
        .map { (from: $0.originalWord, to: $0.term, notable: notable($0)) }   // §6 derived flag
        .dedup(by: { ($0.from, $0.to) })              // proposals are per-occurrence — collapse
    return (result.text, ux)                          // ux rides the DeliveryEvent (§6 channel, feedback-ux.md §3)
```

## 8. Implementation notes (port the REAL gate, not pseudo-code)
Round 1 established the real `VocabularyGate` is more defensive than any sketch, so the
plan is **port + adapt**, not re-author:
- Keep `decide(...)`'s **full** structure including **step (0) OVERRIDE** and its `overrides`
  param (learned corrections — ported, not removed).
- Keep `nthWholeWordRange` position derivation, the positional sort, and the overlap-skip
  (it skips overlapping replacements without emitting a proposal — `:156, :164`).
- Remap `DiagnosticsLog` → `ErrorLog`; port `CommonWords` + per-language dictionaries
  (+ pbxproj); port `enrichedAliases`; **port `CorrectionStore`** (persistence for learned
  overrides) and its propose→confirm→learn loop (macOS UX in `feedback-ux.md`).
- Keep thresholds in a named `GateThresholds`; master toggle default-off pending calibration.
- Gate stays **pure value logic** (no AppKit/Observable) so it remains unit-testable and
  copy-shareable with jot-mobile.

## 9. Edge cases (real gate already handles the first four)
- **Missing per-word confidence:** `measured ?? lowConfidence` default (`:208`) — gate
  still runs (no longer a fallback *mode*, just a per-word default).
- **Empty/short transcript:** `apply` early-returns on `!wasModified || replacements.isEmpty`
  (`:95-97`); `perWordMinConfidence` handles empty timings.
- **Overlapping replacements:** positional sort + overlap guard skips without proposing
  (`:156, :164`).
- **Term longer than utterance / merged words:** handled by `enrichedAliases` merged-form
  injection (port it, §6) + skeleton normalization dropping spaces (`:300-304`).
- **Multi-occurrence:** gate per occurrence, log each verdict; de-dupe `from→to` for UX (§6).
- **Multilingual v3 (default model):** English common-word guard is meaningless for
  non-English — resolved by §6's [DECIDE] (recommend: run gate, skip common-word guard
  for non-English).
- **Nemotron path:** never calls `rescore()`, returns `confidence: 1.0`
  (`Transcriber.swift:357-378`) — gate simply never runs there. Correct, no action.
- **JA path:** `JapaneseVocabularySubstituter` is naive longest-alias-first substring
  replace, no margins/timings (FluidAudio returns a plain `String`, not `ASRResult`) — the
  gate **cannot** guard it. Out of scope v1; flag as follow-up. (It can still substring-
  overcorrect on user aliases, but that's an authored-alias problem, not the CTC bug.)

## 10. UX coupling (downstream — `feedback-ux.md`)
The pill feedback design depends on the adapter (§6/§7) mapping the gate's `Result`
into a `{from, to, notable}` applied set (`notable` = the **derived** multi-word /
decisive-margin / low-confidence / override flag, defined once in the adapter — NOT a
gate field). Requirements:
- The applied set must reach the pill via the **`DeliveryEvent`** channel — the success
  pill is delivery-driven (`PillViewModel.swift:196-201, 476-490`), not result-driven, so
  the earlier "`lastFallbackNotice` mirror" was wrong. Either extend `DeliveryEvent` to
  carry the payload or have `deliveryEvent` read a recorder companion set *before*
  `DeliveryService` publishes. `feedback-ux.md §3/§10` owns this [DECIDE]; delivery timing
  must be unchanged either way.
- Order by source position; de-dupe identical `from→to` in the adapter (proposals are
  per-occurrence).
- If surfacing the full set is hard, the documented graceful fallback is a `count` only.

## 11. Maintainability / risk summary
- Pure-value gate, thresholds in one place — re-tune target documented (§6).
- Top risk: **`common-words.txt` silently absent** (V3 / pbxproj) → guard no-ops. Verify
  bundle inclusion at runtime (log "DISABLED" is the tell).
- v1 deliberately ships **default-off** until a Mac calibration pass; learned-overrides
  deferral removes confident-single-word correction (documented, not hidden).

## 12. Review log
- **Round 1 (adversarial, vs code).** Verdict: *sound to implement after fixes.* Folded in:
  V1 **confirmed available** → struck the confidence fallback (§3, §6); V2 confirmed
  richer + **no positional range** → port the real gate, not the sketch (§3, §8); V3
  `common-words.txt` asset + **4 pbxproj edits** flagged as the top silent-failure risk
  (§3, §11); V4 **three deps to sever** (DiagnosticsLog→ErrorLog, remove CorrectionStore
  step 0 + param, port CommonWords) — it's surgery not a copy (§3); [HIGH] deferring
  learned overrides **removes a correction capability** (confident single-word names),
  documented (§6, §2); [MEDIUM scope bug] **multilingual v3 is the default** and the
  English common-word guard mis-applies → new [DECIDE] (§6, §9); [MEDIUM] ship
  **default-off + calibration pass** (§6, §11); [LOW] **port `enrichedAliases`** for
  merged-word plausibility (§6); JA + Nemotron scope-out confirmed correct (§9).
- **Round 2 (confirming, vs code in both repos).** Verdict: *implementable, but not
  as-the-pseudo-code-reads.* All round-1 load-bearing facts (V1–V4, the [HIGH] step-0
  consequence, the scope bug, [LOW] enrichedAliases, JA/Nemotron scope-out, single rescore
  caller, preview path unaffected) **re-verified** against code; FluidAudio rev pin confirmed
  byte-identical in both repos; all four thresholds (0.95/0.85/4.0/0.45) match. Folded in the
  one substantive new hole: (MAJOR) **`earned`/`appliedForUX` was invented** → real shape is
  `Result{text, applied, blocked, proposals}` with `Proposal{… decision, outcome, confidence,
  margin, unsure …}`; `notable` is now a **derived** flag mapped in the adapter, and the UX
  payload rides the **`DeliveryEvent`** (success is delivery-driven), §6/§7. Also: (MINOR)
  default-model citation corrected to `.tdt_0_6b_v3_eou_streaming` /
  `TranscriberHolder.swift:132`; (MINOR) resolution (b) needs a `language`/`isEnglish` param
  on `rescore()` + gate (one caller — safe), §6/§7; (MINOR) noted per-word confidence is
  valid cross-language, grounding (b) over (a).
- **Round 3:** not needed for the gate — round-2 confirmed sound; remaining items are
  implementation notes. The `earned→notable` + delivery-channel fix is mirrored in
  `feedback-ux.md` (its own round 1).
