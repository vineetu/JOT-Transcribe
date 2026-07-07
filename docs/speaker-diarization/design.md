# Speaker Diarization (offline VBx)

Identify **who said what** in a Jot recording. Offline, best-quality, on-demand.
Runs the FluidAudio **offline VBx pipeline** over a completed recording, splits
the transcript into per-speaker turns, auto-names the device owner's voice, and
leaves other voices as anonymous, renameable `Speaker 2 / 3 / …`.

> This design **replaces** the dormant "Speaker Labels piece A" feature
> (`Features.speakerLabels`, `docs/plans/speaker-labels.md`), which was built
> around the **wrong engine** for this goal — the streaming **Sortformer**
> model (34% DER, 250 MB, per-recording 4-speaker cap) plus a heavy
> nursery-rhyme voice-**enrollment** flow. That path is ripped out; its
> storage + UI + LLM-preservation scaffolding is kept and rewired to VBx.

Status: **design** (post-brainstorm, pre-implementation). No `requirements.md`
exists for this feature; intent is captured inline under "Goal & decisions."

---

## Goal & decisions

User's ask (verbatim intent): *"the best one offered by fluid inference … it
doesn't have to be real time."* Follow-up decisions from the brainstorm:

| # | Decision | Rationale |
|---|---|---|
| D1 | **Engine = offline VBx** (`OfflineDiarizerManager`), FluidAudio pin stays **0.15.4** | 12% DER vs 25–34% for every streaming variant; 120–220× real-time on this machine; ~22 MB models. Empirically validated below. |
| D2 | **Rip out Sortformer** (holder, cache, downloader, diarizer wrapper, enrollment sheet/recorder, `EnrolledIdentity`, live-pill labels) | Wrong model for the goal; enrollment UX is friction the user rejected ("really bad, rip it out"). |
| D3 | **Anonymous speakers, except auto-identify the owner** → label `"User"` (renameable); others `"Speaker 2/3"` | User: *"we have their audios … figure out the user at least … name it User until they rename it. The others is fine."* No enrollment step — the owner's voiceprint is derived implicitly from the existing solo-recording corpus. |
| D4 | **Manual, on-demand** — a "Detect speakers" action in the recording detail view, works on **new + old** recordings | User rejected the meeting-toggle framing and auto-on-stop: *"the user manually goes and does it."* No background per-recording pass in v1. Auto-on-stop is a deferred opt-in (see Deferred). |
| D5 | **Per-recording rename** of any speaker label, persisted to that recording's timeline only | Satisfies "name it User until they rename it" + "others is fine." No global identity store, no retraining. |
| D6 | **Serialize diarization against transcription** via a **shared cross-pipeline gate** (never run both CoreML graphs at once) | FluidAudio issue #661: concurrent ASR + diarizer prediction corrupts shared BNNS state → `EXC_BAD_ACCESS`. **Caveat (verified):** today's `isTranscribing` guard is *internal* to the `Transcriber` actor (`Transcriber.swift:149,169`) — it only stops overlapping *transcriptions*, not a diarize-while-transcribe. A new shared primitive is required (see below). |
| D7 | **Solo-skip uses a dominance threshold**, not a bare speaker count | A real 68-min solo recording produced a **2.8 s phantom "Speaker 2"** (0.1% of speech). Bare `count > 1` would mislabel it. |

---

## Background: what already exists (and what changes)

The integration map (read from code) found diarization is **~2,400 LOC already
in the tree**, dormant behind `Features.speakerLabels = false`
(`Sources/App/Features.swift:19`). The reusable half survives the engine swap;
the Sortformer/enrollment half is deleted.

**KEEP (engine-agnostic, rewire to VBx):**
- `Recording.speakerTimeline: Data?` SwiftData field + the `SpeakerTimelinePayload` /
  `SpeakerTimelineSegment` JSON schema (`SpeakerTimeline.swift:12-31`). Version envelope already present.
