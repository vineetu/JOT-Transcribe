# Audio-first, queued transcription — never lose audio

**Status:** design — **reviewed**. **Chosen scope (user): PERSIST-FIRST ONLY** (the safe MVP). The ordered-queue / auto-finish / banner half (§3.1, §3.4) is **DEFERRED** as a possible fast-follow — the review found it over-scoped and risky (it repeals "live speech wins", drops the Transform + indexing steps, races provenance, and forces splitting the fragile `stopAndTranscribe`). Persist-first alone closes BOTH gaps (orphaned WAV + `.busy` data loss) at ~20% of the risk and touches none of the fragile pipeline machinery.
**Principle (user):** audio is sacred — never lose it. A recording (audio + a Recents row) must survive any transcription outcome (busy, error, crash, quit); on failure the user **re-transcribes from Recents** (already works).

> ## Chosen implementation — persist-first only
> **Do (safest realization — success path UNTOUCHED):** leave the success flow exactly as today (it already inserts a complete, Transformed, indexed, provenance-committed row). Add "never lose audio" on the *edges only*:
> 1. **Persist-on-failure:** when a recorder transcription throws (`.busy`/error) in `runFlow`'s catch clauses (`RecorderController.swift:423-483`), persist a pending `Recording` row (audio filename + empty transcript + `pendingSince = .now`) so the just-finalized WAV isn't orphaned and shows in Recents immediately with a re-transcribe affordance. Requires the pipeline to expose the finalized `AudioRecording` on the failure path (it's on disk after `capture.stop()` regardless of transcription outcome) — a small, synchronous accessor, NOT the fragile async `stopAndTranscribe` split.
> 2. **Startup orphan-adoption scan:** on launch, scan `RecordingStore.audioDirectory` for WAV/m4a files with no `Recording` row → adopt each as a pending row (read duration via `AVAudioFile`). Covers the crash-mid-transcription case AND the ALREADY-shipping orphans (open Q3). Non-fragile, high value.
> 3. Because the SUCCESS path is unchanged, there is **no double-insert, no insert→update, and Transform/indexing/provenance are all inherited as-is** — the failure/orphan rows are simply empty+pending (nothing to Transform/index/commit until the user re-transcribes, which already does all three).
> This achieves the user's goal (never lose audio; busy → saved + message + manual re-transcribe) with the minimum surface and zero changes to the working live-dictation/success path.
>
> **Review must-handles for persist-first (all avoid the queue's blast radius):**
> - **R3 double-insert:** `RecordingPersister.$lastResult` currently INSERTs (`:52-68`). It must UPDATE the pre-created pending row by id, not insert a second one. This is the central change.
> - **F1 Transform preserved:** keep today's flow — the row is filled on the SUCCESS path AFTER the Transform tail (`RecorderController.swift:357-410`), so the stored/pasted text stays the transformed text. Persist-first only moves the row CREATION earlier; the fill still carries `lastTransformedTranscript ?? result.text` (`RecordingPersister.swift:51`).
> - **F3 indexing:** the update/fill step must still call `RecordingIndexer.shared?.index(...)` (as `RecordingPersister.swift:87` / `FileTranscriptionIngest.swift:417` do today) — the empty up-front row is (correctly) not indexed; the filled row must be.
> - **F2 provenance:** unchanged — no queue, existing transcribe→commit timing. The pre-created row's id is what `CorrectionProvenance.commit(transcriptID:)` targets.
> - **Voice-command exclusion:** persist-first ONLY for `token.owner == .recorder` + file import. Rewrite / Ask-Jot voice still delete their WAV (`VoiceInputPipeline.swift:301-303`) and never persist. User **cancel** still deletes + no row.
> - **Paste unchanged:** live dictation still transcribes inline + pastes as today (this scope does NOT defer/queue live dictation). A busy dictation surfaces a message ("Saved — Jot was busy; re-transcribe from Recents") and leaves the pending row; nothing auto-pastes late.
> - **`pendingSince: Date?`** additive-default migration (like `tags`/`editedAt`, `Recording.swift:36/42`) — zero-risk. Detail/list show a "Transcribing…/Needs transcription" chip on pending rows; re-transcribe (already exists) clears it.
> - **Existing orphans (open Q3):** optionally a one-time scan of the recordings dir for WAVs with no row → adopt as pending rows or delete (the bug has been shipping).

---

## 1. The gaps this closes (confirmed in code)

- **Row is created only AFTER a successful transcription.** `RecordingPersister` subscribes to `RecorderController.$lastResult`, which is published ONLY on success (`RecorderController.swift:386/406/419`); no catch path sets it. So on `.busy` / error / crash, **no `Recording` row is created**, and the recorder's already-on-disk WAV (`AudioCapture` writes it incrementally during capture, finalized at `stop()`) is **orphaned** — `RetentionService` only purges files owned by rows, so orphans accumulate invisibly forever. *(Core gap.)*
- **Single-in-flight `.busy` = data loss.** `Transcriber.transcribe` throws `.busy` if another job holds it (`Transcriber.swift:149`). A dictation during a file import / diarization hits this at stop time → `state = .error("Another transcription is already running.")` and the take is lost (the documented residual-risk window, `FileTranscriptionIngest.swift:36-51`). The current mitigation (dictation *cancels* the file import) also loses the *file's* work.

## 2. The model

Two orthogonal changes:

**(A) Persist audio + a Recents row UP FRONT, before transcription.** The moment a recorder session stops (or a file is accepted for import), write/keep the audio in the library and insert a `Recording` row with an empty transcript marked **pending**. Transcription then *fills in* that same row (exactly what re-transcribe already does in place). A crash/error/quit now always leaves a re-transcribable recording; nothing is orphaned.

**(B) Replace single-in-flight-throws-`.busy` with an ordered TRANSCRIPTION QUEUE.** All transcription requests (mic, file import, re-transcribe) funnel through one serial queue that owns the single `Transcriber`. When the engine is busy, a job **waits its turn** instead of throwing. Each job, on completion, updates its row's transcript + saves.

### 2.1 Paste behavior — the one subtlety (user-decided)
- **Engine free at submit (the common case):** the dictation transcribes immediately (seconds) and **pastes at the cursor**, exactly as today. Live dictation is unaffected in normal use.
- **Engine busy at submit (queued):** the dictation's audio is saved, it shows **"Transcription will complete once the current job finishes,"** and when it completes it lands in **Recents only — NO paste** (the cursor has long moved; user copies it from Recents). *User confirmed: queued items don't paste; save and paste-later-manually is fine.*

So the paste decision = **"did this job run immediately (queue empty at submit), or did it have to wait?"** Only immediate jobs paste.

## 3. Component design

### 3.1 `TranscriptionQueue` (new) — the serial owner of `Transcriber`
A `@MainActor ObservableObject` (or an actor with a published mirror) that owns the single `Transcriber` and exposes:
- `enqueue(job) -> ` an async result, where a job = `{ recordingID, audioURL, recordsProvenance, kind: .liveDictation | .fileImport | .reTranscribe }`.
- `@Published var depth: Int` / `@Published var activeKind` — drives the banner (§3.4).
- Runs jobs strictly FIFO, one at a time (the ANE does one at a time anyway; this also preserves the `CorrectionProvenance` single-slot invariant — only one `recordsProvenance:true` job runs at any moment).
- **`Transcriber.transcribe` stops throwing `.busy`** for queued callers — the queue guarantees serialization, so `.busy` becomes unreachable through the queue (keep the guard as a backstop for any non-queue caller, or route ALL callers through the queue).

Every completion: look up the `Recording` by id, set `transcript`/`rawTranscript`, clear `pendingSince`, `context.save()` — the re-transcribe template (`RecordingDetailView.retranscribe:494-505`).

### 3.2 Audio-first persistence
- **Mic (recorder):** in `RecorderController.runFlow`, after `capture.stop()` returns the `AudioRecording` (WAV on disk), **immediately** persist a pending `Recording` row (empty transcript, `pendingSince = .now`, `audioFileName`, `durationSeconds`) — do NOT wait for transcription, and do NOT gate this on `pipeline.stillActive` (a superseded token must not skip persistence — the whole point). Then submit the transcription to the queue with the row's id.
- **File import:** `FileTranscriptionIngest` reorders to persist-first — accept file → (ffmpeg/native decode as needed) → transcode into the library m4a → insert pending row → enqueue transcription. (Its current careful orphan-unlink on failure is preserved for the *decode/transcode* failures that happen before a row exists.)
- **Keep the genuine-discard deletions:** non-recorder owners (Rewrite / Ask Jot voice) still delete their WAV (`VoiceInputPipeline.swift:301-303`) and never persist a row; user **cancel** (`AudioCapture.cancel`) still deletes + no row. Only *completed recorder dictations and imports* persist up front.

### 3.3 `Recording.pendingSince: Date?` (additive migration)
New optional field, default `nil` (`complete`). Non-nil = transcription pending/queued/failed-retriable. Follows the additive-default pattern of `tags`/`editedAt` (`Recording.swift:36/42`) — no `VersionedSchema`, zero migration risk (verified pattern). The detail/list views show a subtle "Transcribing…" / "Queued" affordance for pending rows and offer **re-transcribe** (which already exists) as the manual retry. A startup pass MAY auto-resume any `pendingSince != nil` rows through the queue (crash/quit recovery) — nice-to-have, gated behind the queue.

### 3.4 Paste gate + banner
- **Paste gate:** reuse the `handleDeliveryBridge` choke point (`AppDelegate.swift:345`, "the single dictation auto-paste choke point"). Stamp each live-dictation result with an **`eligibleToPaste`** flag = "ran immediately (queue was empty at submit)", travelling WITH the result like `lastResultOriginApp` does (before-`lastResult` ordering, `RecorderController.swift:64-71`). `handleDeliveryBridge` pastes only when `eligibleToPaste`; a queued completion routes to `showSavedToRecents(...)` (the existing `skipNextPaste` behavior) — never delivers.
- **Banner:** an app-window top banner (the model-repair banner precedent, `JotAppWindow.migrationDownloadBanner:288-322`, driven by `@Published` on an injected `ObservableObject`). Add a branch driven by `TranscriptionQueue.depth`: "Transcription will complete once the current job finishes" (with the pending count). The **pill** shows the per-dictation confirmation via `PillState.savedToRecents` / a new `.queued` case.

## 4. Not breaking the fragile invariants (from the investigation)

- **30s transcribe watchdog** (`VoiceInputPipeline.swift:507-517`): a queued job must NOT count queue-wait against it. Because persistence + enqueue happen and the mic `runFlow` then RETURNS (it no longer synchronously awaits transcription when queued), the watchdog no longer wraps a queue wait. The watchdog stays scoped to a single active inference inside the queue.
- **Token/phase machinery** (`stillActive`/`phaseMatches`): the persist-row step is deliberately token-independent (must run even if the token was superseded). Transcription-fill happens via the queue against a stable `recordingID`, not a live token.
- **`lastAudioRecording`/`lastResult` publish ordering** (`RecorderController.swift:56-58`): the new `eligibleToPaste` flag publishes with the same before-`lastResult` ordering.
- **`recordsProvenance` single slot** (`Transcriber.swift:154-167`): the FIFO queue runs one job at a time → only one provenance-recording transcribe is ever live → invariant preserved (actually strengthened vs. today's ad-hoc overlap).
- **mic-vs-file cancel dance** (`RecorderController.swift:253` / `FileTranscriptionIngest` `cancelInFlight`): the queue REPLACES it. No more cancelling the file for a dictation — both queue and complete. Remove `cancelInFlight` + the reciprocal guard once the queue lands (they exist only to paper over the collision the queue eliminates).

## 5. Blast radius

**Large — this is a core-concurrency rework** touching the recording→persist→transcribe→paste path:
- New `TranscriptionQueue` + wiring all five `Transcriber.transcribe` call sites through it.
- `RecorderController.runFlow` — persist-first + enqueue + return (stop awaiting transcription inline for the queued case; keep inline-fast-path for the empty-queue case) + the `eligibleToPaste` flag.
- `RecordingPersister` — create the pending row up front (or a new persist path) instead of only on `$lastResult` success.
- `FileTranscriptionIngest` — reorder to persist-first + enqueue; drop `cancelInFlight`.
- `Recording` +`pendingSince`; detail/list pending affordance; startup resume (optional).
- `AppDelegate.handleDeliveryBridge` — `eligibleToPaste` gate.
- `JotAppWindow` banner + `PillState` queued case.

Given the fragility, implement **incrementally** with a build+review checkpoint after (a) persist-first + pending row, (b) the queue, (c) paste-gate + banner.

## 6. Risks & open questions

**R1 — Live-dictation latency must stay zero in the common case.** When the queue is empty, the dictation must transcribe inline and paste with today's latency — the queue must have a true fast path (submit → runs immediately → paste), not add a hop that delays every dictation. Verify no added latency for the free-engine case.

**R2 — "eligibleToPaste = queue was empty at submit" edge.** If a dictation submits to an empty queue but a *diarization* is holding the `CoreMLInferenceGate` (not the transcriber), does it still run "immediately"? Define eligibleToPaste against the transcriber queue depth; a short gate wait (diarization is ~seconds) is acceptable and still pastes. A long wait (behind a file import) → don't paste. Pick the threshold (queue-empty is the clean signal).

**R3 — Pending rows cluttering Recents.** A queued/failed pending row appears in Recents with no transcript yet. Ensure it renders sensibly ("Untitled recording" title already handled; add a "Transcribing…/Queued" chip) and that search/tag/retention handle an empty-transcript row. Auto-resume on launch prevents "stuck pending forever" after a crash.

**R4 — Rewrite / Ask Jot voice must stay OUT of this.** They intentionally discard audio and never persist. Confirm the persist-first path is gated to `token.owner == .recorder` + file import only.

**R5 — Re-transcribe/queue reentrancy.** Re-transcribe now also goes through the queue; ensure a user re-transcribing while a dictation is queued behaves (both serialize). The in-place row update must be idempotent.

**Open:**
1. Where does the queue live — a standalone `TranscriptionQueue` injected everywhere, or folded into `TranscriberHolder` (which already owns the transcriber + is injected as `@EnvironmentObject`)?
2. Auto-resume pending rows on launch — in v1 or a fast-follow?
3. Do we backfill/clean the *existing* orphaned WAVs (a one-time scan of the recordings dir for files with no row → either adopt as pending rows or delete)? Worth doing since the bug has been shipping.
