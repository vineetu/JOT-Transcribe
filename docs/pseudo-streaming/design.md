# Pseudo-streaming live preview — replace the EOU model with FluidAudio's SlidingWindowAsrManager

> **⚠️ SUPERSEDED by `docs/batch-pseudo-streaming/design.md` (2026-06-13).**
> That doc is the canonical plan. It chooses a port of jot-mobile's
> `PreviewScheduler` (re-run the batch model with a **fresh** `TdtDecoderState`
> per tick + trailing-overlap re-transcription) over the `SlidingWindowAsrManager`
> approach specified here. The disqualifying evidence — **verified against the
> FluidAudio 0.14.7 source** — is that `SlidingWindowAsrManager` *carries* decoder
> state across windows (`SlidingWindowAsrManager.swift` writes `self.decoderState
> = state` per window and threads `previousTokens: accumulatedTokens`), which is
> the carried-state algorithm jot-mobile measured at **10.9% mean divergence from
> the final** (up to 50%) and rejected, vs **1.3%** for the fresh-state overlap
> approach. Since the whole point of removing EOU is preview↔final fidelity, the
> carried-state engine reintroduces a milder version of the "transcript changes at
> stop" effect. The EOU-removal *surface* work below (and its built implementation)
> is still valid and reusable; only the **preview engine** (`SlidingWindowTranscriber`)
> is the wrong choice and should be swapped for the `PreviewScheduler` port. See
> that doc's §8 for the full adjudication.

**Status:** SUPERSEDED (engine choice). Targets macOS 14+, Apple Silicon only.
**Author:** design pass, 2026-06-13.
**Scope:** Remove the dedicated EOU 120M streaming model that powers the
recording-pill live preview for the Parakeet v2 and v3 options, and replace it
with **pseudo-streaming** — FluidAudio's `SlidingWindowAsrManager`, which runs
overlapping-window decode on the **same v2/v3 batch weights Jot already loads**.
No separate streaming model, no separate download, no UX redesign.

---

## TL;DR

Today, the two batch+preview options (`tdt_0_6b_v2_en_streaming`,
`tdt_0_6b_v3_eou_streaming`) each load **two** models: the Parakeet v2/v3 batch
model (final transcript) **plus** a separate EOU 120M streaming model (live
preview in the pill). The EOU model exists only to drive the preview, was
deliberately chosen to be *less accurate than the final* so the transcript
doesn't appear to "get worse" at stop (see `docs/plans/v3-eou-pairing.md`), and
costs an extra bundle download (~428 MB on disk for the v3+EOU pairing,
~120 MB for v2) plus its own ANE load.

