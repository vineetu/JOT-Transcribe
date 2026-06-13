# Implementation handoff — batch pseudo-streaming live preview (EOU removal)

**Updated:** 2026-06-13. Tree was reverted to a clean state on the owner's call.
**Execute the canonical plan: `docs/batch-pseudo-streaming/design.md`.** This file is
just orientation + gotchas for a fresh agent.

---

## 0. Situation

Two agents got near-identical tasks (remove EOU, drive the recording-pill preview
from the batch model). One agent (terse brief) **built and tested** an implementation
using FluidAudio's `SlidingWindowAsrManager`. The other (richer brief referencing
jot-mobile's batch streaming) wrote the **canonical design** (`design.md`) choosing a
**port of jot-mobile's `PreviewScheduler`** — the approach the owner confirmed is right
(it tracks the final transcript to ~1.3% vs ~10.9% for the carried-state SDK manager).

**The first agent's code was reverted** (owner chose a clean start over untangling
half-modified files). **The working tree is now back at `HEAD` — EOU intact, nothing
to undo.** Build the canonical approach fresh from a clean tree.

---

## 1. Current tree state

- **Code: clean.** `git status --short` shows only untracked `docs/` dirs (this plan,
  the superseded sibling, two sibling research docs) — no code changes. EOU is fully
  present, as on `main`. There is **no half-done implementation to reconcile**.
- **No `PreviewScheduler` code exists yet** in either repo's main tree (jot-mobile's
  lives only in a worktree — see §4). You are building it fresh.

---

## 2. Why `SlidingWindowAsrManager` was rejected (don't re-propose it)

Verified against FluidAudio 0.14.7 source: `SlidingWindowAsrManager` **carries decoder
state across windows** (`SlidingWindowAsrManager.swift` ~line 421 does
`self.decoderState = state` and threads `previousTokens: accumulatedTokens`). That is the
carried-state algorithm jot-mobile measured at **10.9% mean divergence-from-final (up to
50%) and rejected**, vs **1.3%** for fresh-`TdtDecoderState`-per-tick + trailing-overlap
re-transcription. Since the whole point of removing EOU is preview↔final fidelity, the
carried-state engine reintroduces a milder "transcript changes at stop" effect. Use the
`PreviewScheduler` port. (Full adjudication: `design.md` §8. Superseded sibling design,
kept for its surface map: `docs/pseudo-streaming/design.md`.)

---

## 3. Build the canonical plan (execute `design.md`)

1. **Read** `docs/batch-pseudo-streaming/design.md` fully (esp. §2.2–2.9, §4.1–4.5, §6).
   §4.5 has the complete EOU-removal surface map — use it as your checklist.
2. **Algorithm source of truth:** jot-mobile's
   `/Users/vsriram/code/jot-mobile/.claude/worktrees/batch-only-streaming/Jot/App/Transcription/PreviewScheduler.swift`
   (373 lines — port it). Its lean decode counterpart is `previewTranscribe` in
   `…/batch-only-streaming/Jot/App/Transcription/TranscriptionService.swift` (~:660-710).
3. **New `Sources/Transcription/PreviewScheduler.swift`** (actor): trailing `[Float]` ring
   (cap+5s); RMS pause gate (0.7s silence, silenceRMS 0.005); triggers pause→commit /
   5s timer→volatile / 15s cap→commit / first-tick-fast 2s; 2s duty-cycle min spacing;
   speech-in-window gate; single-flight `inFlight` + `pendingTrigger` latest-wins;
   `quiesce()` fence; retry-not-discard on empty commit (give up after 3 empties at cap);
   cumulative display = committedText + volatileTail. `ingest` is `nonisolated` forwarding
   into a lock-protected ring (so the audio writer queue never blocks). Publish via the
   `onPartial` closure the pipeline already wires into `StreamingPartialStore` — no
   pipeline rewiring.
