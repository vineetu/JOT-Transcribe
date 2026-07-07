# File-transcription progress (determinate where honest)

**Status:** design — awaiting review. Not implemented.
**Ask (user):** while transcribing an imported file, show "how much is done" instead of the indeterminate "Transcribing…" spinner.

## 1. What's actually available (from investigation)
- **Parakeet TDT path (default model):** FluidAudio `AsrManager` exposes `transcriptionProgressStream: AsyncThrowingStream<Double, Error>` — **real, monotonic processed-samples ÷ total-samples** progress, emitted automatically for audio > 15 s (`ASRConstants.maxModelSamples = 240_000`). This is TRUE progress, not an estimate. In-repo precedent exists: diarization already consumes a FluidAudio progress closure into a `ProgressView(value:)` (`SpeakerLabelsPane`).
- **Nemotron path (e.g. `nemotron_multilingual_latin` — the user's model):** `transcribeWithNemotron` does NOT touch `AsrManager` → **no progress stream**.
- **RTF is NOT constant with file length** (measured this session): ~48× on a 10-min clip but ~18× on a 65-min file. So a time-estimate `elapsed / (duration/RTF)` is **unreliable** — it would stall at 100% or finish early depending on the assumed RTF.

## 2. Design — determinate where honest, never a lying bar
- **Parakeet:** true determinate bar from `transcriptionProgressStream`. Show `ProgressView(value: fraction)` + `NN%`.
- **Nemotron / any file < 15 s / no stream:** do NOT fake a percentage (RTF variance makes it dishonest). Instead show an **indeterminate bar + an elapsed-time counter** ("Transcribing… 1:23"). Honest: it tells the user it's working and how long it's been, without a fraudulent completion estimate.
- Rationale: the user explicitly called out "don't make things up." A wrong percentage that sits at 100% for a minute is worse than an honest elapsed timer. (If we later want a Nemotron %, it needs a calibrated duration→RTF curve — out of scope for v1.)

## 3. Wiring (blast radius: contained to the transcription seam)
1. **`Transcriber`** — thread an optional `@Sendable (Double) -> Void` progress callback through `transcribeFile` → `transcribe` → `transcribeWithAsrManager`. Just before `manager.transcribe(...)`, obtain `await manager.transcriptionProgressStream` and spawn a child `Task { for try await p in stream { callback(p) } }`. Nemotron path: no callback fired (stays nil → UI uses the elapsed timer).
2. **`FileTranscriptionIngest`** — change `Status.importing(filename:)` → `.importing(filename: String, progress: Double?)` (nil = indeterminate/elapsed). Pass a callback into `transcribeFile` that hops to `@MainActor` and updates the status fraction. Start an elapsed-time ticker (a `Task` sleeping ~0.5s) for the indeterminate case; stop it on completion/failure.
3. **`HomePane.dictateZoneCaption`** `.importing` case (~:146): if `progress != nil` → `ProgressView(value: progress)` + `%`; else `ProgressView()` (indeterminate) + "Transcribing… M:SS" from the ticker.

## 3a. Coverage caveat (review finding A)
The determinate bar is reachable only via `FileTranscriptionIngest`'s `as? Transcriber` downcast. The composition factory returns a bare `Transcriber` for only `.tdt_0_6b_v3` / `.tdt_0_6b_v3_int4` (the standard/default Parakeet); the other Parakeet variants (v2-English-streaming, JA, v3-EOU) are wrapped in `DualPipelineTranscriber`, whose `transcribeFile` does not forward a progress callback — so they fall back to the honest **indeterminate + elapsed** UI even though their `AsrManager` *does* emit a stream. This is safe (honest fallback, not broken) and correct for Nemotron (no stream). **Follow-up to widen coverage:** add a progress-aware `transcribeFile` to `DualPipelineTranscriber` that forwards to its `.batch` `Transcriber`'s 3-param overload. Deferred — not worth destabilizing the dual-pipeline component for a minority of Parakeet variants when the fallback is already honest.

## 4. Interaction / risks
- **Single-in-flight** — Jot serializes transcription, and `ProgressEmitter` is one-session-at-a-time, so no clash. The preview path (`previewWithAsrManager`) is short (<15s) → no session opened → safe.
- **R1** — the child Task consuming the stream must be cancelled/finished with the transcription (no leak, no double-resume). Model it on the existing FluidAudio stream-consumption in the diarization progress path.
- **R2** — decode/transcode phases have no progress hook (single-shot); the bar covers the **transcription phase only** (the long pole — ~75s–3.5min for a 1-hr file; decode ~10-15s). Acceptable; optionally label the brief pre-phase "Decoding…".
- **R3** — don't regress live dictation. This touches `Transcriber.transcribe`, which live dictation also uses — the progress callback is OPTIONAL (nil for the mic path); verify the mic path is unchanged (callback nil → no behavior change).
- **R4** — elapsed ticker must not spin after completion (cancel it in every terminal branch).