FluidAudio 0.14.7 (Jot's pinned version) ships a public actor
**`SlidingWindowAsrManager`** whose own header reads *"Uses an offline TDT
encoder with overlapping windows for **pseudo-streaming**."* It accepts
pre-loaded `AsrModels` (the same `AsrModels` Jot already loads for the batch
final), emits a two-tier volatile/confirmed transcript via an
`AsyncStream<SlidingWindowTranscriptionUpdate>`, and is the FluidAudio-intended
public surface for live preview on batch weights.

This plan:

1. Adds a `SlidingWindowTranscriber` actor wrapping `SlidingWindowAsrManager`,
   loaded from the **same `AsrModels`** as the batch final (shared CoreML
   weights → negligible extra RAM).
2. Routes the v2/v3 preview engine through it instead of `StreamingTranscriber`
   (EOU).
3. Deletes the EOU path end-to-end: `StreamingTranscriber.swift`, the EOU
   download/cache logic, and the EOU branches in the composite/factory.
4. Leaves the **final transcript pipeline 100% unchanged** (batch
   `Transcriber.transcribe` with vocab rescoring + v2 post-processing) and the
   **pill UX 100% unchanged** (`StreamingPartialStore` → `PillViewModel` →
   `PillView`).

Net wins: one fewer model to download/load/maintain; preview now uses the
**same weights as the final** (so it's multilingual on v3, not English-only;
and the "transcript got worse at stop" failure mode is *structurally
impossible* because the final sees strictly more context than the windowed
preview); lighter loaded footprint than EOU.

---

## 1. What "pseudo-streaming" means here

The term is FluidAudio's own. There are two distinct families in the SDK:

- **True streaming** (`StreamingAsrManager` protocol → `StreamingEouAsrManager`,
  `StreamingNemotronAsrManager`): separate, cache-aware encoder models
  (EOU 120M; Nemotron 0.6B) that emit partials as audio arrives. These are
  *different model weights* from the batch v2/v3 model. **EOU is the one we're
  removing.**
- **Pseudo-streaming** (`SlidingWindowAsrManager`): runs the *offline batch
  encoder* (the v2/v3 weights) over overlapping windows, trimming consumed
  audio and carrying TDT decoder state forward. FluidAudio docs
  (`Documentation/Architecture.md`, "Sliding Window, Not Stateful Streaming"):
  *"Sliding window gets us pseudo-streaming for free. The cost is some compute
  redundancy in the overlap; the win is no encoder-side cache bookkeeping."*

So "remove EOU streaming, use pseudo-streaming on the batch model" maps exactly
to "drop `StreamingEouAsrManager`, drive the preview with
`SlidingWindowAsrManager` on the v2/v3 `AsrModels`."

### Cost model (why this is safe)

A naive "re-run `AsrManager.transcribe` on the whole accumulating buffer every
N seconds" would be O(n) per update → O(n²) per recording, and FluidAudio's
public `transcribe` resets decoder state internally on the long-audio path.
**We do not do that.** `SlidingWindowAsrManager` encodes only a bounded window
(default 15 s chunk + 10 s left + 2 s right context; the `.streaming` preset
uses an 11 s chunk for lower latency), trims consumed samples, and reuses
`TdtDecoderState` across windows. Per-update cost is bounded by the window
size, not the recording length → ~O(1) per update, O(n) total, plus a fixed
~2 s overlap redundancy. At Parakeet v3's measured ~155× RTFx on M4 / ~47× on
M2, an 11–15 s window costs roughly 70–320 ms of ANE time per update — well
within real-time.

---

## 2. Current state (the surface we're changing)

The EOU live-preview path, end to end:

| Layer | File | What it does |
|---|---|---|
| Model enum | `Sources/Transcription/ParakeetModelID.swift` | `tdt_0_6b_v2_en_streaming`, `tdt_0_6b_v3_eou_streaming` cases; `supportsStreaming`; `displayName`/`detailText` say "EOU live preview"; `approxBytes` counts the EOU bundle |
| EOU wrapper | `Sources/Transcription/StreamingTranscriber.swift` | Actor wrapping `StreamingEouAsrManager` (160 ms chunks); AsyncStream consumer; `setPartialCallback` |
| Composite | `Sources/Transcription/DualPipelineTranscriber.swift` | `StreamingEngine.eou(StreamingTranscriber)` case + init `init(batch:streaming:)` |
| Factory | `Sources/App/JotComposition.swift` (~298–333) | `case .tdt_0_6b_v2_en_streaming, .tdt_0_6b_v3_eou_streaming:` builds `DualPipelineTranscriber(batch:streaming:)` |
| Pipeline | `Sources/Recording/VoiceInputPipeline.swift` | `beginStreamingSession`/`endStreamingSession`, `activeStreamingDual`, sink wiring (~151–153, 327–353, 371–381) |
| Download | `Sources/Transcription/ModelDownloader.swift` (~254–303) | `downloadEouStreamingSide`, `downloadStreamingSide` dispatch, `batchProgressShare` EOU split |
| Cache | `Sources/Transcription/ModelCache.swift` (~59–151) | `streamingPartialCacheURL` EOU dir (`parakeet-eou-streaming/160ms`), `isCached` requires batch+streaming bundles, `streamingBundleExists` EOU required-files |
| Migration | `Sources/Transcription/ModelChoiceMigration.swift` | `runV12EouRenameIfNeeded`, `eouRenameMigratedKey`, pending-download flag |
| Settings | `Sources/Settings/TranscriptionPane.swift` (~327–432) | `sharedStreamingBundleProtection` (EOU shared-bundle delete guard), per-model cache deletion |
| Reset | `Sources/Settings/ResetActions.swift` | preserves `eouRenameMigratedKey` |
| UI bridge (UNCHANGED) | `Sources/Overlay/StreamingPartialStore.swift`, `PillViewModel.swift`, `PillView.swift`, `AudioCapture.setStreamingSink` | pill plumbing — stays exactly as is |

**Not in scope / left untouched:**
- `nemotron_en` (Nemotron-only, the Recommended English option) — a separate
  streaming model, not EOU. `NemotronStreamingTranscriber` stays.
- `tdt_0_6b_v3_nemotron_streaming` (retired migration anchor) — stays.
- `tdt_0_6b_v3`, `tdt_0_6b_v3_int4`, `tdt_0_6b_ja` (batch-only, no preview) —
  unchanged.
- The pill UI and `StreamingPartialStore` contract — unchanged.

---

## 3. Design decisions

### D1 — Scope: remove EOU only, keep Nemotron
The request is literally "remove the EOU streaming." Nemotron-only
(`nemotron_en`) is a different model, is the current "Recommended" pick, and
is not EOU. **Keep it.** Removing it would be a larger, riskier UX change the
request doesn't call for. *(Open for veto — see §8.)*

### D2 — Affected options
`tdt_0_6b_v2_en_streaming` and `tdt_0_6b_v3_eou_streaming` swap their **preview
engine** from EOU to sliding-window pseudo-streaming on their own batch
weights. The enum cases stay (stored `jot.defaultModelID` values must keep
deserializing); only the preview implementation and copy change.

### D3 — Final transcript pipeline unchanged
The authoritative final stays on `Transcriber.transcribe(fullSamples)` — vocab
rescoring + v2 post-processing intact. The sliding-window output is **discarded
at stop** (exactly as the EOU `finish()` return is discarded today). This keeps
final quality byte-for-byte identical to today and preserves "the final is
authoritative."

### D4 — Share `AsrModels` to avoid double weights (the key RAM decision)
`SlidingWindowAsrManager.loadModels(_ models: AsrModels)` constructs an internal
`AsrManager` around the `AsrModels` you pass it. If we load `AsrModels` **once**
and hand the *same* value to both the final `AsrManager` and the sliding-window
manager, the underlying CoreML `MLModel` objects (the ~460 MB of weights) are
**shared by reference**, not duplicated. Extra RAM for the preview is then just
decoder/window bookkeeping, not a second copy of the model.

This requires a small refactor: today `Transcriber` calls `AsrModels.load(...)`
privately. We hoist the load so the composite can share it (see §4.2). If the
refactor proves fiddly, the fallback is two independent loads (more RAM, still
≤ today's batch+EOU footprint) — but the shared path is the target and should
be the default.

### D5 — Sliding-window config (CORRECTED after review)
**Do NOT use `SlidingWindowAsrConfig.streaming`.** Its 11 s chunk + 2 s right
context means the first window only fires after `chunk + right = 13 s` of audio
(`SlidingWindowAsrManager.appendSamplesAndProcess`:
`while currentAbsEnd >= nextWindowCenterStart + chunk + right`). Jot's dominant
use case is short hotkey dictations (3–10 s) — with `.streaming` those would
show **no live preview at all** until `flushRemaining()` runs at stop. The
`hypothesisChunkSeconds` field that the preset's comment implies gives "quick
feedback" is **declared but unused** in the window-firing loop, so it does not
help.

Use a **custom low-latency config** instead:

```swift
SlidingWindowAsrConfig(
    chunkSeconds: 2.0,              // first preview at ~2 s, new window every ~2 s
    hypothesisChunkSeconds: 1.0,   // unused by the engine today; harmless
    leftContextSeconds: 6.0,       // past audio already buffered → accuracy, no added latency
    rightContextSeconds: 0.0,      // lookahead = latency; a draft preview doesn't need it
    minContextForConfirmation: 2.0,// confirm sooner (display-irrelevant for Jot — see below)
    confirmationThreshold: 0.80
)
// v2 ONLY: .applying(tdtConfig: TdtConfig(blankId: 1024))  — see D5a
```

First-preview floor is then ~2 s (vs EOU's ~160 ms word-by-word, vs `.streaming`'s
13 s). Utterances shorter than ~2 s still only get text at stop — acceptable, and
EOU's edge there was marginal anyway. Tune `chunkSeconds` down further (e.g. 1.5)
if 2 s feels laggy in runtime testing; smaller = lower latency but more overlap
compute and rougher per-window text.

**Jot shows `update.text` directly in the pill regardless of the
volatile/confirmed flag** (the pill has no two-tier rendering), so the
`minContextForConfirmation` "stays gray until 10 s" concern does not apply — the
volatile text is displayed as soon as it's emitted.

### D5a — v2 needs an explicit TDT blank token
`SlidingWindowAsrConfig.streaming`/`.default`/custom default to `TdtConfig()` =
blankId 8192 (v3). The config's own doc-comment warns to pass blankId **1024**
for v2 rather than rely on `AsrManager`'s runtime auto-adaptation. So for
`tdt_0_6b_v2_en_streaming` build the config with
`.applying(tdtConfig: TdtConfig(blankId: 1024))`; v3 uses the default.

### D6 — `isCached` / download simplification
For v2/v3 streaming options, "installed" now means **just the batch bundle**.
`isCached` drops the EOU-bundle requirement; download stops fetching EOU. This
also retroactively unblocks any user mid-migration who was pending the EOU
download — they're "installed" the moment their batch bundle is present.

### D7 — Orphaned EOU bundle cleanup
Existing v2/v3+EOU users have a now-unused `parakeet-eou-streaming/` directory
(~428 MB). Add a **best-effort, one-shot** launch cleanup that removes that
directory **only** if no installed model still needs it. Since after this change
*nothing* references the EOU bundle, the guard is "always safe to remove," but
gate it behind a one-shot key and wrap in try? so a failure is silent and
non-fatal. *(Deleting user files — see R5 / §8 for the safety argument.)*

### D8 — Copy changes (not a UX redesign)
`displayName` / `detailText` drop the "EOU" wording (the model is gone):
- v3: "Parakeet v3 (multilingual) + live preview" — and the detail can now
  honestly say the preview is multilingual and matches the final model.
- v2: keep "(deprecated)".
These are string edits; the pill, panes, and wizard structure are untouched.

### D9 — Vocabulary boosting in the preview: out of scope for v1
`SlidingWindowAsrManager.configureVocabularyBoosting` exists, but wiring CTC
boosting into the preview adds risk for a draft surface. v1 leaves the preview
unboosted (the **final** still applies vocab rescoring as today). Flag as a
later enhancement.

---

## 4. Implementation

### 4.1 New `SlidingWindowTranscriber` actor
`Sources/Transcription/SlidingWindowTranscriber.swift` — keeps
`StreamingTranscriber`'s **nonisolated-enqueue + single-serial-consumer**
pattern (the part that guarantees FIFO from the CoreAudio writer queue without
actor-hop reordering — the root cause of a prior 30 s-delay bug, see
`VoiceInputPipeline.swift` sink comments). Only the per-chunk call target
changes from EOU's `process(buffer:)` to the sliding-window's `streamAudio`.

```swift
final actor SlidingWindowTranscriber {
    private var manager: SlidingWindowAsrManager?
    private let config: SlidingWindowAsrConfig    // custom low-latency (D5)
    private let modelsProvider: () async throws -> AsrModels   // shared with final (D4)
    private let continuationBox = ContinuationBox()            // reuse EOU's, [Float]
    private var feedTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?

    func ensureLoaded() async throws {
        if manager != nil { return }
        let mgr = SlidingWindowAsrManager(config: config)
        try await mgr.loadModels(modelsProvider())   // shares MLModels w/ final
        manager = mgr
    }

    func start(generation: UInt64,
               onPartial: @escaping @Sendable (String, UInt64) -> Void) {
        // Per-session [Float] stream FIRST so chunks yielded before load drain in order.
        var holder: AsyncStream<[Float]>.Continuation!
        let stream = AsyncStream<[Float]>(bufferingPolicy: .unbounded) { holder = $0 }
        continuationBox.set(holder)

        updatesTask = Task.detached { [weak self] in
            guard let self else { return }
            do { try await self.ensureLoaded() } catch { return }   // load fail → no preview
            guard let mgr = await self.manager else { return }
            try? await mgr.reset()
            // (A) Install the update continuation BEFORE startStreaming so the
            //     recognizer task can't yield into a nil continuation (#2).
            //     transcriptionUpdates MUST be read exactly once per session.
            let updates = await mgr.transcriptionUpdates
            try? await mgr.startStreaming(source: .microphone)
            // (B) Single serial feed consumer → streamAudio in mic order (#3).
            await self.startFeed(into: mgr, stream: stream)
            for await u in updates {
                if Task.isCancelled { break }
                onPartial(u.text, generation)        // pill shows text as-is (D5)
            }
        }
    }

    private func startFeed(into mgr: SlidingWindowAsrManager,
                           stream: AsyncStream<[Float]>) {
        feedTask = Task {
            for await samples in stream {             // one consumer = FIFO preserved
                if Task.isCancelled { break }
                if let buf = Self.makeBuffer(samples) { await mgr.streamAudio(buf) }
            }
        }
    }

    nonisolated func enqueue(samples: [Float]) {     // called from writer queue, sync
        continuationBox.yield(samples)
    }

    func finish() async -> String? {                 // GRACEFUL: full drain (#4)
        continuationBox.finish()                     // close feed → recognizer sees stream end
        let text = try? await manager?.finish()      // awaits recognizerTask.value (unbounded)
        updatesTask?.cancel(); updatesTask = nil; feedTask = nil
        return text                                  // discarded by pipeline
    }

    func cancel() async {                            // CANCEL: abandon, don't await (#4)
        continuationBox.finish()
        feedTask?.cancel(); updatesTask?.cancel()
        feedTask = nil; updatesTask = nil
        if let mgr = manager { Task { try? await mgr.cancel() } }
    }
}
```

**Why this order matters (review #2/#3/#4):**
- `transcriptionUpdates` reassigns the manager's single `updateContinuation` on
  every access and yields are dropped when it's nil — so read it **once**, and
  **before** `startStreaming` starts the emitting recognizer task.
- A single `feedTask` draining one `AsyncStream` and `await`-ing `streamAudio`
  sequentially preserves mic order; a `Task`-per-chunk would not (actor
  reentrancy reorders).
- **Graceful `finish()` uses the manager's unbounded drain**
  (`recognizerTask?.value`) so no sliding-window inference is in flight when the
  pipeline then runs the final batch `transcribe`. We deliberately do **not**
  copy EOU's 2 s bounded-abandon on the graceful path. **`cancel()`** abandons
  without awaiting (no final follows it, and Esc must stay responsive).

### 4.2 Sharing `AsrModels` (RAM)
Add an injectable-models path so the composite loads `AsrModels` once:

- `Transcriber`: add an initializer / loader that accepts pre-loaded
  `AsrModels` instead of always loading internally (keep the existing
  self-loading path for the batch-only options that don't pair a preview).
- `DualPipelineTranscriber` (or the factory): for v2/v3 streaming options, do
  `let models = try await AsrModels.load(from: batchDir, version:, encoderPrecision:)`
  once, then build `Transcriber(models:)` (final) and
  `SlidingWindowTranscriber(models: models)` (preview) from the same value.

Because model load is async and the factory is currently sync-returning, the
load can stay lazy: both engines call `ensureLoaded()` which resolves the
shared `AsrModels` once behind a coalescing `Task`. Implementation detail to
settle during build; the **invariant** is "one `AsrModels.load`, shared by
reference."

### 4.3 Composite + factory
- `DualPipelineTranscriber.StreamingEngine`: replace
  `case eou(StreamingTranscriber)` with `case slidingWindow(SlidingWindowTranscriber)`.
  Update `startStreaming`/`enqueueStreaming`/`finishStreaming`/`cancelStreaming`
  to dispatch to it. The `.nemotron` case is untouched.
- `JotComposition` factory: the
  `case .tdt_0_6b_v2_en_streaming, .tdt_0_6b_v3_eou_streaming:` branch builds the
  shared-models composite instead of `StreamingTranscriber(bundleDirectory:)`.
  It now needs only the **batch** cache dir (`cache.cacheURL(for:)`), not
  `streamingPartialCacheURL`.

### 4.4 Deletions / simplifications
- **Delete** `Sources/Transcription/StreamingTranscriber.swift`.
- `ModelDownloader`: delete `downloadEouStreamingSide`; in `downloadStreamingSide`,
  v2/v3 streaming no longer have a streaming side (only Nemotron does); fix
  `batchProgressShare` so v2/v3 streaming = 1.0 (batch only).
- `ModelCache`: `streamingPartialCacheURL` returns `nil` for v2/v3 streaming
  (EOU dir gone); `isCached` for v2/v3 streaming = batch bundle only;
  `streamingBundleExists` drops the EOU required-files branch. Keep the
  Nemotron branches.
- `TranscriptionPane.sharedStreamingBundleProtection`: drop the
  `(.tdt_0_6b_v3_eou_streaming, .tdt_0_6b_v2_en_streaming)` EOU-shared-bundle
  rule (they no longer share a bundle). Keep the Nemotron rule. Per-model cache
  deletion for v2/v3 streaming becomes a plain batch delete.
- `ParakeetModelID`: update `displayName`/`detailText`/`approxBytes` (v3 ≈ 461 MB
  batch-only now; v2 ≈ 600 MB). `supportsStreaming` stays `true` for both (they
  still drive the pill — just via pseudo-streaming).

### 4.5 Migration / existing users
- No `jot.defaultModelID` migration needed: the enum raw values are unchanged,
  so a user on `tdt_0_6b_v3_eou_streaming` stays on it — they just get the
  pseudo-streaming preview and stop needing the EOU bundle.
- `runV12EouRenameIfNeeded` and `eouRenameMigratedKey` stay (they migrate the
  retired Nemotron-pairing anchor → the v3 streaming case; still valid). The
  "pending EOU download" flag it sets becomes a harmless no-op once download
  skips EOU. Audit during build; simplest is to leave it.
- Orphaned EOU bundle: best-effort one-shot cleanup (D7).

---

## 5. UX impact (what the user sees)

- **Structure: identical.** Same pill, same "live preview text in the middle
  slot during recording," same expand-on-tap, same model picker rows.
- **v3 preview becomes multilingual.** EOU was English-only; the v3 batch model
  is multilingual, so non-English speakers now get a live preview that matches
  what they're saying. Strict improvement.
- **No "transcript got worse at stop."** Preview and final are the same model;
  the final sees strictly more context (full audio vs. a trailing window), so
  preview→final is a refinement, never a regression. This *removes* the very
  failure mode EOU was introduced to paper over.
- **Feel: slightly chunkier cadence.** EOU streamed ~word-by-word at 160 ms;
  sliding-window confirms in windows with ~2 s right-context lag. The
  `.streaming` config minimizes this; volatile updates keep it lively. This is
  a *feel* change within the same UX, not a redesign.
- **Smaller download.** v3 streaming drops from ~890 MB to ~461 MB; v2 from
  ~720 MB to ~600 MB. Existing users reclaim ~428 MB (v3) once cleanup runs.

---

## 6. Testing

- **Build:** clean compile; exhaustive `switch`es over `ParakeetModelID` and the
  `StreamingEngine` enum are the compiler's checklist that every site is updated.
- **Unit:** dual-pipeline init for v2/v3 streaming builds the sliding-window
  composite; `isCached(v3-streaming)` true with batch-only bundle present;
  download plan for v2/v3 streaming has no streaming side; migration keys
  behave; cleanup removes the EOU dir once and is idempotent.
- **Tests to rewrite (review #6 — these assert EOU semantics D6 inverts; they
  compile fine and fail at runtime, so the compiler won't catch them):**
  `Tests/.../ModelCacheStreamingTests` — drop the `streamingPartialCacheURL(v2/v3) != nil`
  assertions and the EOU-bundle staging/`isCached` flip cases; assert the new
  batch-only `isCached` for v2/v3. Re-check `ModelChoiceMigrationTests`
  (pending-flag tests still pass; flag self-clears at the consumer — verified
  below).
- **Runtime (required — per project rule, audio changes are not "done" until
  observed):** record on v3 and v2; confirm (a) live preview text appears in the
  pill during recording, (b) non-zero audio actually flows (the silent-capture
  failure mode), (c) the final transcript matches today's quality, (d) Esc
  cancel mid-preview is clean, (e) no second copy of the model in memory
  (Instruments / RSS check on an 8 GB M1 if available), (f) Nemotron and
  Japanese options still work unchanged.
- Help-doc budget check + `HelpInfraTests.runAll()` still pass (copy edits only).

---

## 7. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Double model weights in RAM** if `AsrModels` isn't actually shared. | D4: load `AsrModels` once, pass same value to both managers. **Verified:** `AsrModels` is a struct of `let MLModel` references; `AsrManager.loadModels` just assigns them — no copy/re-specialize → weights shared by reference. Confirm with an RSS check. Fallback (two loads) still ≤ today's batch+EOU. |
| R8 | **Shared module-global `sharedMLArrayCache`** between the preview and final managers (review #1). | It's a scratch-buffer pool, not model state — contention/`clear()` only costs re-allocation, not correctness. Mitigation: **never call `SlidingWindowAsrManager.cleanup()` while the final manager is loaded** (the wrapper calls `cancel()`/`finish()`, never `cleanup()`); preview and final don't predict concurrently (R2). |
| R2 | **ANE contention** if a sliding-window inference overlaps the final batch pass. | `finish()` awaits the recognizer task before the pipeline runs the final (ordering already enforced by `endStreamingSession` → final `transcribe`). |
| R3 | **Chunkier preview cadence** vs EOU's word-by-word. | `.streaming` config (11 s chunk); publish volatile updates. Acceptable per "don't change UX" = don't redesign; flag for sign-off. |
| R4 | **Heavier ANE/battery during recording** (0.6B encoder vs EOU 120M). | Low duty cycle (70–320 ms per window, run every few seconds at ~47–155× RTFx). Validate thermals on M1/8 GB. |
| R5 | **Cleanup deletes the wrong directory.** | Only ever removes the literal `parakeet-eou-streaming` cache dir, gated one-shot, `try?`, after confirming no model references it (post-change: none do). |
| R6 | **`runV12EouRenameIfNeeded` pending-EOU-download flag** strands a user. | Download now skips EOU; the flag becomes a no-op. Audit; leave or retire the flag. |
| R7 | **`SlidingWindowAsrManager` behaves differently than EOU at session boundaries** (reset/cancel/finish). | Mirror EOU's bounded-wait teardown; prior in-repo art exists (`streaming-test/variant-1-streaming-live` already drove `SlidingWindowAsrManager`). |

---

## 8. Open decisions for sign-off

1. **Keep Nemotron-only (`nemotron_en`)?** This plan keeps it (D1). If the
   intent is "one model family, pseudo-streaming everywhere," Nemotron-only and
   the retired Nemotron-pairing anchor would also be removed — bigger blast
   radius, loses the Recommended English option. **Recommendation: keep.**
2. **Delete the orphaned EOU bundle on disk?** Recommendation: yes, best-effort
   one-shot (D7). Alternative: leave it (zero risk, wastes ~428 MB until a
   manual model delete).
3. **Sliding-window config:** `.streaming` (11 s, recommended) vs `.default`
   (15 s, more context, more lag).

---

## 9a. Adversarial review outcomes (incorporated)

An independent review verified the plan against FluidAudio 0.14.7 + Jot source.
Validated findings, all now folded in:

1. **Config (the big one):** `.streaming` preset gives **no preview for sub-13 s
   dictations** → replaced with a custom 2 s-chunk / 0 s-right config (D5).
2. **`transcriptionUpdates` ordering:** read once, before `startStreaming`, or
   early updates drop (§4.1 (A)).
3. **FIFO audio feed:** `streamAudio` is actor-isolated → keep the
   nonisolated-enqueue + single-serial-consumer pattern (§4.1 (B)).
4. **Teardown:** graceful `finish()` uses the unbounded drain (not EOU's bounded
   abandon) so no preview inference races the final; `cancel()` abandons (§4.1).
5. **v2 blank token:** pass `TdtConfig(blankId: 1024)` for v2 (D5a).
6. **Tests:** `ModelCacheStreamingTests` assert EOU semantics → rewrite (§6).
7. **Global array cache:** real but benign scratch-pool sharing; don't call
   `cleanup()` on the preview manager (R8).

Verified-and-fine (no change needed): `AsrModels` weight-sharing is genuine
(R1); no double resampling (Jot's 16 kHz mono hits `resampleBuffer`'s fast
path); the stranded `fourOptionDownloadPendingKey` is harmless —
`TranscriberHolder.startPendingMigrationDownloadIfNeeded` clears it when
`isCached` is true (TranscriberHolder.swift:100), which post-change means
batch-bundle-present; enum raw values preserved → no defaults migration;
`SlidingWindowAsrManager` needs no extra CTC bundle for the unboosted path.

Scope reminder from review #8/#9: the `streamingPartialCacheURL`→nil and
`isCached`→batch-only changes apply to the **v2/v3 streaming cases only** —
the `.nemotron_en` / `.tdt_0_6b_v3_nemotron_streaming` branches must stay
intact (the factory and Nemotron `Transcriber` path still depend on them), and
the four coupled cache/download methods must change atomically.

## 9b. Implementation review outcomes (incorporated)

A second adversarial pass reviewed the built code against these invariants and
found two issues that compilation/units couldn't catch — both fixed:

- **Blocker — teardown race on short recordings.** If stop arrives before the
  detached session task has built its `SlidingWindowAsrManager` (the common
  case for 1–2 s dictations), the original `finish()` nil-ed the task handle
  without cancelling it, leaking an ANE-loaded manager whose recognizer waited
  forever for audio. Fixed: `finish()`/`cancel()` now cancel the session task,
  and the task checks `Task.isCancelled` after every setup step and tears down
  any manager it built (`SlidingWindowTranscriber.teardown`). The graceful
  `finish()` still drains the recognizer before the final batch pass.
- **Major — preview was chunk-local, not cumulative.** `SlidingWindowTranscriptionUpdate.text`
  carries only the latest window's words, so forwarding it would make the pill
  show a rolling ~2 s fragment instead of a growing sentence. Fixed: the wrapper
  emits the manager's cumulative `confirmedTranscript + " " + volatileTranscript`,
  matching EOU's growing-preview feel.

Verified-correct by the review: read-once-before-startStreaming ordering;
single-serial FIFO feed; shared-`AsrModels` weight reuse; no `cleanup()` call
(R8); no concurrent preview/final prediction; `SharedAsrModelsLoader`
memoization + generation guard.

**Build status:** app target builds clean; `ModelCacheStreamingTests` (11) and
the four `ModelChoiceMigration*Tests` suites pass; help-doc budget check passes.
(Pre-existing, unrelated: the `*ProbeParserTests` / `TierClassifierTests` family
doesn't compile against current Sources — broken by commit a087346's AI-probe
refactor, not by this work.)

**Runtime verification still required** (per project rule — audio changes aren't
"done" until observed): install the build, record on v3 and v2, and confirm the
live preview text appears and grows in the pill during recording, non-zero audio
flows, the final transcript matches today's quality, Esc cancels cleanly, and
RSS shows no second copy of the model.

## 9. References
- `Sources/Transcription/StreamingTranscriber.swift` — the EOU wrapper being removed.
- `Sources/Transcription/DualPipelineTranscriber.swift` — composite to retarget.
- `docs/plans/v3-eou-pairing.md` — why EOU was chosen (intentionally-worse preview); pseudo-streaming makes that moot.
- `docs/plans/streaming-option.md` — original dual-pipeline + pill design (the UX contract we preserve).
- FluidAudio 0.14.7 `SlidingWindowAsrManager` (`…/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/`) + `Documentation/Architecture.md` ("Sliding Window, Not Stateful Streaming").
- `streaming-test/variant-1-streaming-live/` — prior in-repo spike driving `SlidingWindowAsrManager`.
