# Speaker diarization: pyannote/VBx → NVIDIA Nemotron 3 Diarization

Status: design, 2026-09-24. Owner decision: replace outright, no fallback.

## Why

Local benchmark (scratchpad `diarization-bench/REPORT.md`, independently re-scored):

| | pyannote c-1 + VBx (today) | Nemotron 3 fast128 |
|---|---|---|
| AMI test (8 mtgs) speaker confusion | 10.1 % | 0.9 % |
| AMI exact speaker count | 6/8 | 7/8 raw, 8/8 after filter |
| User's long recordings called multi-speaker | 17/62 | 43/62 |
| Solo dictations falsely multi (after 6 s gate) | 0/36 | 1/36 (0/36 with the projection below) |
| Speed (M2 Pro) | 230× | 254× |
| Model | 21 MB | 190 MB |

VBx collapsed whole meetings to one speaker (AMI TS3003a 4→1; user's Jun 10 69-min and
Jun 1 57-min recordings → 1). Vineet listened to the disagreement clips: Nemotron was right
("perfectly"). Nemotron separates speakers inside one mixed audio stream, which VBx could not.

## Decisions

**D1 Engine.** FluidAudio **0.17.4** (tag 21493f8d) `Nemotron3Diarizer` with
`Nemotron3Config.fast128` (monolithic/v2 bundle, ANE-fixed). App and `jot` CLI. No fallback;
VBx/pyannote code paths and models are removed. Hard cap of 8 speakers is accepted.

**D2 FluidAudio bump (whole app).** Both pins move together: `Jot.xcodeproj` (exactVersion),
the app `Package.resolved`, `tools/jot-cli/Package.swift` + its `Package.resolved`.
Required code change: `DownloadUtils` → `ModelHub` / top-level `ProgressHandler` in
`Sources/Transcription/ModelDownloader.swift` (4 sites; comments too). ASR model caches are
unchanged (no re-download). Transcription output can shift (Parakeet long-form defaults,
Nemotron native mel, vocab rescorer defaults) → full dictation regression pass required.
- Quiet FluidAudio's logger at app and CLI start (its default is `.debug` mirrored to
  console, and debug lines can include recognised words — privacy).
- NemoTextProcessing (~8 MB) gets linked; accepted (opting out isn't exposed to Xcode
  package references).
- Verify the multilingual Nemotron ASR repo still ships `preprocessor.mlmodelc`
  (`ModelCache.swift:220` requires it). If gone, fix the readiness check so fresh installs
  don't read as "not downloaded".
- CLI `--vad`: Silero moves v6.0.0→v6.2.1. The CLI must not start downloading on its own:
  make `jot setup` fetch the new VAD, and make `--vad` fail with the setup hint if missing.

**D3 Engine adapter.** New Jot-owned type `DiarSegment { speakerId: String, start: Double,
end: Double, meanProbability: Float }`. `DiarizerHolder.process` returns `[DiarSegment]`
(already exclusive, see D4). Nothing else in the app imports FluidAudio diarization types.
`TimedSpeakerSegment` disappears from `DiarizationTimelineBuilder` and its tests.
- `Nemotron3Diarizer` is a synchronous, non-Sendable class: create per run, call
  `processComplete(samples)` off the main actor inside the existing `CoreMLInferenceGate`
  acquire/release. Cancellation is checked before and after (a 1 h file blocks ~14 s).

**D4 Exclusive projection (new, shared logic app + CLI).** Nemotron segments overlap; every
downstream stage (coalesce, `SegmentSlicing.sliceBounds`, import transcript rewrite) assumes
exclusive runs — overlap would transcribe the same words twice. Project from
`processComplete`'s per-frame probabilities (10 ms, 8 slots): each frame belongs to the
argmax slot among slots with p > 0.5, else silence; contiguous frames → segments;
`meanProbability` = mean of the owner's p over the segment. Speaker ids are `"S<slot+1>"`
in slot order (display labels are assigned later by first appearance, unchanged).
Bench (proxy projection): solo false-multi 1/36 → 0/36, the 3-speaker test clip (both copies) keeps 3 speakers,
AMI confusion 1.06 %.

**D5 Filters (DiarizationTimelineBuilder).** Delete `smoothIsolatedSegments` — it was a
VBx-noise patch, its quality gate is vacuous for Nemotron, and it deletes real speakers
(u4330 3→2). Keep: 6 s solo gate (largest secondary speaker), 6 s phantom fold, 0.5 s
adjacent merge, full coalesce. The CLI gets the same projection + solo gate + fold (today it
only merges).

**D6 Models on disk.** Download via `Nemotron3Models.loadFromHuggingFace(config: .fast128,
cacheDirectory: <AppSupport>/Jot/Models/Diarizer, computeUnits: .all, progressHandler:)` →
`Diarizer/nemotron-3-diarization/`. "Downloaded" = `monolithic/v2/Nemotron3Diarizer_fast128
.mlmodelc/coremldata.bin` + `learnable_sil_emb.bin` + weights marker present. Triggers are
unchanged (Detect speakers, auto-diarize on import, Settings "Download"). On first
diarizer-holder init after update, delete the old `Diarizer/speaker-diarization/` folder and
any stale `owner-voiceprint.json` (one-time, best-effort). CLI never downloads during
`transcribe`: it loads from the same folder (note: `learnable_sil_emb.bin` sits at the repo
root, one level above `monolithic/v2` — use the loader that handles that) and
`jot setup --components diarizer` fetches Nemotron instead of pyannote.

