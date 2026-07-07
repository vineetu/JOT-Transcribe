# Auto-diarize imported files

**Status:** design — awaiting review. Not implemented (post-1.17.3).
**Ask (user):** when a user imports an audio/video file, automatically run speaker diarization too — they shouldn't have to click "Detect speakers" separately.

## Decisions (user-confirmed)
- **Scope:** auto-diarize after a **FILE IMPORT** finishes transcribing. NOT live mic dictation (single-speaker).
- **Model download:** if the ~22 MB speaker model isn't present, the first import **auto-downloads** it (via `prepareIfNeeded`), then labels. On-device.
- **Toggle:** an **Advanced** setting "Detect speakers automatically on imported files", **default ON** (`@AppStorage`), in the Speaker labels pane.

## Approach
Reuse the exact pipeline "Detect speakers" already runs (`RecordingDetailView.detectSpeakers`, `:573`): `prepareIfNeeded → DiarizationAudio.readMono16kFloat(url) → holder.process(samples) → DiarizationTimelineBuilder.buildPayload(result, transcript, duration) → encode → recording.speakerTimeline`.

1. **Extract a shared runner** so both callers share one code path — e.g. a free func / small type:
   ```
   DiarizationRunner.run(holder:audioURL:transcript:) async throws -> SpeakerTimelinePayload?
   // prepareIfNeeded → readMono16kFloat → (empty → throw) → process → buildPayload
   // returns nil == single speaker (dominance gate); throws on model/audio/process error
   ```
   Refactor `detectSpeakers()` to call it (UI: error/status/save unchanged).

2. **`FileTranscriptionIngest`** — inject `DiarizerHolder` (add to `init` + the `JotComposition` construction at `:759`, holder already exists at `:731`). In `run()`, AFTER the `Recording` is inserted + saved with its transcript:
   - If `@AppStorage("jot.diarize.autoDetectOnImport", default true)` is on AND `Features.speakerLabels`:
   - Set status to a new **`.diarizing(filename:)`** state ("Detecting speakers…").
   - `let payload = try await DiarizationRunner.run(holder:, audioURL: RecordingStore.audioURL(for: recording), transcript: recording.transcript)` — this `prepareIfNeeded`s (downloads model if absent per the decision).
   - On success: `recording.speakerTimeline = encode(payload)` (nil payload = single speaker → leave nil), `context.save()`.
   - **Graceful:** any diarization failure (model download fails, process errors) is caught + logged; the transcript+recording are ALREADY saved, so the import still succeeds — just without labels. Never fail the import over diarization.
   - Runs AFTER transcription (sequential) so the `CoreMLInferenceGate` (ASR vs diarizer) is uncontended.

3. **Status UI** — add `.diarizing(filename:)` to `FileTranscriptionIngest.Status`; render in `HomePane.dictateZoneCaption` ("Detecting speakers in <file>…" with the person.wave.2 glyph). Update every exhaustive `switch` on `Status`.

4. **Toggle** — `SpeakerLabelsPane`: add a Toggle bound to `@AppStorage("jot.diarize.autoDetectOnImport")` (default true), shown only when Advanced is on (the pane is already Advanced-gated). Copy: "Detect speakers automatically on imported files."

## Interaction / risks
- **Only file import** — the mic path (`RecorderController`) never calls this. Verify.
- **Model download on first import** blocks the diarize step (not the transcript, which is already saved). Show "Detecting speakers…" during it; if download fails, log + leave unlabeled.
- **Single-speaker / same-room** files → `buildPayload` returns nil → no timeline (correct; not every import gets labels).
- **Queue** — a file import already runs one-at-a-time; the diarize step extends that job. A live dictation preempting mid-import is already handled (import cancelled) — diarization is inside the same cancellable job.
- **Gate-contention residual (known, accepted for v1)** — diarization holds `CoreMLInferenceGate`, serialized against the mic's stop-time transcription (design D6). Cancelling the import Task stops the diarize result from persisting/clobbering status, but does NOT abort an already-running `manager.process()` (vendored CoreML, not interruptible) or release the gate early. So a dictation that *starts* mid-diarize waits the diarize pass out before its transcript pastes. Mitigations: (1) `run()` re-checks `recorderIsIdle()` before starting diarize — if the user is already dictating when the import lands, auto-diarize is skipped (they can "Detect speakers" manually later); (2) a diarize pass is short + bounded. The residual "starts dictating during diarize" window is left open; a cancellation-aware gate is a possible fast-follow but has limited value (can't abort the in-flight CoreML call). This makes auto-diarize fire the pre-existing gate mechanism more often than the manual button did — a genuine (bounded) UX cost, not a correctness bug.
- **No double-diarize** — an imported file that the user later hits "Detect speakers" on just re-runs (idempotent, same result).

## Blast radius
`RecordingDetailView` (extract runner), new `DiarizationRunner`, `FileTranscriptionIngest` (inject holder + diarize step + Status case), `HomePane` (status render), `SpeakerLabelsPane` (toggle), `JotComposition` (pass diarizerHolder). Contained; reuses the shipped diarization pipeline verbatim.