- `SpeakerTimelineBuilder.distributeText` / `renderLabeled` / segment-merge helpers
  (`SpeakerTimeline.swift:198-267`) — pure functions on `(label, start, end, text)`, no Sortformer coupling.
- `RecordingDetailView` labeled rendering (per-speaker colored blocks, "Transcript · labeled" header,
  "Show plain" toggle, `RecordingDetailView.swift:240-303`) + playback slider with a time cursor (:157-179, :605-686).
- `RecordingPersister`'s fire-and-forget "attach a timeline to the saved row after the fact" pattern
  (`RecordingPersister.swift:96-145`).
- `RecordingIndexer`'s trickle **backfill sweep** that yields to live dictation (`RecordingIndexer.swift:99-100`)
  — the template for optional library backfill, if ever wanted.
- Label-aware Cleanup/Rewrite: `SpeakerLabelDetector.looksLabeled` + the label-preservation prompt rule
  (`LLMClient.swift:103-108, 835-871`). Engine-agnostic; keep.
- `InfoPopoverButton` + Help deep-link + `InfoCircleAnchorTests` pattern for Settings.

**DELETE:**
- `Sources/Transcription/Sortformer/` (Holder 261, ModelCache 73, ModelDownloader 70, Diag 28, Tests 273 LOC —
  the VBx-agnostic parts of `SpeakerTimeline.swift` move out first, then the Sortformer coupling goes).
- `Sources/Settings/SpeakerLabelsEnrollmentSheet.swift` (282), `EnrollmentRecorder.swift` (182).
- `Sources/Library/EnrolledIdentity.swift` (87), `EnrolledIdentitiesStore.swift` (124) — no enrollment model.
- Sortformer/enrollment refs in `AppDelegate` (incl. the `SpeakerLabelsTests.runAll()` call at
  `AppDelegate.swift:125` and the `SortformerHardwareGate.isSupported` warmup guard at :354),
  `AppSidebar`, `JotAppWindow`, `JotComposition`, `GeneralPane`.
- `SortformerHardwareGate` and its refs (`SpeakerLabelsPane`, `GeneralPane:937`, `AppDelegate:354`).
  **Do NOT touch `HardwareTier`** — that is the *Nemotron* eligibility gate
  (consumed by `LanguageChoice`, `QwenRetirementMigration`, `NemotronMultilingualMigration`,
  `NemotronAutoUpgradeMigration`); deleting it regresses Nemotron. VBx needs no hardware gate at all
  (one lightweight pipeline). At most scrub the stale `SortformerHardwareGate` mentions in
  `HardwareTier.swift:31,98` comments.
- `SpeakerLabelsPane`'s enrollment UI (the pane itself is repurposed; see Settings).

---

## Investigation findings (empirical — `tools/diarize-probe`)

Built a probe against the **pinned 0.15.4** `OfflineDiarizerManager` and ran it
on real + synthetic audio. Raw numbers, this machine (Apple Silicon):

**API & models.** `OfflineDiarizerManager(config:).prepareModels()` then
`process(audio: [Float]) -> DiarizationResult`. Result gives
`segments: [TimedSpeakerSegment {speakerId "S1"/"S2"…, startTimeSeconds,
endTimeSeconds, embedding: [Float], qualityScore}]` plus
`speakerDatabase: [String: [Float]]` (per-speaker **256-d** mean embedding).
Models = segmentation + embedding + PLDA, **~22 MB**, from the same HuggingFace
host Jot already whitelists. Cache directory is configurable (pass Jot's own
model dir). License **CC-BY-4.0** (pyannote community-1) → public-shippable with
an attribution line. `exclusiveSegments: true` (default) guarantees
non-overlapping segments → token→speaker lookup is unambiguous.

**Speed** (process time, excl. one-time ~10 s first-run compile; ~0.2 s warm load):

| Audio | Duration | Process time | Real-time factor |
|---|---|---|---|
| Real note | 43 s | 0.35 s | 125× |
| Real note | 77 s | 0.55 s | 139× |
| Real recording | **68 min** | **18.7 s** | 221× |

