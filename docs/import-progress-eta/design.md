# Import progress: length context + measured countdown + load pre-phase

**Status:** spec — ready to implement. Extends `docs/transcription-progress/design.md`.
**Origin:** user reported the file-import status shows only an ever-increasing elapsed timer (no sense of "how much longer"). Investigation + on-device measurement (2026-07-07) established the real shape of the problem.

## Measured facts (this machine, `nemotron_en` one-shot via `tools/nemotron-probe`; diarize via `tools/diarize-probe`)
- **Transcription RTF is stable & fast:** 44–50× flat across 19 s → 19 min (`transcribe ≈ audio ÷ 46`). A 19-min file transcribes in **25 s**. The `docs/transcription-progress/design.md:9` "48× vs 18×" variance did NOT reproduce — a single per-machine rate predicts well here.
- **Diarization is also fast:** ~180–230× (19-min file = 4.9 s). Runs as the separate `.diarizing` phase; not the bottleneck.
- **Cold model load is ~15 s + ANE warmup.** This — and, for video, container audio-decode — is the actual multi-second wait, and today it's hidden inside the `.importing` timer with no label.

## What to build (three parts)

### 1. Total audio length in the importing caption (always; fully honest)
`Transcribing meeting.mp4 (47:30)… 1:20` — the `(47:30)` is the source audio duration, known up front. No prediction. Gives instant scale ("big file → longer wait").

### 2. Measured countdown (only when we can back it — honest by construction)
`Transcribing meeting.mp4 (47:30)… ~40s left`
- Applies ONLY to the indeterminate (Nemotron one-shot) path — the Parakeet path already shows a true determinate bar (`docs/transcription-progress/design.md`), leave it untouched.
- Rate = processing-seconds ÷ audio-seconds, **learned per-machine, persisted in `UserDefaults`**, EMA-smoothed. **NO hardcoded seed** (M1≠M4): the FIRST import on a machine shows length + timer only (part 1); the rate is recorded on its completion; import #2 onward shows the countdown. This is what makes it honest for every user, and the stable-RTF measurement is what makes the learned rate accurate.
- Countdown **only counts down, never claims done early**: `remaining = max(0, estimate − elapsed)`; when `elapsed > estimate` show `… almost done…` (never a stuck "0s"/100%).
- Gate: only when `audioDuration ≥ 20 s` (short files finish before a countdown is useful) AND a learned rate exists.
- Clock (`importStartedAt`) starts at the **`.importing` phase start (post-load)** so the estimate/learning exclude the cold-load pre-phase (part 3).

### 3. "Getting ready…" load pre-phase (the biggest fix for what the user saw)
When a job starts and the transcription model is not yet loaded, show a distinct caption (`Getting ready…` / "Loading model…") instead of the transcribing timer, so a cold load doesn't masquerade as a stalled transcribe.

## Implementation notes (follow existing patterns; do NOT alter the concurrency invariants)

**`Sources/Transcription/ParakeetModelID.swift`** — add:
```
/// True when file-import transcription emits a determinate processed÷total
/// fraction (chunked Parakeet batch path). False for the Nemotron one-shot
/// models (nemotron_en / _multilingual / _multilingual_latin) — those get the
/// measured-countdown + elapsed treatment instead. Mirrors `supportsStreaming`'s
/// exhaustive switch so a new case forces a decision.
var filesReportTranscriptionProgress: Bool   // true for all tdt_*, false for the 3 nemotron_* cases
```

**`Sources/Home/FileTranscriptionIngest.swift`**
- Add `Status.preparing(filename: String)` (part 3). Update EVERY exhaustive switch on `Status`: `isImporting` (treat `.preparing` as importing == true → keeps the Dictate pill disabled), `scheduleClear` (non-terminal, like `.importing`), and the HomePane render switch, and `cancelInFlight`'s switch (a cancel during `.preparing` → `pendingResume = .transcribe(currentJob)` just like `.importing`; if no `currentJob`, `.idle`).
- Add published: `@Published private(set) var importAudioDuration: TimeInterval?` and `@Published private(set) var importRemaining: TimeInterval?`. Reset both to nil in `stopElapsedTicker()` and `cancelInFlight()`.
- Add stored: `estimatedImportSeconds: TimeInterval?`, `currentAudioDuration: TimeInterval?`.
- Rate persistence (static helpers, key `jot.import.nemotronComputeSecPerAudioSec`):
  - `learnedImportRate() -> Double?` — returns stored value if `> 0`, else nil.
  - `recordImportRate(_ sample: Double)` — sanity `sample.isFinite && sample > 0 && sample < 100`; EMA `prior*0.6 + sample*0.4`, first sample sets directly.