4. **New `SharedAsrModelsLoader`** (or equivalent): load one `AsrModels`, memoize it, and
   share it between the batch-final `Transcriber` and the preview path so the ~460 MB
   weights aren't duplicated. (`AsrModels` is a struct of `MLModel` refs → sharing is by
   reference. The reverted agent verified this; ~50 trivial lines.)
5. **Add `Transcriber.previewTranscribe(_ samples:) async -> String?`** — fresh decoder
   state per call (the existing batch path already does this), NO `isTranscribing` gate,
   NO vocab rescore, v2-gated post-processing only on v2, return nil for <1s, never throw
   (canonical §2.6 / §4.3).
6. **`DualPipelineTranscriber.StreamingEngine`:** `.eou(...)` → `.batchPreview(PreviewScheduler)`;
   map the four seam methods to begin/ingest/quiesce/cancel (§4.2). **`finishStreaming()`
   MUST `await scheduler.quiesce()` BEFORE the final batch `transcribe`** — `sharedMLArrayCache`
   is module-global; preview and final must never decode concurrently (§4.3.1).
7. **Delete** `Sources/Transcription/StreamingTranscriber.swift` and do the EOU-removal
   surface edits (canonical §4.5): `ModelDownloader` (drop `downloadEouStreamingSide`,
   v2/v3 → single-bundle), `ModelCache` (v2/v3 `streamingPartialCacheURL`→nil, isCached→
   batch-only, drop EOU `streamingBundleExists` branch — **Nemotron cases untouched**),
   one-shot orphan-bundle cleanup, `ParakeetModelID`/`TranscriptionPane`/`VocabularyPane`/
   `BasicsContent`/`help-content-base.md`/`features.md` copy ("EOU" → "live preview"),
   and the `JotComposition` factory arm. **Keep the enum raw values** (`tdt_0_6b_v2_en_streaming`,
   `tdt_0_6b_v3_eou_streaming`) — they're persisted in `jot.defaultModelID`, so redefining
   their *meaning* upgrades existing users with zero defaults migration (§4.5).
8. **Build** until clean compile is the exit criterion (the Swift exhaustiveness checker is
   the real switch-site checklist), then **runtime-verify** per §6.

---

## 4. Gotchas / pre-existing issues (NOT from this feature)

- **Broken test family blocks `build-for-testing`:** `GeminiProbeParserTests`,
  `OpenAIProbeParserTests`, `AnthropicProbeParserTests`, `OllamaProbeParserTests`,
  `TierClassifierTests` don't compile (symbols removed from Sources by commit a087346's
  AI-probe refactor). To run any JotTests, temporarily move those files aside, run
  `-only-testing:` your suites, then move them back.
- **FluidAudio "No such module" SourceKit errors** on edited files are re-indexing noise —
  `xcodebuild` resolves FluidAudio 0.14.7 and builds clean. Ignore them.
- **Build command (isolate DerivedData — parallel agents share the repo):**
  `xcodebuild build -project Jot.xcodeproj -scheme Jot -configuration Debug -derivedDataPath /tmp/jot-<your-stream>-build -destination 'platform=macOS,arch=arm64'`
- **Sony release commit on `main`:** before any `git push public main`, run
  `git log public/main..main` and `git show main:appcast.xml | grep enclosure`; drop any
  `*-sony` release commit (it rewrites the public appcast to an internal playstation host).
- Owner runs many parallel agents (`git worktree list`). Both pseudo-streaming efforts
  landed in the **main** worktree, which is why they collided. The sibling research docs
  (`hardware-capability-matrix/`, `language-based-model-selection/`) are other agents' work
  — leave them alone.

---

## 5. Runtime verification gate (required before "done")

Install the build; record on v2 (English default) and v3 (multilingual); confirm: live
preview text appears and **grows** in the pill during recording (not a rolling fragment);
non-zero audio actually flows; the final/pasted transcript is byte-identical to today's
batch output; Esc cancels cleanly mid-preview; no preview tick runs after the stop fence;
RSS shows no second copy of the model.