**Accuracy / correctness.**
- Synthetic 2-speaker dialog → **2 speakers**, boundaries match the real turns.
- 3 real solo recordings (controls) → **1 speaker each** ✓.
- The 68-min recording → phantom **2.8 s "S2" (0.1% of speech)** → motivates **D7**.

**Owner auto-ID feasibility (the one novel claim — validated).** Extracted the
256-d `speakerDatabase` embedding from 9 real solo recordings + 2 distinct
voices. Cosine-distance separability:

| Metric | Naive (all 9) | Robust (trim 2 outliers) |
|---|---|---|
| Owner → own centroid (max) | 0.578 | **0.182** |
| Centroid → other voice (nearest) | 0.690 | 0.823 |
| **Separation gap** | 0.11 (thin) | **0.64 (wide)** |

Two of the 9 "solo" clips were outliers (`max` owner-owner distance **1.001** —
anti-correlated → almost certainly *not* the owner: a played video, someone
else's memo). A **medoid-trimmed centroid** (drop clips whose mean distance to
the rest is an outlier) collapses owner-cohesion to ≤0.18 and opens a 0.64 gap.

**Conclusion:** owner auto-ID is clean **provided the centroid is built
robustly**, matched **conservatively** (confident-only), and **falls back to
`Speaker 1`** when unsure. A wrong "User" label is worse than an anonymous one.
The gap vs *synthetic* voices is huge; the gap vs a *real* second human will be
smaller — flagged as the dogfooding risk (R1).

---

## Options explored