- Duration probe: `static func probeAudioDuration(_ url: URL) async -> TimeInterval` — try `AudioFormat.duration(ofFileAt: url)`; if `≤ 0` try `AVURLAsset(url:).load(.duration)` → `CMTimeGetSeconds`; return `0` if unknown (ffmpeg-only containers). Never throws.
- Restructure `run()` (KEEP the `gen`/`currentTask`/`currentJob`/generation-guarded `defer`/tempWAV-cleanup logic EXACTLY as-is; only insert the phase steps):
  1. After the top cancel-guard, `let audioDur = await Self.probeAudioDuration(url)`.
  2. `let transcriber = transcriberHolder.transcriber`. If `!(await transcriber.isReady)`: `status = .preparing(filename:)`; `try? await transcriber.ensureLoaded()`; re-check `guard !Task.isCancelled`. (The later `transcribeFile` call's internal `ensureLoaded` is then a no-op.) NOTE: do NOT start the elapsed ticker during `.preparing`.
  3. Enter importing: set `currentAudioDuration = audioDur`; `importAudioDuration = audioDur > 0 ? audioDur : nil`; if `audioDur >= 20 && !transcriberHolder.primaryModelID.filesReportTranscriptionProgress`, `estimatedImportSeconds = learnedImportRate().map { audioDur * $0 }` (nil if no learned rate yet). `status = .importing(filename:, progress: nil)`; `startElapsedTicker()` (moved here from `start()` — see below).
  4. Proceed with the EXISTING decode/transcribe/transcode/save flow unchanged.
  5. On a successful transcription (right after `result` is obtained and non-empty, before transcode is fine, or right before the diarize block): if `audioDur >= 20 && !filesReportTranscriptionProgress`, and `importStartedAt` set, `Self.recordImportRate(Date().timeIntervalSince(importStartedAt!) / audioDur)`.
- Move `startElapsedTicker()` out of `start(_:)` into `run()` at the `.importing` transition (step 3). `start(_:)` still sets `status = .importing(... progress:nil)` initially? NO — change `start(_:)` to NOT set importing/ticker; `run()` owns the phase transitions now. But `start(_:)` must still set `currentJob`, bump generation, launch the task. Set an initial neutral status in `start`: leave it as whatever it was until `run()` sets `.preparing`/`.importing` on its first `await` — acceptable (sub-frame). To avoid a flash, `start(_:)` may set `status = .preparing(filename:)` optimistically; `run()` corrects to `.importing` if already loaded. Simpler: `start` sets `.preparing(filename:)`; `run` immediately flips to `.importing` when `isReady`. Choose whichever keeps the exhaustive switches happy.
- Ticker: in `startElapsedTicker`, after updating `importElapsed`, also set `importRemaining = estimatedImportSeconds.map { max(0, $0 - importElapsed!) }` (nil when no estimate).

**`Sources/Home/HomePane.swift`** (`dictateZoneCaption`, ~155–182, 249–255)
- New `.preparing(let filename)` case: spinner + `Text("Getting ready to transcribe \(filename)…")`.
- `.importing` nil-progress branch: build the caption as `Transcribing \(filename)\(lengthSuffix)\(etaOrElapsedSuffix)` where
  - `lengthSuffix` = `" (M:SS)"` from `fileIngest.importAudioDuration` (empty if nil),
  - if `fileIngest.importRemaining != nil` → `"… ~\(clock(remaining)) left"` (or `"… almost done…"` when remaining rounds to 0), else the existing `elapsedSuffix(importElapsed)`.
  - Reuse the existing `%d:%02d` formatting idiom; add a `clock(_:)` helper.
- Determinate branch (`progress != nil`): unchanged, but may append the same `(M:SS)` length suffix for consistency (optional).

## Out of scope / do not touch
- The `gen`/generation/`currentTask`/`cancelInFlight`/`resumePendingIfNeeded`/`pendingResume` concurrency machinery — only ADD the new state transitions listed; do not restructure the resume logic.
- The Parakeet determinate bar path.
- Diarization phase timing UI (fast enough; leave `.diarizing` caption as-is).
- The separate latent bug that multilingual imports run English Nemotron (`DualPipelineTranscriber.swift:210`) — noted, not fixed here.

## Verification (DEBUG, before declaring done)
- Builds clean (app target).
- Trace all exhaustive `switch` sites on `Status` compile (the compiler is the checklist for the new `.preparing` case).
- Manual reasoning: cold import → `.preparing` → `.importing` (timer from 0, excludes load); warm import #1 (no rate) → length + timer; warm import #2 → length + `~Ns left`; short (<20 s) file → length + timer, no countdown; Parakeet model → determinate bar unchanged.
