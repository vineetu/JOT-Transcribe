# Batch pseudo-streaming live preview — port jot-mobile's `PreviewScheduler` to macOS

**Status:** design (not yet built). Targets macOS 14+, Apple Silicon only.
**Author:** design pass, 2026-06-13.
**Origin of the request:** "EOU sucks, remove it entirely; we did batch streaming
which is super cool — just using the batch model." (Bring jot-mobile's
batch-pseudo-streaming live-preview technique to macOS Jot.)

> **CANONICAL PLAN. This doc SUPERSEDES `docs/pseudo-streaming/design.md`.**
> Both docs target the same goal (remove the EOU model, drive the pill preview from the
> batch weights). The earlier sibling proposed FluidAudio's built-in `SlidingWindowAsrManager`;
> an independent reviewer adjudicated the fork **in favor of the `PreviewScheduler` port
> specified here**, on hard evidence (the SDK manager carries decoder state across windows —
> the exact algorithm jot-mobile measured at 10.9%–50% divergence-from-final and rejected;
> see §8). This doc folds in all the genuinely-correct material from the sibling (the
> end-to-end EOU-removal surface map, the preserved-raw-value migration insight, the
> first-preview-latency lesson). Treat `docs/pseudo-streaming/design.md` as historical;
> implement from THIS doc.

---

## TL;DR

The premise of the request — "macOS has EOU, we need to remove it and add batch
streaming" — is **half right and the surprising half matters**:

- **EOU already exists on macOS and ships as the default.** `TranscriberHolder.swift:56`
  defaults fresh installs to `.tdt_0_6b_v3_eou_streaming` — a Parakeet v3 batch
  final transcript **plus** a separate FluidAudio `StreamingEouAsrManager` (Parakeet
  EOU 120M) driving the pill's live preview (`StreamingTranscriber.swift:6,39,93`).
- **A live-text preview surface already exists and ships.** The recording pill renders
  live partials inline (`PillView.swift:227-290`) and in a tap-to-expand scrollable
  transcript (`PillView.swift:297-376`), fed by `StreamingPartialStore`
  (`Sources/Overlay/StreamingPartialStore.swift:31,39,46`).
- So this is **a removal-and-replacement task, not a greenfield add.** "Remove EOU"
  is real work (the EOU engine is wired end-to-end). "Add batch pseudo-streaming" means
  **replacing the engine that drives the existing preview surface**, not building a new
  surface.

What this doc proposes: add a `PreviewScheduler` actor (ported from jot-mobile) that
maintains a trailing audio window, detects pauses by RMS energy, and re-runs the
**existing batch `Transcriber`** over the window on a cadence to produce volatile/committed
preview text. Route the v2/v3 preview through it instead of `StreamingTranscriber` (EOU),
publish into the **unchanged** `StreamingPartialStore`, and delete the EOU path. The
**final pasted transcript stays byte-for-byte unchanged** (still `stopAndTranscribe` →
batch `Transcriber.transcribe`).

This is chosen over FluidAudio's built-in `SlidingWindowAsrManager` (the superseded sibling
doc) on hard evidence: the SDK manager **carries decoder state across windows**
(`SlidingWindowAsrManager.swift:410-425`) — the exact algorithm jot-mobile measured at
**10.9%–50% divergence-from-final and rejected**, which would reintroduce the "transcript
flips at stop" pathology that killing EOU is meant to remove. The `PreviewScheduler` uses a
**fresh per-call `TdtDecoderState`** (1.3% divergence). See §8.

---

## 1. Current macOS state (the surface we are changing)

Every claim here is from a direct read of the cited file. Confidence: **Confirmed**
unless noted.

### 1.1 EOU and live preview already ship on macOS

- **Default model is the EOU pairing.** `Sources/Transcription/TranscriberHolder.swift:56`
  resolves the default to `.tdt_0_6b_v3_eou_streaming` when no stored choice exists.
- **`ParakeetModelID` enumerates three streaming variants** (`Sources/Transcription/ParakeetModelID.swift:26,34,42`):
  `tdt_0_6b_v2_en_streaming`, `tdt_0_6b_v3_nemotron_streaming`, `tdt_0_6b_v3_eou_streaming`,
  plus the batch-only `tdt_0_6b_v3` (`:21`), `tdt_0_6b_v3_int4` (`:22`), `tdt_0_6b_ja`
  (`:23`), and `nemotron_en` (`:45`).
- **The EOU engine is a real, wired FluidAudio wrapper.** `Sources/Transcription/StreamingTranscriber.swift`
  is an `actor` wrapping `StreamingEouAsrManager` (`:6,39,93`); partials arrive via
  `mgr.setPartialCallback` (`:155-157`); **its `finish()` text is discarded — batch is
  authoritative** (`StreamingTranscriber.swift:223`).
- **A second streaming engine exists** (Nemotron): `Sources/Transcription/NemotronStreamingTranscriber.swift:11`
  wraps `StreamingNemotronAsrManager`.
- **There is no Jot-owned VAD / silence-detection / endpointing.** The only end-of-utterance
  logic lives *inside* FluidAudio's `StreamingEouAsrManager` — Jot does not auto-stop on
  silence; recording stops only on hotkey / mic-disconnect / cancel. (Grep for
  `VAD`/`endpoint`/`silence`/`endOfUtterance` across `Sources/` returns only LLM/donation
  endpoint URLs and one unrelated comment in `RewriteController.swift:284`.)

### 1.2 The composite seam (`DualPipelineTranscriber`)

`Sources/Transcription/DualPipelineTranscriber.swift` is the class the pipeline actually
holds. It routes a **final** engine and a **streaming** engine independently:

- `enum FinalEngine { case batch(Transcriber); case nemotron(NemotronStreamingTranscriber) }` (`:12-14`)
- `enum StreamingEngine { case eou(StreamingTranscriber); case nemotron(NemotronStreamingTranscriber) }` (`:17-19`)
- Streaming seam methods: `startStreaming(generation:onPartial:)` (`:123`),
  `enqueueStreaming(samples:)` (`:136`), `finishStreaming()` (`:145`),
  `cancelStreaming()` (`:169`).
- Final seam: `transcribe(_:)` (`:77`), `transcribeFile(_:)` (`:99`), `ensureLoaded` (`:113`).

**This is the cleanest insertion point.** Adding batch pseudo-streaming means adding a
`StreamingEngine` case (or replacing `.eou`) that, instead of feeding a streaming ASR
model, runs a `PreviewScheduler` over the same chunks.

### 1.3 The batch `Transcriber` (the model we will re-run for preview)

`Sources/Transcription/Transcriber.swift` is an `actor` (`:19`) wrapping FluidAudio's
batch `AsrManager`:

- `func transcribe(_ samples: [Float]) async throws -> TranscriptionResult` (`:112`).
- **Single-in-flight busy guard:** `guard !isTranscribing else { throw TranscriberError.busy }`
  (`:113`), set/cleared via `isTranscribing = true` + `defer { isTranscribing = false }`
  (`:118-119`); `var busy: Bool { isTranscribing }` (`:271`).
- **Minimum-length guard:** rejects `< 1 s` of audio with `.audioTooShort` (`:114-115`).
- **Post-processing** (`transcribeWithAsrManager`, `:137-243`): vocab rescore via
  `VocabularyRescorerHolder.shared.rescore` using token timings (`:192`); the
  `ParagraphSegmenter → FillerWordCleaner → NumberNormalizer` chain is **gated to v2 only**
  (`:205-231`), because v3 / JA / Nemotron heads emit well-cased filler-trimmed text natively.

This maps onto jot-mobile's split exactly: jot-mobile has a full `transcribe()` and a lean
`previewTranscribe()` that skips the busy-throw, provenance/diagnostics, and **vocab rescore**
(jot-mobile `TranscriptionService.swift:660-710`). macOS has no lean variant yet — we add one.

### 1.4 The audio tap and buffering

- **CoreAudio AUHAL, not `AVAudioEngine`.** `Sources/Recording/AudioCapture.swift` is an
  `actor` (`:66`) driving a `kAudioUnitSubType_HALOutput` unit; the render callback is the C
  trampoline `audioCaptureAUHALInputCallback` (`:1274`). (CLAUDE.md says `AVAudioEngine`;
  the live path is AUHAL. Conversion still uses `AVAudioConverter`.)
- **Target format is 16 kHz mono Float32** — confirmed by the streaming buffer builder
  `standardFormatWithSampleRate: 16_000, channels: 1` (`StreamingTranscriber.swift:198-216`)
  and the `AudioFormat.target` conversion in `convertAndWrite` (`AudioCapture.swift:1374-1445`).
- **There is a per-chunk fan-out sink:** `nonisolated(unsafe) public var streamingSink:
  (@Sendable ([Float]) -> Void)?` (`AudioCapture.swift:138`), invoked per converted chunk
  inside `convertAndWrite` (`:1435-1438`). This is exactly what `PreviewScheduler.ingest()`
  needs as its feed.