**Engine (settled by D1).**
- *Offline VBx* — 12% DER, 22 MB, anonymous, post-stop. **Chosen.**
- *Sortformer (dormant)* — 34% DER, 250 MB, named-via-enrollment, streaming. Rejected (D2): worse, heavier, wrong interaction.
- *LS-EEND* — 25% DER, MIT license, streaming. Rejected: worse than VBx, no upside here.
- *Version bump off 0.15.4* — the only post-tag diarizer fix that touches VBx (#735, deterministic re-clustering under `numSpeakers`/min/max constraints) is irrelevant unless we pass speaker-count constraints, which we don't in v1. **Stay pinned** — preserves the carefully-validated ASR side.

**Owner naming (settled by D3).**
- *Fully anonymous* — simplest; but user explicitly wants the owner named.
- *Implicit owner voiceprint from existing corpus* — **chosen**; no enrollment, validated feasible.
- *Explicit enrollment (Sortformer's model)* — rejected (friction the user called out).

**Trigger (settled by D4).**
- *Auto on every stop* — rejected: user wants to press a button, not have a background pass.
- *Meeting toggle (dormant design's framing)* — rejected: *"toggle doesn't make sense."*
- *Manual on-demand, new + old* — **chosen.**

---

## Selected design

### Data flow (on-demand)

```
User opens a recording ▸ taps "Detect speakers"
  │
  ├─ guard: transcription not in flight (D6 serialize); else queue/wait
  ├─ decode recording audio → 16 kHz mono Float32   (existing readMono16kFloat)
  ├─ VBx: result = try diarizer.process(audio: samples)
  │        (lazy prepareModels on first ever run → progress UI; else warm)
  │        ON THROW: .noSpeechDetected / too-short → "No speech / single speaker" state,
  │                  NOT a user-facing error. Guard audio length before process() too. (S4)
  ├─ solo-skip (D7): if not multiSpeaker(result) → show "Single speaker" state,
  │                   store no timeline, done.
  ├─ owner match (D3): ownerLabel(for: eachSpeaker, using: ownerCentroid)
  │                    → "User" if confident, else "Speaker N"
  ├─ align transcript → per-speaker text
  │        Parakeet: token-midpoint over exclusive VBx segments (needs tokenTimings, below)
  │        Nemotron / no timings: proportional split-by-time (existing distributeText)
  ├─ payload = SpeakerTimelinePayload(segments)          [REUSED schema]
  └─ write Recording.speakerTimeline = JSON(payload); refresh detail view
```

### `multiSpeaker` (D7 — dominance, not count)

```
func multiSpeaker(_ r: DiarizationResult) -> Bool:
    perSpeakerSec = sum of segment durations grouped by speakerId
    total = sum(perSpeakerSec.values)
    // Gate on the LARGEST SINGLE non-dominant speaker, NOT the sum of all
    // secondaries (S3): summing lets 3×2 s phantom clusters (=6 s) trip the
    // gate even though no real second voice exists.
    sorted = perSpeakerSec.values.sortedDescending()
    largestSecondary = sorted.count > 1 ? sorted[1] : 0
    return distinctSpeakers > 1
        AND largestSecondary >= max(MIN_SECONDARY_SEC, MIN_SECONDARY_FRAC * total)
    // seed: MIN_SECONDARY_SEC = 5 s, MIN_SECONDARY_FRAC = 0.05
    // the 68-min phantom (single 2.8 s S2) fails both ⇒ treated as solo. Calibrate in V0.
```
Phantom sub-threshold speakers are folded into the temporally-adjacent dominant
speaker (so their transcript words aren't dropped). **Known tradeoff (S3):** a
genuine second speaker who says only one short sentence (< `MIN_SECONDARY_SEC`)
is folded away — i.e. brief real speakers can be missed. This is the inherent
phantom-vs-brief-real tension; the per-largest-secondary gate + a low seed (5 s)
biases toward not inventing speakers. Revisit the floor in V0 with real meetings.

### Owner voiceprint (D3)

*Build (background, off the inference gate's idle windows — NEVER blocks a tapped diarization):*
```
OwnerVoiceprint.build():
    candidates = up to N recent recordings where multiSpeaker(VBx result)==false  // N seed 20–40; NOT bare count==1 (N5)
    embs = [ result.speakerDatabase["S1"] for each single-speaker candidate ]
    kept = medoidTrim(embs)         // drop clips whose mean dist-to-rest > mean+1σ (validated)
    centroid = normalize(mean(kept))   // stored in rho space (see metric note below)
    persist { centroid, builtFromCount, builtAt } in UserDefaults/app-support
    // guard: need >= MIN_CLIPS (seed 5) confidently-solo clips, else "owner unknown" → all anonymous
```
**Timing & the D4 tension (S2, be honest about it).** The build is itself a
batch of 20–40 VBx `process` calls (0.3–18.7 s each → possibly minutes) over
recordings that were never diarized — which is *exactly* the kind of background
pass D4 avoids for the primary flow. Reconciliation: the build is a **one-time,
low-priority, gated, yielding** job (mirror `RecordingIndexer`'s trickle: acquire
the shared inference gate per file, yield to any live dictation, resume when
idle), it is **not** on the tap path, and until it finishes **every speaker
renders anonymous** (the feature is fully usable without it — owner-naming is a
progressive enhancement). A user who taps "Detect speakers" before the centroid
exists gets correct anonymous labels, upgraded to "User" on a later re-tap once
ready. Kick the build off the first time the user opens the repurposed Settings
pane or first taps "Detect speakers" — never at app launch.
*Match (across ALL speakers in a multi-speaker recording — relative, not just absolute):*
```
ownerLabel(speakers):
    // Score every speaker against the centroid; the owner is at most ONE of them,
    // and may be ABSENT entirely (a recording the owner isn't in). An absolute
    // threshold alone false-labels a similar-voiced family member as "User" (S5).
    scored = speakers.map { (spk, distance(spk.embedding, centroid)) }.sortedByDistance()
    best = scored[0]; second = scored.count > 1 ? scored[1] : (nil, +inf)
    isOwner = best.distance <= OWNER_ABS_BAR                    // absolute gate
          AND (second.distance - best.distance) >= OWNER_REL_MARGIN   // clearly-the-closest
    return isOwner ? [best.spk: .owner, others: .anonymous] : allAnonymous
    // Absent-owner and similar-voice cases fall through to all-anonymous. Both
    // seeds (OWNER_ABS_BAR, OWNER_REL_MARGIN) calibrated in rho space in V0
    // against FAMILY / similar voices, not generic strangers.
```

**Similarity metric — score in PLDA-rho space, not raw cosine (verified in source).**
`DiarizationResult.speakerDatabase` and `TimedSpeakerSegment.embedding` are the
**raw 256-d WeSpeaker** vectors (`OfflineReconstruction.buildSpeakerDatabase` just
averages `segment.embedding`; my probe confirmed dim=256). But the pipeline's
*own* speaker-similarity metric is **cosine in the 128-d PLDA-rho space**
(`PLDATransform.transform` 256→128, then `PLDATransform.score`, `PLDATransform.swift:24-96`)
— the discriminatively-trained space built specifically to separate speakers.
Raw-256 cosine *worked* in the feasibility test (0.18 self vs 0.82 other), so it's
serviceable, but PLDA-rho scoring is the more robust choice and directly de-risks
R1 (real second humans). Plan: transform both the centroid clips and the
candidate speaker embedding through the loaded PLDA model and score with
`PLDATransform.score`. `OWNER_MATCH_THRESHOLD` is then calibrated in **rho space**
(seed determined during V0, not the raw-cosine 0.45). Store the centroid in rho
space so matching never re-transforms it. Raw-256 cosine stays as the fallback
only if the PLDA model/`psi` aren't reachable from the public
`OfflineDiarizerModels` surface (to verify in Phase 2).
Owner renders as the user's chosen owner name (default literal **"User"**);
anonymous speakers render `Speaker 2`, `Speaker 3`, … in first-appearance order.
When the voiceprint can't be built (too few solo clips, brand-new user), every
speaker is anonymous — the feature still works, just without the "User" nicety.

### Token→speaker alignment

- **Parakeet TDT** already *produces* `ASRResult.tokenTimings` and Jot currently
  *discards* them after CTC rescoring (`Transcriber.swift:269-277`). Plumbing is
  **less invasive than a protocol change (N3):** `Transcribing` already returns
  `TranscriptionResult` — just add an optional `tokenTimings: [TokenTiming]?`
  field (`TranscriptionResult.swift:9`), populated on the Parakeet path and left
  `nil` for Nemotron. Every `TranscriptionResult` initializer defaults it `nil`
  (compiler-checked ripple). Then assign each token to the VBx segment containing
  its **midpoint** (unambiguous — segments are exclusive).
- **⚠ Alignment operates on RAW tokens, but the stored transcript is POST-cleanup (S7).**
  `tokenTimings` index `result.text` (raw), while the persisted transcript is
  rescored → paragraph-segmented → (v2 only) filler-cleaned / number-normalized
  (`Transcriber.swift:284,309-323`), which *mutates words*. Reconstructing
  per-speaker text from raw-token positions can therefore diverge from the stored
  cleaned transcript (worst on v2). **Design decision needed before Phase 2:**
  either (a) compute per-speaker *time boundaries* from tokens, then split the
  *cleaned* transcript proportionally within each speaker's time span (keeps the
  displayed text authoritative), or (b) accept raw-token per-speaker text and skip
  cleanup on labeled recordings. Seed: **(a)** — boundaries from tokens, text from
  the cleaned transcript. This makes token-timing a *boundary refiner* over
  `distributeText`, not a separate text path.
- **Nemotron / any path without timings** → the existing `distributeText`
  proportional split (accurate to within one word at each boundary). Correct
  enough to ship; the Parakeet boundary-refinement above sits on top of the same
  cleaned-text splitter.

### Rename (D5)

Right-click / long-press a speaker label in the detail view → inline rename or
pick from labels already used in this recording. Rewrites only *this*
recording's `speakerTimeline` (relabel every segment with the old label string).
No global store, no model change. Renaming the owner's label updates the stored
owner name so future recordings default to it.

### Model download & lifecycle

- New `DiarizerHolder` (`@MainActor ObservableObject`) mirroring `TranscriberHolder`:
  `state ∈ {notDownloaded, downloading(progress), ready, failed}`; `prepareIfNeeded()` on first
  "Detect speakers"; `process(samples:)` serialized via the shared cross-pipeline gate (D6).
- **Shared serialization primitive (D6).** Introduce one `actor CoreMLInferenceGate`
  (or a shared `AsyncSemaphore(1)`) that BOTH `Transcriber` and `DiarizerHolder`
  acquire around their `predict` calls. `Transcriber.busy` alone is insufficient
  (it's the transcriber's private flag; a transcription can still start mid-diarize).
  The **owner-voiceprint build** step runs VBx too, so it must acquire the same
  gate — and, because it can span many recordings, it must yield between files so
  live dictation is never starved (mirror `RecordingIndexer`'s trickle/yield).
- Reuse `ModelDownloader`'s `@Sendable (Double)->Void` progress closure and the `TranscriptionPane`
  determinate-bar pattern. Call `OfflineDiarizerModels.load(progressHandler:)` (exposes progress)
  rather than bare `prepareModels()` (does not), then `initialize(models:)`.
- Cache under `~/Library/Application Support/Jot/Models/Diarizer/` (own subdir, parallel to `Parakeet/`),
  passed as `directory:` so FluidAudio nests `speaker-diarization/` inside it.
- No 16 GB hardware gate (that was Sortformer's dual-ANE requirement). VBx is one light pipeline; runs anywhere Jot runs.

### Settings & discoverability

- **There is NO on/off toggle, by design.** A toggle only made sense for the old
  Sortformer path because it ran *live during every recording* and kept a model
  resident in RAM — the switch existed to stop that background cost. Offline VBx
  has **no background cost**: it does work only when the user taps "Detect
  speakers", runs for a fraction of a second, and goes fully idle (no resident
  model, no per-recording pass). There is nothing to switch off, so no switch.
- Repurpose the **Speaker Labels** sidebar pane as **configuration, not a switch**:
  a short explainer, the model download state / "Download (~22 MB)" affordance, the
  owner-name field (default "User"), and an attribution line (pyannote
  community-1, CC-BY-4.0). `info.circle` → Help deep-link (keep `InfoCircleAnchorTests` green).
- The **only** entry point that runs diarization is the **"Detect speakers"**
  button in the recording detail view (D4). Works on new *and* old recordings.
  (If auto-after-transcription is ever wanted, *that* is what would reintroduce a
  toggle — deferred, Phase 4.)

---

## Implementation plan (phased)

**Phase 0 — rip out Sortformer.** Delete the files in "DELETE" above; excise refs
in the 6 App/Settings sites; move the engine-agnostic helpers
(`SpeakerTimelinePayload`, `distributeText`, `renderLabeled`, merge) into a neutral
`Sources/Diarization/` before deleting the Sortformer file. Keep
`Recording.speakerTimeline` + the label-aware LLM prompt. Build stays green with
`Features.speakerLabels` still `false`.

*Rip-out safety (verified against the tree):*
- **No `EnrolledIdentity` rows exist in any shipped build.** Its only writer,
  `EnrolledIdentitiesStore` (:71), sits behind the enrollment UI, which is behind
  `Features.speakerLabels=false`. Verified (N1): `git log -S "speakerLabels: Bool = true"`
  returns nothing — the flag was **never committed as `true`**, so zero production
  rows. Deleting the `@Model` loses no user data.
- **No migration needed.** Schema is lightweight (`Recording.swift:33`, no
  `VersionedSchema`); removing a zero-row entity is safe. Remove
  `EnrolledIdentity.self` from all three `ModelContainer(for:)` sites
  (`JotComposition.swift:511,521,543`) — the compiler enforces completeness once
  the type is gone.
- **No old-format `speakerTimeline` rows in the wild.** The persister's
  diarization branch is gated on `Features.speakerLabels` (`RecordingPersister.swift:114`),
  never fired in a shipped build. The reused `Recording.speakerTimeline` field is
  effectively virgin; the VBx path writes the same JSON schema, so even a
  hypothetical future migration is a no-op.
- **Delete `SpeakerLabelsTests.swift`** (Sortformer-specific) and confirm
  `HelpInfraTests.runAll()` / `InfoCircleAnchorTests` still pass after the Settings
  pane is repurposed (re-point any Speaker-Labels help anchor).

**Phase 1 — VBx engine wrapper.** `DiarizerHolder` + `DiarizerModelCache`
(clone the `ModelDownloader`/cache/holder triple) + a thin
`OfflineDiarizer.process(samples) -> DiarizationResult` seam. Serialize against
transcription (D6). Unit-test `multiSpeaker` (D7) and the solo/phantom cases.

**Phase 2 — timeline build + owner ID.** `DiarizationTimelineBuilder`:
VBx result → merged segments → owner-match labels → aligned text →
`SpeakerTimelinePayload`. `OwnerVoiceprint` build/cache/match (medoid-trim).
Surface Parakeet `tokenTimings` through `Transcribing`.

**Phase 3 — UI.** "Detect speakers" action + progress + solo/single-speaker
state in `RecordingDetailView`; per-speaker rename (D5); repurposed Settings
pane; Help copy + anchor; attribution. Flip `Features.speakerLabels = true`.
- **Localize every new user string from the start (S6)** — Jot ships
  `Resources/Localizable.xcstrings` and already localized the JA UI. "Detect
  speakers", "Single speaker", "Speaker N", the attribution line, and Settings
  copy all go through `String(localized:)` / xcstrings in Phase 3, not deferred.
- **Accessibility (N4):** speaker identity is text ("User", "Speaker 2"), never
  color-only, in the reused labeled rendering; ensure the rename control exposes
  the speaker name to VoiceOver.

**Phase 4 (deferred, opt-in).** Auto-diarize-on-stop setting; library backfill
sweep (reuse `RecordingIndexer` trickle pattern); multilingual owner-name
*passage/prompt* copy (UI strings are already localized in Phase 3).

---

## Risks

- **R1 — owner match vs a real / similar-voiced second human.** Validated
  separability was against synthetic voices (gap 0.64). Real second speakers —
  especially family — sit closer. Mitigation: PLDA-rho scoring + **relative margin**
  (S5) + confident-only + anonymous fallback; calibrate against *family/similar*
  voices in V0, not strangers. Accept that "User" can occasionally surface in a
  recording the owner isn't in until the margin is tuned.
- **R2 — owner centroid poisoned by non-owner "solo" clips.** Real: 2 of 9 were
  outliers. Mitigation: medoid-trim + `MIN_CLIPS` floor + rebuild-on-growth.
  **Sub-risk (S5):** medoid-trim may also discard *legitimate alternate-mic* solo
  clips as outliers, biasing the centroid toward one mic and worsening cross-mic
  match. Watch in V0; if real, keep per-mic clusters instead of one centroid.
- **R3 — BNNS concurrency crash (#661).** Mitigation: hard serialize (D6).
- **R4 — `computeUnits` ignored by offline loader (#742).** Can't force ANE/CPU
  routing at 0.15.4; accept FluidAudio's default. Not blocking (speed is already
  120–220×).
- **R5 — solo-skip threshold miscalibration.** Seed values from one machine;
  calibrate `MIN_SECONDARY_SEC/FRAC` in V0.

## Open questions

1. Owner-name default string — literal **"User"** (D3) vs the macOS full-name vs a
   first-run prompt. Seed: "User", renameable.
2. Does "Detect speakers" also **re-run Cleanup/Rewrite** to reflow labeled text,
   or leave the stored transcript untouched and only add the timeline overlay?
   Seed: overlay only; Cleanup/Rewrite already label-aware if the user re-runs them.
3. Corpus-growth rebuild cadence for the owner centroid (every +K recordings? on
   demand?). Seed: rebuild when `recordingCount` grows ≥50% since `builtFromCount`.
