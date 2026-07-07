# Resilient import resume (auto-resume from scratch)

**Status:** design — awaiting review. Not implemented. Builds on `docs/auto-diarize-imports/design.md`.
**Ask (user):** when a live dictation interrupts an in-flight file import, don't discard it — **pause and auto-resume** when the mic is done, instead of forcing a re-drop. Confirmed: **resume-from-scratch** (re-transcribe), not mid-stream resume (the ASR engine exposes no partial-transcript checkpoint — see the parent thread). Silent/auto resume, not a tap-to-resume prompt.

## Current behavior (what we're changing)
- `RecorderController.runFlow()` (`:290`) calls `FileTranscriptionIngest.shared?.cancelInFlight()` the moment a dictation starts — the mic and file import share the **single-in-flight** `Transcriber` (`Transcriber.swift:175`, throws `.busy` on overlap), so they can't co-run.
- `cancelInFlight()` (`:202`) cancels `currentTask`, bumps `generation`, **`queue.removeAll()`**, resets `status = .idle`. Comment: *"the cancelled job is retriable; the user can drop the file again."* → We are deliberately reversing this "user re-drops" decision.

## Design

Two interruption windows, two resume shapes — unified by one rule: **resume the unfinished part when the recorder returns to `.idle`.**

### 1. Capture on interrupt (don't discard)
`cancelInFlight()` stops discarding and instead records a `pendingResume`:

```
enum ResumeJob {
    case transcribe(url: URL, filename: String)   // interrupted during transcription
    case diarize(recordingID: PersistentIdentifier, filename: String)  // interrupted/deferred during diarization
}
private var pendingResume: ResumeJob?
```

- **Interrupted during transcription** (`status == .importing`): the transcode-to-`.m4a` happens *after* transcription (`:517`), so nothing is saved yet. Capture `.transcribe(originalURL, filename)` — the original dropped file. Re-running it re-decodes + re-transcribes from scratch (the existing `enqueue(url)` path does exactly this). *Precondition:* the original file URL must still resolve on resume — for security-scoped drops, keep the scope open (or copy to a temp on drop) until the job truly completes OR is abandoned, not just until transcription starts. Verify current scope handling in `enqueue`/`handleDrop`.
- **Interrupted during diarization** (`status == .diarizing`): the transcript + Recording are *already saved*. Capture `.diarize(recording.persistentModelID, filename)`. Resume re-runs only `DiarizationRunner` on that recording — cheap, transcript never at risk.

`cancelInFlight()` keeps cancelling `currentTask` + bumping `generation` (the mic must get the engine now); it just stores `pendingResume` instead of `queue.removeAll()`-and-forget. A genuinely new drop, or an explicit user cancel, clears `pendingResume`.

### 2. Fold in the diarization guard (fixes the current skip)
Today the auto-diarize block skips diarization when `recorderIsIdle() == false` (design: auto-diarize-imports) — that **silently loses the labels**. Change skip → **defer**: if the recorder is busy when we reach the diarize step, set `pendingResume = .diarize(...)` and don't run now; the idle hook picks it up. Strictly better than skipping, and it's the same resume path.

### 3. Resume trigger (recorder → idle)
`RecorderController` already calls into the ingest on dictation *start* (`:290`); add the symmetric call on the transition back to `.idle` (after transcribe + paste, engine free):
```
FileTranscriptionIngest.shared?.resumePendingIfNeeded()
```
`resumePendingIfNeeded()` (@MainActor): if `pendingResume` and no `currentTask`, consume it — `.transcribe` → `enqueue(url)`; `.diarize` → fetch the Recording by id and run `DiarizationRunner`, saving `speakerTimeline`. Guard against re-entrancy and against resuming while another dictation/import is active. Single hook point (the one `.idle` transition) so every recorder flow — dictation, Rewrite-with-voice — triggers it.

### 4. UI
Add `case pausedForDictation(filename: String)` to `FileTranscriptionIngest.Status`. While paused the Home pill shows a quiet "Paused — resumes after dictation" caption (pause glyph). On resume it flips back to `.importing` / `.diarizing`. Update **every** exhaustive `switch` on `Status` (isImporting → true so the pill stays disabled; cancelInFlight; scheduleClear; HomePane caption; the `.help` tooltip added earlier).

### 5. Staleness / lifetime
- `pendingResume` is **in-memory** — a quit mid-import loses it (acceptable v1; the file transcription was never persisted anyway). Not worth SwiftData-persisting a resume queue now.
- Multiple dictations in a row: `pendingResume` simply waits for the idle after the *last* one. No timeout — the user asked for pause/resume, not expiry. A new drop or explicit cancel supersedes it.
- Only **one** `pendingResume` at a time (imports already run one-at-a-time). A second interruption during a resumed job just re-captures it.

## Interaction / risks
- **No mic regression:** the mic still preempts instantly (unchanged) — resume only happens *after* it's done.
- **Re-transcribe cost:** a long file interrupted at 90% re-does all of it. Accepted for v1 (this is option (b)); silence-chunked checkpointing is the deferred follow-up (`resilient-import-checkpoint`, separate doc).
- **Diarize double-run:** resuming `.diarize` on a recording that a user *also* manually "Detect speakers"'d is idempotent (same pipeline, overwrites `speakerTimeline`).
- **Security scope: RESOLVED — not a risk.** Jot is Developer-ID/notarized, **not App Store-sandboxed**; the codebase uses no `startAccessingSecurityScopedResource` and reads dropped file URLs directly (`HomePane.swift:118` → `enqueue`). So a dropped file's URL stays valid on disk indefinitely — re-enqueuing it on resume re-reads the original with no scope handling. (If Jot is ever sandboxed, revisit: copy the source to temp on drop.)
- **`enqueue` Guard 2:** `enqueue` refuses to start while `recorderIsIdle() == false` (`:182`). The resume hook fires on the idle transition, so `recorderIsIdle()` is true by then — resume's `enqueue(url)` proceeds normally, not the "Finish dictating first" failure. Confirm ordering.

## Blast radius
`FileTranscriptionIngest` (pendingResume + capture in cancelInFlight + resumePendingIfNeeded + Status case + defer-diarize), `RecorderController` (one idle-transition hook call), `HomePane` (paused caption + tooltip). Contained; reuses the existing queue + `DiarizationRunner`.