- **CRITICAL GAP — no rolling/ring buffer of recent audio.** Audio is accumulated two ways
  only: (1) one growing in-memory `[Float]` (`QueueState.samples`, appended at `:1428`,
  snapshotted whole on `stop()`), and (2) the on-disk file via `AVAudioFile.write` (`:1441`).
  The streaming sink fans out a *copy* of each chunk to a consumer that drops it. **Batch
  pseudo-streaming needs a bounded trailing window** — this is the one genuinely new piece of
  audio plumbing (jot-mobile's `StreamingBufferQueue` / ring; see §3). The growing
  `QueueState.samples` array could in principle be re-sliced, but it lives in the
  `AudioCapture` actor and is not exposed for windowed reads — the ring belongs in the
  scheduler.

### 1.5 The preview UI surface (already exists — do not rebuild)

- **`StreamingPartialStore`** (`Sources/Overlay/StreamingPartialStore.swift:31`) is an
  `ObservableObject` with `@Published private(set) var partial: String?` (`:39`) and
  `isActive: Bool` (`:46`), session-bracketed by a generation token.
- **`PillViewModel`** subscribes to `$partial` and rebuilds the recording state
  (`PillViewModel.swift:206-235`).
- **`PillView`** renders the partial inline (compact, `:227-290`) and in the tap-to-expand
  scrollable transcript (`:297-376`). The pill widens to `streamingPillWidth` (480) when a
  partial is present (`OverlayWindowController.pillWidth :277-286`).

> **Answer to the parent question "what is the macOS preview surface, and is preview even
> wanted in a paste-at-cursor flow?":** the surface already exists, ships, and is the current
> UX — the pill *already* shows live text during dictation. The product decision "is live
> preview valuable in a speak→paste flow?" was made when EOU shipped; this doc does not
> reopen it. Our job is to keep that surface and swap the engine behind it. See §7 Open Qs
> for whether to keep the *expanded* transcript view (it may matter more now that preview
> quality equals final quality).

### 1.6 State machine (exhaustive-switch surface)

- **`RecorderController.State`** (`Sources/Recording/RecorderController.swift:24-30`):
  `.idle`, `.recording(startedAt: Date)`, `.transcribing`, `.transforming`, `.error(String)`.
  **No `.preview` case — streaming partials ride inside `.recording`** via the separate
  `StreamingPartialStore`. `RecorderController` is `@MainActor` (`:22`).
- **`PillViewModel.PillState`** (`Sources/Overlay/PillViewModel.swift:14-49`):
  `.hidden`, `.recording(elapsed:streamingPartial:)`, `.transcribing`, `.condensing`,
  `.rewriting`, `.transforming`, `.success(preview:)`, `.notice(message:)`,
  `.savedToRecents(preview:)`, `.error(message:)`, `.holdProgress(progress:)`. The live
  preview is the `streamingPartial: String?` associated value on `.recording`.
- **Switch sites** (per CLAUDE.md's "compiler is the checklist" rule):
  `RecorderController.State` is switched in `RecorderController.swift:103,158,119`,
  `PillViewModel.swift:294-322`, `JotMenuBarController.swift:455-523`,
  `SoundTriggers.swift:24,67`, `HotkeyRouter.swift:550`,
  `WizardShortcutChip.swift:125-156`, `HelpVisuals.swift:66-138`, `AskJotView.swift:475`.
  `PillState` is switched in `PillView.swift:71-134` (the render body),
  `PillViewModel.swift:251-258,301-334,380-401`, and `OverlayWindowController.swift:252-326`.

> **Good news for scope:** because the preview rides *inside* `.recording(streamingPartial:)`,
> **batch pseudo-streaming adds no new `RecorderController.State` or `PillState` case** in
> the happy path. We are changing what *fills* `streamingPartial`, not the state shape. See
> §7 for the one possible exception (a distinct "preview is mid-refresh" affordance — likely
> unnecessary).

### 1.7 Delivery is decoupled from preview (the safety invariant)

- Final transcript is produced by `pipeline.stopAndTranscribe(token)` → batch
  `Transcriber.transcribe` (`RecorderController.runFlow()` builds `TranscriptionResult` from
  `stopResult.text`, `RecorderController.swift:258-290`).
- Delivery is the clipboard sandwich: `DeliveryService.performSandwich` (`Sources/Delivery/DeliveryService.swift:148-185`)
  — snapshot → write → synthetic ⌘V → optional auto-Enter → restore.
- **`StreamingPartialStore.partial` is read only by the pill.** Nothing in the delivery path
  reads it. **Therefore any preview-engine change is UX-only and structurally cannot regress
  the pasted/saved text**, as long as `stopAndTranscribe → batch` stays authoritative.

### 1.8 Threading model (existing)

- `RecorderController` `@MainActor` (`:22`); `VoiceInputPipeline` `@MainActor`
  (`Sources/Recording/VoiceInputPipeline.swift:4`).
- Heavy batch inference runs off-MainActor inside the `Transcriber` actor (`:19`).
- Streaming engines are `actor`s draining via `Task.detached`
  (`StreamingTranscriber.swift:134`); the sync `enqueue` is `nonisolated` (`:190`).
- `StreamingPartialStore` is `@MainActor` (`:30`); partials reach it via a single
  `Task { @MainActor in … }` hop from the engine's `onPartial` (`VoiceInputPipeline.swift:333-337`).

This mirrors jot-mobile's intended model: **scheduler off-MainActor, presenter on MainActor.**

---

## 2. What jot-mobile actually does (authoritative, current values)

Source: jot-mobile design doc `/Users/vsriram/code/jot-mobile/docs/plans/batch-only-streaming.md`
and the implementation in the worktree
`/Users/vsriram/code/jot-mobile/.claude/worktrees/batch-only-streaming/`
(branch `worktree-batch-only-streaming` — **not yet merged to jot-mobile `main`**; verify
before treating as shipped).

### 2.1 Pipeline

`audio tap → StreamingBufferQueue (ring) → PreviewScheduler (actor, off-MainActor) →
StreamingPartial (@MainActor presenter) → UI`. One scheduler per recording slice.

### 2.2 Exact tunables (jot-mobile `PreviewScheduler.swift`, `sampleRate = 16_000`)

| Tunable | Value in code | Samples @16 kHz | Seconds |
|---|---|---|---|
| `pauseSilenceSamples` | `Int(0.7 * 16000)` (`:52`) | 11,200 | **0.7 s** |
| `timerSamples` | `Int(5.0 * 16000)` (`:54`) | 80,000 | **5.0 s** |
| `capSamples` | `Int(15.0 * 16000)` (`:57`) | 240,000 | **15.0 s** |
| `silenceRMS` | `Float = 0.005` (`:63`) | — | RMS threshold (lowered from 0.008) |
| `minTickSpacingSamples` | `Int(2.0 * 16000)` (`:70`) | 32,000 | **2.0 s** |
| `minWindowSamples` | `Int(1.0 * 16000)` (`:73`) | 16,000 | **1.0 s** |
| `firstTickSamples` | `Int(2.0 * 16000)` (`:80`) | 32,000 | **2.0 s** (first-tick-fast) |
| `ringCapacity` | `capSamples + Int(5.0*16000)` (`:82`) | 320,000 | **20.0 s** (15 s + 5 s margin) |

### 2.3 Algorithm (trigger priority + two universal gates)

`PreviewScheduler.ingest()` (`:190-266`). Per incoming chunk: compute RMS
(`:199-209`), update `silenceRun` vs `silenceRMS`; if `rms >= silenceRMS` reset
`silenceRun`, clear `pauseFiredThisRun`, set `lastSpeechTotal = totalSamples`.

**Two universal gates (every trigger must pass both):**
1. **Speech-in-window** (`:242`): `guard speechInWindow` where `speechInWindow =
   lastSpeechTotal > windowStartTotal` (`:213`) — an *index* comparison, not a boolean,
   so speech landing mid-tick isn't wiped. (A pure-silence window must never run inference.)
2. **Min-tick-spacing** (`:246`): `guard totalSamples - lastTickTotal >= minTickSpacingSamples`
   — the structural inference duty-cycle bound (≤ 1 tick / 2 s).

**Trigger priority (pause > cap > first-tick > timer), `:247-265`:**
- **pause** (`silenceRun >= pauseSilenceSamples`, `!pauseFiredThisRun`, `windowLen >= minWindowSamples`)
  → `.commit` (one fire per silence run).
- **cap** (`windowLen >= capSamples`) → `.commit` (runaway guard).
- **first-tick-fast** (no committed/volatile text yet, `windowLen >= firstTickSamples`)
  → `.volatileRefresh` (kills the dead initial 5 s wait).
- **timer** (`totalSamples - lastTickTotal >= timerSamples`, `windowLen >= minWindowSamples`)
  → `.volatileRefresh`.

`.commit` finalizes the window `[lastCommit … now]` into a committed prefix and advances
`windowStartTotal`; `.volatileRefresh` re-derives the not-yet-committed tail.

### 2.4 Overlap window beat the alternatives

Measured divergence vs the final full-file pass (jot-mobile doc `:36-43`, class comment
`:15-19`): isolated-utterance freeze (segment-and-concat) **4.5%** (≈8% multi-utterance);
**carried `TdtDecoderState` 10.9%** (up to 50% — rejected); **re-transcribed trailing
overlap window 1.3%** (winner). A prior naive sliding-window TDT spike measured 15.6%.

### 2.5 Fresh decoder state per call — no carry

Both the batch and preview paths build a **fresh** `TdtDecoderState.make(...)` per call and
never thread it across windows (jot-mobile `TranscriptionService.swift:570-573` and
`:692-695`). Carrying state was the 10.9% loser.

> **macOS note:** Jot's batch `Transcriber.transcribe` already does a fresh decode per call
> (it's a one-shot batch API); there is no decoder-state plumbing to expose or avoid. This
> is automatically satisfied by reusing `Transcriber`.

### 2.6 Lean `previewTranscribe()`

jot-mobile `TranscriptionService.swift:660-710`: no `isTranscribing` busy gate (ticks
coalesce latest-wins in the scheduler), no `CorrectionProvenance` / `DiagnosticsLog` side
effects, **no vocabulary rescore** (vocab corrects only on stop), guards `>= 1 s` returning
`nil` (never throws). Runs paragraphs + filler-clean + number-normalize.

### 2.7 `quiesce()` fence on stop

jot-mobile `PreviewScheduler.quiesce()` (`:177-180`): sets `stopped`, awaits the in-flight
tick. Teardown MUST call it before reading assembled text, else actor reentrancy drops the
last window's words. Called from `RecordingService.tearDownStreamingSession()` (`:543`)
before `assembledText()`.

### 2.8 Dropped-words fix: retry-not-discard

jot-mobile `PreviewScheduler.runTick()` commit branch (`:326-348`): on an **empty** commit,
**never advance `windowStartTotal` past speech** — keep the window and retry with more audio
("the model wants more context, not less"). A give-up valve advances only after
`emptyRetries >= 3` AND the window has reached cap length. SchedulerSim corpus: counting
deletions 3/40 → 0/40 with this fix; a competing "trim window to speech−0.5 s" fix was a
14/40 regression (Parakeet decodes sub-2 s clips badly).

### 2.9 Device hard-wall

jot-mobile `DeviceCapability.swift:23-24`: `is600MCapable = physicalMemory >= 4_600_000_000`.
Single boolean; the doc's historical 4-tier resolver was superseded.

### 2.10 `previewSource` flag

jot-mobile App Group key `jot.preview.source` → `"eou"` | `"batch"`, **defaulting to
`"batch"`** in the worktree (`AppGroup.swift:149,354-363`); consumed at session start in
`kickOffStreamingSession()` (`:379`); never flips mid-session.

---

## 3. iOS-only machinery — EXCLUDED from the macOS plan

This is why macOS gets *simpler*. Each item below exists in jot-mobile solely because of the
keyboard-extension architecture; **none ports.**

| jot-mobile mechanism | Why it exists on iOS | macOS analogue |
|---|---|---|
| **Keyboard extension / appex** (`Jot/Keyboard/JotKeyboardViewController.swift`, `StreamingStrip.swift`) | A separate process that can't run inference; remote-controls the main app | **None.** macOS Jot is one process; the pill is in-process. Drop entirely. |
| **App Group mirroring of the partial string** (`StreamingPartial.publishProjection()` jot-mobile `:230-248`, Darwin `CrossProcessNotification`) | Cross-process IPC to get partials into the keyboard | **None.** macOS presenter (`StreamingPartialStore`) and view (`PillView`) are in-process. No App Group, no Darwin notification, no 5 Hz throttle. |
| **~60 MB appex memory ceiling** (8 KB partial cap, "keyboard must not run inference") | iOS keyboard-extension limit | **None.** macOS app has the full process memory budget. Drop the 8 KB cap and the inference-bounce. |
| **Owned-input "Ask" / voice-prompt-rewrite-as-input-field** (`ownsActiveRecording`, `AskView.swift`, `RewritePickerSheet.swift`) | iOS surfaces that use the live preview *as a text field* | **Partial analogue.** macOS has Ask Jot voice input and Rewrite-with-Voice, which already use `VoiceInputPipeline` + `StreamingPartialStore`. They get the new preview *for free* once the engine is swapped — but the iOS `ownsActiveRecording` gating (faster cadence, exempt-from-RAM-gate) is **not implemented even on iOS** (jot-mobile `RecordingService.swift:377` "follow-up"), so it is out of scope here too. |
| **`previewSource` as an App Group key** | Shared across appex + main app | **Keep the flag, change the storage.** macOS uses `@AppStorage`/`UserDefaults` directly (no App Group). See §6. |
| **`DeviceCapability` 4.6 GB RAM wall** | iPhone SKUs vary widely; ≤4 GB devices exist | **Defer to the hardware-capability-matrix plan** (§5). Macs are uniformly higher-spec; the wall is likely a no-op but the *gating mechanism* (auto/on/off + a capability boolean) is reused. |

---

## 4. Proposed macOS architecture

### 4.1 Component port map

| jot-mobile component | macOS disposition | Target |
|---|---|---|
| `PreviewScheduler` (actor) | **Port directly** (the core IP) | `Sources/Transcription/PreviewScheduler.swift` (new) |
| RMS pause gate (inline in `ingest`) | **Port directly** | inside `PreviewScheduler` |
| `StreamingBufferQueue` / ring buffer | **Port as a small ring** (no macOS equivalent exists — see §1.4) | inside `PreviewScheduler` (private `[Float]` ring of `ringCapacity`) |
| `previewTranscribe()` lean path | **Add as a method on `Transcriber`** | `Sources/Transcription/Transcriber.swift` (new `previewTranscribe`) |
| `StreamingPartial` (@MainActor presenter) | **Already exists** as `StreamingPartialStore` | `Sources/Overlay/StreamingPartialStore.swift` (unchanged shape; new feeder) |
| `quiesce()` fence | **Port directly** | `PreviewScheduler.quiesce()` |
| retry-not-discard empty-commit fix | **Port directly** | `PreviewScheduler.runTick()` |
| Engine routing | **New `StreamingEngine` case** | `Sources/Transcription/DualPipelineTranscriber.swift` |
| Keyboard appex / App Group / Darwin / 8 KB cap | **DROP** (iOS-only) | — |
| `DeviceCapability` RAM wall | **Defer to sibling plan** | (see §5) |
| `previewSource` flag (App Group) | **Port as `@AppStorage`** | `Sources/Settings/…` |
| SchedulerSim offline validator | **Recommend a macOS equivalent** | `tools/` (see §9) |

### 4.2 Where the scheduler plugs in

The cleanest seam is `DualPipelineTranscriber`'s existing `StreamingEngine` enum
(`:17-19`). Add a case:

```swift
private enum StreamingEngine: Sendable {
    case eou(StreamingTranscriber)          // delete in Phase 4
    case nemotron(NemotronStreamingTranscriber)
    case batchPreview(PreviewScheduler)     // NEW
}
```

Then extend the four streaming seam methods (`startStreaming :123`, `enqueueStreaming :136`,
`finishStreaming :145`, `cancelStreaming :169`) with a `.batchPreview` branch:

- `startStreaming(generation:onPartial:)` → `scheduler.begin(onPartial:)` (stores the
  MainActor publish callback; starts the drain/tick task).
- `enqueueStreaming(samples:)` → `scheduler.ingest(samples)` (nonisolated forwarding into
  the ring; identical contract to the EOU enqueue).
- `finishStreaming()` → `await scheduler.quiesce()` then return `nil` (batch is authoritative;
  the assembled preview text is **not** used as the final — same as EOU today).
- `cancelStreaming()` → `await scheduler.cancel()` (drop ring, stop ticks, no final publish).

The `PreviewScheduler` calls back into the **existing** `Transcriber.previewTranscribe(...)`
to produce text and into the `onPartial` closure to publish — exactly the closure
`VoiceInputPipeline.beginStreamingSession` already wires into `StreamingPartialStore`
(`VoiceInputPipeline.swift:327-353`). **No pipeline rewiring needed.**

### 4.3 The lean preview path on macOS `Transcriber`

Add to `Sources/Transcription/Transcriber.swift`:

```swift
/// Lean preview decode. NO busy-throw (caller coalesces ticks), NO vocab rescore,
/// NO provenance/diagnostics side effects. Returns nil for <1s or on any error.
/// Mirrors jot-mobile TranscriptionService.previewTranscribe (:660-710).
func previewTranscribe(_ samples: [Float]) async -> String? { … }
```

It must:
- **Bypass the `isTranscribing` guard** (`:113`) — but only because §4.3.1 guarantees, at the
  scheduler level, that a preview tick and the final pass are never in flight at the same time.
  The `isTranscribing` flag is still honored by the *final* `transcribe` path; the lean path
  simply does not set/check it (it relies on the stronger scheduler ordering below).
- **Skip vocab rescore** (the `:192` rescore call) and any provenance writes.
- **Run the v2-gated post-processing chain only when the active model is v2** (matching the
  final path `:205-231`), so preview and final use the same normalization. (v2 is English-default
  and first-class; v3 is multilingual — both are maintained preview paths.)
- **Use the ACTIVE model's TDT decoder config** — v2 uses blankId 1024, v3 uses 8192 — so the
  scheduler decodes against whichever model is loaded for the session. This is just correctly
  reusing the batch model's existing decoder config (the same one the final pass uses); it is a
  per-call fresh decode, **no carried state**, fully consistent with the fresh-`TdtDecoderState`
  design (§2.5).
- Return `nil` (never throw) below 1 s.

### 4.3.1 Concurrency: preview ticks MUST NOT overlap the final pass (safe-by-construction)

This is a hard ordering requirement, not an open question. Verified facts:

- FluidAudio's `AsrManager` is an `actor` (`AsrManager.swift:6`), so individual calls
  serialize. **But actor isolation alone is insufficient here:** a batch decode
  `await`-suspends at each inference step, which lets a queued preview tick interleave between
  suspensions; worse, both the final pass and preview ticks contend for the **module-global**
  `let sharedMLArrayCache = MLArrayCache()` (`MLArrayCache.swift:78`), used at
  `AsrManager.swift:149` (`getArray`) and cleared at `:185`/`:194` (and in the pipeline at
  `AsrManager+Pipeline.swift:81`). A preview tick clearing/repopulating that global cache
  mid-final-decode is a real corruption/perf hazard, *not* a theoretical one.

**Required ordering (enforced at the `PreviewScheduler` + `DualPipelineTranscriber` seam):**

1. **Single-flight preview ticks** inside the scheduler (`inFlight` + `pendingTrigger`,
   latest-wins) — already part of the port. At most one preview decode runs at a time.
2. **`quiesce()` fence on stop, before the final pass.** `DualPipelineTranscriber.finishStreaming()`
   must `await scheduler.quiesce()` (which sets `stopped` and awaits the in-flight tick) **and
   only then** allow the final `transcribe` to begin. This mirrors *both* jot-mobile's
   `quiesce()` fence (`PreviewScheduler.swift:177-180`, called before `assembledText()` at
   `RecordingService.swift:543`) *and* the sibling doc's own enforcement
   (`docs/pseudo-streaming/design.md:429` — await `finish()`/drain before the final transcribe).
3. **No new preview tick may start once `stopped` is set.** `quiesce()` sets `stopped`; the
   scheduler's tick-scheduling guard checks it, so no tick races the final pass after the fence.

Concretely, the stop sequence is strictly: `quiesce()` (drain + block further ticks) →
`Transcriber.transcribe(fullSamples)` (final, authoritative) → publish/deliver. The preview
decode and the final decode therefore never touch `sharedMLArrayCache` concurrently. **This
must be verified at runtime** (per project memory on audio/inference changes): observe that
no preview tick logs after the stop fence and that the final transcript is byte-identical to
the pre-change batch output (see §9 verification gate).

### 4.4 Threading model (macOS)

- **`PreviewScheduler`** = `actor`, off-MainActor (mirrors jot-mobile `:41`). Owns the ring,
  the RMS state, the tick coalescing (`inFlight` + `pendingTrigger`, latest-wins). Its tick
  calls `await Transcriber.previewTranscribe(...)` (off-MainActor) and hops to MainActor only
  to publish via the `onPartial` closure.
- **Feed:** `AudioCapture.streamingSink` (`:138`) → `DualPipelineTranscriber.enqueueStreaming`
  → `scheduler.ingest`. `ingest` should be `nonisolated` forwarding into a lock-protected
  ring (mirror jot-mobile's `nonisolated enqueue`, `StreamingTranscriber.swift:190` pattern),
  so the writer queue never blocks on actor hops.
- **Presenter:** `StreamingPartialStore` stays `@MainActor` (`:30`); the single MainActor hop
  is the existing `Task { @MainActor in … }` in `VoiceInputPipeline.swift:333-337`.

No new global concurrency surface; the model is identical to today's EOU path with the
scheduler substituted for the streaming ASR actor — **plus** the explicit stop-fence ordering
in §4.3.1 (which the EOU path also relies on, since EOU's `finish()` is likewise awaited
before the final pass).

### 4.5 EOU-removal surface map (folded in from the superseded sibling doc)

This is the end-to-end inventory of every EOU touchpoint, credited to the surface analysis in
`docs/pseudo-streaming/design.md:97-104,339-366` (verified against the live tree). The
disposition column reflects that the preview engine is the **`PreviewScheduler`** (not a
`SlidingWindowTranscriber`), but the *deletion* surface is identical either way.

| Touchpoint | File:line | Action |
|---|---|---|
| EOU wrapper | `Sources/Transcription/StreamingTranscriber.swift` | **Delete the file** (actor wrapping `StreamingEouAsrManager`, 160 ms chunks, `setPartialCallback`). |
| Composite enum | `Sources/Transcription/DualPipelineTranscriber.swift:18,63-65,129-131,148-150,172-174` | Replace `case eou(StreamingTranscriber)` with `case batchPreview(PreviewScheduler)`; rewrite the four seam-method `.eou` branches (§4.2). |
| Factory | `Sources/App/JotComposition.swift:~298-333` | The `case .tdt_0_6b_v2_en_streaming, .tdt_0_6b_v3_eou_streaming:` arm builds `DualPipelineTranscriber(batch:streaming:)` — repoint `streaming:` to a `PreviewScheduler` constructed over the **same `AsrModels`/`Transcriber`** as the batch final (no second model load). |
| Download | `Sources/Transcription/ModelDownloader.swift:~254-303` | Delete `downloadEouStreamingSide`; drop the EOU branch from `downloadStreamingSide` dispatch and the `batchProgressShare` EOU split (`:222,259,305`). Preview now needs only the batch bundle. |
| Cache | `Sources/Transcription/ModelCache.swift:~59-151` (and `:43,61,82,123,141,211`) | `streamingPartialCacheURL` returns `nil` for v2/v3 streaming (EOU dir `parakeet-eou-streaming/160ms` gone); `isCached` for v2/v3 streaming = **batch bundle only**; `streamingBundleExists` drops the EOU required-files branch. **Scope: v2/v3 streaming cases ONLY** — Nemotron's cache logic is untouched. |
| Migration | `Sources/Transcription/ModelChoiceMigration.swift` (`:82` + `runV12EouRenameIfNeeded`/`eouRenameMigratedKey`) | See the raw-value insight below — **no new `jot.defaultModelID` migration is needed**. Keep the existing v1.2 rename migration as-is (historical). |
| Settings | `Sources/Settings/TranscriptionPane.swift:~327-432` | Drop `sharedStreamingBundleProtection` (the EOU shared-bundle delete-guard) and the EOU per-model cache-deletion path. |
| Orphaned bundle | on-disk `parakeet-eou-streaming/` | One-shot cleanup of the now-unused EOU cache dir (gated, `try?`, only the literal dir, after confirming no model references it). |
| `ParakeetModelID` switches | `ModelCache.swift:43,61,82,123,141,211`, `ModelDownloader.swift:222,259`, `PostProcessing.swift:25`, `ModelChoiceMigration.swift:82`, `ParakeetModelID.swift:56-87` | The compiler enumerates these; the cases **stay** (raw values preserved — see below), so these are behavior edits, not case removals. |

**Both v2 (English) and v3 (multilingual) are first-class, maintained PreviewScheduler-driven
preview paths — neither is deprecated or secondary.** English **defaults to**
`tdt_0_6b_v2_en_streaming` (v2 has the better English accuracy); multilingual uses
`tdt_0_6b_v3_eou_streaming`. The EOU-removal / engine-swap applies **equally to both** — each
case loses its EOU side and gains the `PreviewScheduler` running over its own batch weights.

**Preserved-enum-raw-value migration insight (credited to sibling `:129,366,474-475`):**
**Do NOT delete the `tdt_0_6b_v2_en_streaming` / `tdt_0_6b_v3_eou_streaming` enum cases.** They
are persisted by raw value in the `jot.defaultModelID` `@AppStorage` key
(`TranscriberHolder.swift:42,56`). Keep the cases and **redefine their meaning**:
`tdt_0_6b_v2_en_streaming` becomes "Parakeet v2 (English) batch final + batch-pseudo-streaming
preview" and `tdt_0_6b_v3_eou_streaming` becomes "Parakeet v3 (multilingual) batch final +
batch-pseudo-streaming preview" — both first-class. Because the stored raw value is unchanged,
**existing users' selection survives with zero defaults migration** — their preview engine
silently upgrades from EOU to the scheduler on next launch. This is strictly safer than my
earlier "repoint the default / migrate stored users" framing, and it is now the chosen
approach. (Cosmetic: update the display name / description in `ParakeetModelID.swift:56-87`
since "EOU" is no longer accurate.)

**Phase exit criterion — CLEAN COMPILE, not the paper switch-site list.** The switch-site
inventory above is a *map*, not a guarantee. EOU deletion is **done** only when the project
compiles with zero errors after `StreamingTranscriber.swift` is removed and the `.eou` case is
gone — the Swift compiler's exhaustiveness checking is the real checklist (CLAUDE.md: "the
compiler is the checklist"). Do not mark Phase 4/6 complete on the basis of having visited
every line listed here; mark it complete on a clean `xcodebuild` (isolated `-derivedDataPath`
per project memory on the concurrent-build DB lock).

> **Scope decision (mirror the sibling doc's D1):** **remove EOU only; keep Nemotron** as a
> separate user-selectable option for now. Removing both at once compounds migration risk.
> The `streamingPartialCacheURL`→`nil` / `isCached`→batch-only changes apply to the **v2/v3
> streaming cases only**; Nemotron's bundle/cache logic is left alone.

---

## 5. Dependency: hardware-capability-matrix (sibling plan — INPUT)

This plan **consumes** `docs/hardware-capability-matrix/design.md` to decide *which Macs get
live preview at all*. **That doc does not exist yet** (verified — `docs/` has no
`hardware-capability-matrix/`). Assumptions made here, to be validated against it when it
lands:

1. **There is a capability signal** analogous to jot-mobile's `is600MCapable` — for macOS
   likely "is this Mac fast enough to run a batch decode inside the 2 s tick budget without
   audible UI jank?" rather than a RAM wall (all supported Macs have ≥8 GB).
2. **The gate is tri-state** (`auto` / `on` / `off`), with `auto` resolving from the
   capability signal — reuse jot-mobile's `liveTextEnabled` shape (`DeviceCapability.swift:34-40`).
3. **Below the gate, dictation still works** — preview is simply suppressed (pill shows the
   recording dot + timer, no live text); the final batch transcript path is untouched.
4. **No hard wall on macOS** (unlike iOS's ≤4 GB devices). If the matrix introduces one,
   wire it into the same `auto` resolution, not a separate code path.

If the matrix plan ships a concrete API (e.g. `MacCapability.livePreviewEnabled`),
`PreviewScheduler` consults it once at session start (never mid-session, mirroring
jot-mobile's resolve-at-start rule).

---

## 6. Concrete tunables to start with (macOS)

Start with jot-mobile's exact values (§2.2) — they were tuned against a SchedulerSim corpus
and are the best available prior. macOS-specific reasoning:

| Tunable | Start value | Macs-specific justification |
|---|---|---|
| `pauseSilenceSamples` | 0.7 s | Pause-as-commit; human-perceptible pause, model-validated. Keep. |
| `timerSamples` | 5.0 s | Volatile refresh for no-pause talkers. Keep. |
| `capSamples` | 15.0 s | Runaway guard. Macs decode faster than iPhones, but the cap is about *text-assembly* boundaries, not perf — keep. |
| `silenceRMS` | 0.005 (interim) | iPhone-tuned and **unvalidated on Mac mics** — see the gated commitment below. |
| `minTickSpacingSamples` | 2.0 s | Duty-cycle bound. On a fast M-series this could go *lower* (faster preview) since batch RTFx is ~47–155×; **but** keep 2 s initially to bound thermals/battery on laptops. Re-tune per capability tier. |
| `minWindowSamples` | 1.0 s | Matches `Transcriber.audioTooShort` (`:114`). Keep — must be ≥ the batch min-length guard. |
| `firstTickSamples` | 2.0 s | First-tick-fast. Keep. **Do not raise it** — see the first-preview-latency lesson below. |
| `ringCapacity` | 20.0 s (cap + 5 s) | Trivial RAM on a Mac (~1.3 MB Float32). Keep. |

**`silenceRMS` — concrete validation gate, not hand-waving.** `silenceRMS = 0.005` was tuned
against jot-mobile's iPhone-mic SchedulerSim corpus; Mac input devices (built-in vs USB vs
Bluetooth, with desk fans / mechanical keyboards) have a different noise floor and the
threshold may mis-tag quiet speech as silence (a wrong pause-commit) or noise as speech (a
missed commit). **Phase 3 gate (§9):** record a named macOS corpus
`tools/scheduler-sim/corpus/mac-mics/` (≥ 40 clips spanning built-in/USB/BT mics, quiet and
noisy rooms, including the slow-counting case that exposed the iOS drop bug) and run the
macOS SchedulerSim. **Committed acceptance threshold:** ≤ 1 word-level deletion per clip on
the counting/control set (matching iOS's 0/40 target with a 1-clip slack) AND mean
divergence-vs-final ≤ 2% (iOS hit 1.3%; 2% is the macOS pass bar). **Interim default until
the corpus exists:** keep `0.005`, but treat any field report of "preview commits mid-word /
preview never appears in a quiet room" as a `silenceRMS` regression and the trigger to build
the corpus. This is a named, owned risk (R-RMS in §7), not a deferral to nowhere.

**First-preview-latency lesson (credited to sibling `docs/pseudo-streaming/design.md`).** A
naive long-window / long-chunk configuration produces **no preview at all for short
dictations** — if the first decode only fires after a 5 s timer (or after a large fixed chunk
fills), a 3-second dictation shows a blank pill the entire time and the user thinks it's
broken. The `firstTickSamples = 2.0 s` first-tick-fast path is exactly the fix: it forces the
*first* volatile refresh at ~2 s regardless of the 5 s timer, so preview text appears early
even for short utterances. **Keep `firstTickSamples` small and never gate the first tick
behind the full `timerSamples`.**

**One macOS divergence worth considering:** because Mac batch RTFx is high, the
`minTickSpacingSamples` duty-cycle could be tightened on desktop Macs (plugged in) for a
snappier preview. Treat as a capability-tier knob, default 2 s. (Open Q §7.)

---

## 7. Risks, open questions, out-of-scope

### Biggest risk
**EOU deletion stranding existing users' preview.** Fresh installs *and* an unknown number of
existing users sit on `tdt_0_6b_v3_eou_streaming` (`TranscriberHolder.swift:56`). The
preserved-raw-value approach (§4.5) removes the *migration* risk — the stored value is kept and
its meaning is redefined, so no defaults migration runs — but the live behavior change (EOU
engine → scheduler) must be verified to actually paint preview text on those users' next
launch, and the orphaned `parakeet-eou-streaming/` bundle cleanup must delete only that literal
dir. **(The fork-vs-sibling-design risk is now resolved — see §8; it is no longer a blocker.)**

### Open questions a reviewer should attack hardest
1. **`silenceRMS` on Mac mics (the real remaining unknown).** 0.005 is iPhone-tuned. The §6
   gate (named corpus + ≤1 DEL/clip + ≤2% divergence) is the commitment, but the corpus does
   not exist yet — this is the single most likely source of a bad first impression (preview
   commits mid-word, or never appears in a quiet room). **Attack: is the threshold, or the
   *whole RMS-vs-VAD* choice, right for desktop audio?**
2. **`AsrManager` shared-cache contention under the stop fence.** §4.3.1 specifies the
   ordering (quiesce → final), but it leans on the claim that no preview tick can start once
   `stopped` is set AND that `sharedMLArrayCache` (`MLArrayCache.swift:78`) is never touched by
   two decodes at once. **Attack: is there any path — interruption teardown, cancel-during-tick,
   a second recording starting fast — where a tick and the final pass still overlap on that
   global cache?** This needs runtime verification, not just code reading (project memory:
   audio/inference changes need observed behavior).
3. **Does preview-quality==final-quality change the product?** Now that the preview is the
   same weights as the final, the "transcript gets worse at stop" failure mode disappears.
   Does that argue for *promoting* the preview to final on stop (skip the full re-pass) to
   save the stop-latency? **Decision: keep the full stop-pass** (it adds vocab rescore, which
   the lean preview skips, and is the byte-identical-final safety guarantee). Not reopened.
4. **Keep the tap-to-expand scrollable transcript** (`PillView.swift:297-376`)? It may be
   more valuable now (preview == final), or it may be clutter for a paste-at-cursor tool.

### Out of scope
- Removing Nemotron (kept as a separate option).
- Touching the final/saved transcript pipeline (must stay byte-identical).
- iOS keyboard-extension / App Group / Darwin / appex-memory machinery (§3).
- `ownsActiveRecording` faster-cadence path (unimplemented even on iOS).
- Vocabulary boosting *inside* the preview (vocab corrects on stop, per jot-mobile).
- The hardware-capability-matrix itself (consumed, not authored, here — §5).

---

## 8. Decision: `PreviewScheduler` port (DECIDED). `SlidingWindowAsrManager` rejected.

**Decision: build the `PreviewScheduler` port specified in this doc.** An independent reviewer
adjudicated the fork in its favor on hard evidence, and that evidence has been verified against
the FluidAudio source. The earlier "try the SDK first, it's less code" lean was **backwards** —
it weighed lines-of-code over my own §2.4 divergence measurement. Corrected below.

### The disqualifying evidence: `SlidingWindowAsrManager` carries decoder state across windows

`SlidingWindowAsrManager.transcribeWindow(...)` reads the manager's stored `decoderState`,
threads it through `transcribeChunk(_, decoderState: &state, …)`, and **writes it back**
(`self.decoderState = state`) — it is **never reset per window**
(`SlidingWindowAsrManager.swift:410-425`, verified). That is *exactly* the **carried-decoder-state**
algorithm jot-mobile measured at **10.9% mean divergence-from-final, up to 50%, and explicitly
REJECTED** (§2.4) in favor of **fresh per-call `TdtDecoderState` + overlap re-transcription at
1.3%** (§2.5).

Therefore shipping `SlidingWindowAsrManager` means **knowingly shipping the worse-measured
algorithm** — and worse, it **reintroduces the "transcript visibly changes at stop" flip** that
removing EOU is meant to eliminate: a carried-state windowed preview drifts from the full-file
final pass by ~11%+, so the user watches the preview "correct itself" at stop, which is the
exact EOU pathology. The `PreviewScheduler` port, by re-running the batch model with a fresh
decoder state on each tick, structurally tracks the final pass to ~1.3%.

> **Scope of the impact:** this divergence is **PREVIEW-ONLY**. The saved/pasted transcript is
> *always* the full-file batch pass on stop (§1.7, §7 Q3), so carried-state divergence is a
> **fidelity / UX concern, not a correctness bug** — it cannot corrupt the delivered text. But
> the entire point of the feature is preview fidelity, so a 10.9% preview-divergence engine
> fails the feature's own goal.

### Comparison (for the record)

| Dimension | **This plan — `PreviewScheduler` (CHOSEN)** | **`SlidingWindowAsrManager` (REJECTED)** |
|---|---|---|
| Decoder state | **Fresh per call, no carry** (`TdtDecoderState.make` per tick) → 1.3% divergence | **Carried across windows** (`SlidingWindowAsrManager.swift:410-425`) → 10.9%–50% divergence |
| Stop-flip pathology | Structurally avoided (preview tracks final) | **Reintroduced** (the EOU pathology we're removing) |
| Behavioral fidelity | Identical to the validated iOS app | New, untested-on-Mac, measured-worse algorithm |
| Control over commit/pause UX | Full (pause-as-commit, retry-not-discard) | Limited to `SlidingWindowAsrConfig` knobs |
| RAM | Reuses batch `AsrModels` (no extra weights) | Reuses batch `AsrModels` — same win (not a differentiator) |
| Lines of new code | More (scheduler + ring + lean path) | Less — **but irrelevant given the divergence** |

### `SlidingWindowAsrManager` — alternative considered & rejected

**Rejected.** It would only be reconsidered if a **Mac-audio corpus measurement proves that its
carried-state divergence is acceptable on Mac inputs** (i.e. that the iOS 10.9% figure does not
reproduce, which is implausible since the algorithm is identical and the divergence is
algorithmic, not device-specific). Absent that measurement, it is off the table. The "less code
to own" advantage does not survive contact with the divergence evidence.

**Do not ship both.** This doc supersedes `docs/pseudo-streaming/design.md`.

---

## 9. Phased rollout + verification

Feature-flagged, mirroring jot-mobile's `previewSource` idea. On macOS the flag is
`@AppStorage` (no App Group): `jot.preview.source` ∈ `{ "eou", "batch" }`, resolved at
**session start only**, surfaced as a Settings → Transcription "Preview engine" picker
(dev-only at first).

- **Phase 0 — DONE.** The §8 fork is decided: `PreviewScheduler` port. No further gate here.
- **Phase 1 — Lean path.** Add `Transcriber.previewTranscribe`; unit-confirm it matches the
  final text minus vocab rescore on a fixed sample. No wiring yet.
- **Phase 2 — Scheduler behind the flag.** Add `PreviewScheduler` + ring + the
  `.batchPreview` `StreamingEngine` case, plus the §4.3.1 stop-fence ordering. Wire it only
  when `jot.preview.source == "batch"`; EOU stays the default. Both engines feed the same
  `StreamingPartialStore` — visually A/B-able by flipping the flag.
- **Phase 3 — Validate, then flip the default.** Run the macOS SchedulerSim (below) against
  the named Mac-mic corpus; the §6 acceptance threshold (≤1 DEL/clip on the control set, ≤2%
  mean divergence) is the **gate**. Only on pass, flip `jot.preview.source` default to
  `"batch"` for fresh installs. **Exit criterion is the corpus pass, not a code review.**
- **Phase 4 — Delete EOU** (§4.5): remove `StreamingTranscriber.swift`, rewrite the
  `DualPipelineTranscriber` `.eou` branches, simplify download/cache, drop
  `sharedStreamingBundleProtection`, clean the orphaned `parakeet-eou-streaming/` dir.
  **Keep the enum cases (preserved raw values — §4.5), so no `jot.defaultModelID` migration.**
  **Phase exit criterion: a CLEAN COMPILE** (isolated `-derivedDataPath`) with the EOU file
  removed — the compiler's exhaustiveness check is the real proof every site was handled, not
  the paper inventory in §4.5.
- **Phase 5 — Capability gating:** consume the hardware-capability-matrix (§5); suppress
  preview below the gate.
- **Phase 6 — Remove the `"eou"` flag value** once `"batch"` has shipped as default without
  regression (mirrors jot-mobile's Phase-6 EOU-engine deletion). Same clean-compile gate.

### Verification approach

**Port jot-mobile's offline SchedulerSim as a macOS `tools/` target — this is committed, not
optional.** `tools/scheduler-sim/` (a small executable or test target) feeds recorded audio
through the `PreviewScheduler` offline and counts word-level deletions + divergence against the
full-file final pass. jot-mobile's SchedulerSim is how the 0.005 RMS and retry-not-discard
fixes were validated (3/40 → 0/40 counting deletions). **macOS requires its own** because the
RMS threshold is device-dependent (§6). Committed artifacts:
- **Corpus:** `tools/scheduler-sim/corpus/mac-mics/` — ≥40 clips across built-in/USB/Bluetooth
  mics, quiet and noisy rooms, including the slow-counting case that exposed the iOS drop bug.
- **Acceptance threshold (the Phase-3 gate):** ≤ 1 word-level deletion per clip on the
  counting/control set, AND mean divergence-vs-final ≤ 2% (iOS hit 1.3%; 2% is the macOS bar).
- **Re-run** on any change to `silenceRMS`, `minTickSpacingSamples`, the commit logic, or the
  retry-not-discard valve.

Without it, tuning `silenceRMS` / tick spacing is guesswork — so it is a build deliverable,
not a recommendation.

Runtime verification gate (per project memory: audio/inference changes need observed
behavior): on a real notarized-or-dev build, confirm (1) non-zero sample delivery into the
ring, (2) the pill shows live text within ~2 s of speech (first-tick-fast), (3) the pasted
final transcript is byte-identical to the pre-change batch output for a fixed utterance, and
(4) `quiesce()` does not drop the last window's words on a fast stop.

---

## 10. CLAUDE.md "when you ship a feature" checklist — what this touches

- **`docs/features.md`** — preview-engine change is user-visible (Settings picker + behavior).
- **`Resources/help-content.md` budget** — only if Help/Ask Jot copy mentions the preview
  engine; re-run the budget check.
- **Shortcuts registry** — **no change** (preview rides inside existing recording hotkeys;
  no new hotkey).
- **Status-pill states** — **no new `PillState`/`RecorderController.State` case** in the
  happy path (preview rides inside `.recording(streamingPartial:)`). Only touched if §7 Q5
  adds a distinct affordance.
- **Menu bar** — no change.
- **Settings pane** — **add** the "Preview engine" picker under Settings → Transcription with
  an `info.circle` "Learn more →" deep-link into Help (per CLAUDE.md convention).
- **Help tab** — add prose if the picker ships to users; wire the deep-link anchor.
- **Help infra tests** — run `HelpInfraTests.runAll()` / `InfoCircleAnchorTests` if a new
  deep-link anchor is added.
- **Setup wizard** — no change (no new permission).
- **Exhaustive switches** — adding the `.batchPreview` `StreamingEngine` case makes the
  compiler enumerate the four `DualPipelineTranscriber` seam methods; deleting EOU makes it
  enumerate every `ParakeetModelID` switch (§4.5). Let the compiler be the checklist.