**D7 Existing data.** Stored `speakerTimeline`s and user renames stay as they are. Running
"Detect speakers" again uses Nemotron. No migration.

**D8 Copy.** Drop the "only clean, separate audio / not a room mic" scoping everywhere;
say it works on one-mic meetings and calls, up to 8 speakers, ~190 MB one-time download.
Sites: `SpeakerLabelsPane.swift:50,68,129`, `RecordingDetailView.swift:1085,1226`,
`AdvancedContent.swift:298-300`, `Resources/help-content-base.md:51` (re-run the 1500-token
budget), `docs/features.md:182,423`, CLI `main.swift:56-60,238`, `DiarizeEngine.swift:13-14`,
`Features.swift` doc comment, `DiarizationRunner.swift:9`.

**D9 License.** OpenMDW-1.1, commercial OK, no branding/AUP. Replace the pyannote CC-BY
credit in `SpeakerLabelsPane.swift:129` with "NVIDIA Nemotron 3 Diarization (OpenMDW-1.1)";
add a NOTICE line next to Parakeet; ship the license text at `Vendor/licenses/OpenMDW-1.1.txt`.

**D10 Not doing.** Voiceprints / owner recognition (dropped by owner). Streaming/live
diarization. Hardware gate (peak RSS on a 2 h file 1.34 GB vs VBx 1.14 GB — same class).
Adding the CoreML gate to `NemotronStreamingTranscriber` (pre-existing; the
`recorderIsCurrentlyIdle` fences still apply) — flagged, not changed.

## Verification

1. App builds (default DerivedData — isolated paths have produced phantom FluidAudio errors);
   CLI `swift build -c release`.
2. CLI runtime: `jot transcribe --diarize` on the 3-speaker test clip (expect 3
   speakers) and the Jun 10 recording (expect several); plain batch + `--stream` transcripts
   compared against 0.15.4 output on the same files.
3. In-app DEBUG tests: `SpeakerTimelineTests`, `SegmentSlicingTests`, new projection tests,
   `HelpInfraTests.runAll()`.
4. Developer ID-signed flavor-themed install to /Applications; owner tests: Detect speakers on
   the Jun 10/Jun 1/3-speaker-test-clip recordings, import auto-diarize, plus the dictation regression
   list (short/long Parakeet, Nemotron en + multilingual "there", live preview, vocab,
   Rewrite with Voice, Ask Jot voice) — confirm no ASR re-download.
5. No commit until the owner approves.

## Amendments after design review (2026-09-24)

**A1 (blocker) No lost words.** `SegmentSlicing` gives runs < 1.2 s empty text and pads
slices only ±0.2 s, and the joined slices REPLACE an import's plain transcript. Nemotron
marks intra-turn pauses as silence, so the projection must produce a gap-free exclusive
timeline: silence between two speakers is split at its midpoint; leading/trailing silence
goes to the first/last run; runs shorter than the slicing minimum are folded into the
longer adjacent run (prefer the co-speaker that was also above threshold). Acceptance:
sliced-transcript word count ≥ 98 % of the whole-file transcript on the 3-speaker test clip, the Jun 10
recording, and 2 AMI meetings.

**A2 (blocker) Don't hold the CoreML gate uncancellably.** Use the streaming API
(`appendAudio` / `processBufferedAudio` / `finishStream`, frame-exact with
`processComplete` per its doc comment) in 30–60 s blocks; between blocks check
cancellation and release/re-acquire `CoreMLInferenceGate`, so a dictation waits at most
one block. Verify frame-exactness against `processComplete` on one file.

**A3** CLI offline load: don't call `loadFromHuggingFace` (its stale-cache purge could
delete the app's cache) nor `load(config:directory:)` (wrong assets dir). Build the
`MLModel` from `monolithic/v2/…fast128.mlmodelc` + read `learnable_sil_emb.bin` from the
repo root, then use the public `Nemotron3Models` init. Update `Setup.swift` readiness
checks.

**A4** Sharing: the projection + gate + fold live in ONE Foundation-only file under
`Sources/Diarization/`, symlinked into `tools/jot-cli/Sources/jot/`. The CLI also coalesces.

**A5** Test installs must rebuild `Vendor/jot-cli/jot` (only release.sh does today).

**A6** "Downloaded" compares the marker CONTENT to the weights version.

**A7** Drop `meanProbability` (nothing reads it once smoothing is gone).

**A8** Re-running Detect replaces the stored payload (labels, renames, text edits). When a
timeline already exists, confirm before replacing.

Open (owner machine can't test): ANE placement / load time on M1 and M3/M4.
