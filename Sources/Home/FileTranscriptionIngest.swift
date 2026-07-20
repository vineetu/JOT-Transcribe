@preconcurrency import AVFoundation
import Foundation
import SwiftData
import UniformTypeIdentifiers
import os.log

/// Ingests a dropped/picked audio file on Home into a normal `Recording` row
/// (design `docs/audio-file-transcription/design.md`, reviewed — §4.1).
///
/// Runs on the main actor and saves the SAME UI `ModelContext` the app
/// injects everywhere else, so `RecordingsListView`'s `@Query` auto-refreshes
/// the instant the row lands — mirroring `RecordingPersister.persist`
/// (`Sources/Library/RecordingPersister.swift`). Deliberately NOT routed
/// through `RecorderController`/`VoiceInputPipeline` (mic-coupled: paste,
/// disconnect salvage, streaming preview) — this flow shares none of that.
///
/// ## Mic-vs-file collision (review C1, DATA LOSS — design §6 R1)
/// `Transcriber` is single-in-flight: overlapping calls throw `.busy`. A live
/// dictation must never be lost to a running file job. Two guards close the
/// loop from both directions:
///
///  1. **File → mic:** `RecorderController.runFlow()` calls `cancelInFlight()`
///     the INSTANT a new dictation starts — before any mic capture begins
///     (see that file's `runFlow()`). This job checks `Task.isCancelled`
///     before and after the actor-isolated `transcriber.transcribeFile(...)`
///     call, so a job cancelled before it reaches that call never sets the
///     transcriber's busy flag, and a job cancelled after it returns is
///     discarded (no `Recording` inserted, no stray file left behind) — and
///     captured as a `pendingResume` that auto-retries once the recorder
///     returns to idle (docs/resilient-import-resume/design.md).
///  2. **Mic → file:** `enqueue(_:)` refuses to START a brand-new file job
///     while a dictation is already in flight (`recorderIsIdle() == false`).
///     Without this, a freshly-dropped file could grab the transcriber's busy
///     flag WHILE the mic is still recording, and the mic's own later
///     stop-time `transcribe()` call would be the one that loses the race.
///
/// **Residual risk (documented honestly — review A):** FluidAudio's
/// `AsrManager` exposes no mid-inference cancellation hook, so a file job that
/// has ALREADY entered the actor's ANE-inference stage when a dictation starts
/// cannot be preempted — `cancelInFlight()` stops it from PERSISTING a result,
/// but it keeps holding `Transcriber`'s single-in-flight slot until that
/// inference finishes. For a LONG file that window is the whole remaining
/// inference (seconds to minutes), NOT small. If the user completes a dictation
/// during it, the mic's stop-time `transcribe()` throws `.busy` and that take
/// is lost — surfaced as an error pill ("Another transcription is already
/// running"), recoverable by re-dictating, but genuinely lost, not salvaged.
/// This is the narrow (concurrent-dictation-during-an-active-import), non-silent
/// edge the design's C1 couldn't fully close without either a cancellation-aware
/// `AsrManager` or a bounded retry-salvage on the mic's stop-time path — the
/// latter deliberately NOT added here because that path is token/phase/watchdog-
/// guarded fragile concurrency code, and destabilising it for this edge is a
/// worse risk than the edge itself. Tracked as a follow-up.
///
/// Segment-sliced diarize (accepted expansion of the same C1 class): the
/// `.diarizing` phase now ALSO occupies the transcription engine — the sliced
/// pass re-transcribes each speaker run, roughly ~1× the audio duration in
/// total on top of the import's own transcription. The per-slice windows are
/// short (a dictation starting between slices cancels cleanly and the pass is
/// parked for resume), but a dictation whose stop-time transcribe lands while
/// a single long slice is mid-inference hits the same `.busy` edge as above.
@MainActor
final class FileTranscriptionIngest: ObservableObject {
    /// Cross-cutting handle so `RecorderController` can reach the live
    /// instance without a constructor-injection cycle (recorder is
    /// constructed before this service exists, since this service needs a
    /// `recorderIsIdle` read of the recorder) — same pattern as
    /// `RecordingIndexer.shared`.
    static var shared: FileTranscriptionIngest?

    enum Status: Equatable {
        case idle
        /// Import-progress ETA (docs/import-progress-eta/design.md §3): the
        /// transcription model isn't loaded yet — a cold ANE load (~15s,
        /// measured) is happening before any transcribing work starts.
        /// Distinct from `.importing` so a cold load doesn't masquerade as a
        /// stalled transcribe; no elapsed ticker runs during this phase.
        case preparing(filename: String)
        /// `progress`: `nil` = indeterminate (Nemotron, or any file ≤ ~15s —
        /// no honest percentage available; the UI shows a spinner + elapsed
        /// time instead, from `importElapsed`). Non-nil = a real
        /// processed-samples ÷ total-samples fraction from FluidAudio's
        /// Parakeet progress stream (docs/transcription-progress/design.md).
        case importing(filename: String, progress: Double?)
        case success(filename: String)
        case failure(message: String)
        /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
        /// The import's audio was saved to the library and a pending Recents
        /// row was created, but transcription itself didn't run (engine busy,
        /// model not ready). Deliberately distinct from `.failure` — nothing
        /// was lost, so the caption shouldn't read as an error.
        case savedPending(filename: String)
        /// Auto-diarize (docs/auto-diarize-imports/design.md): transcription
        /// already succeeded and the `Recording` is already saved — this is
        /// the post-success "Detect speakers" pass running automatically,
        /// gated by `autoDiarizeImports`. Distinct from `.importing` so the
        /// caption can show a different glyph/message; a failure here never
        /// regresses to `.failure` (see `run()`) — it just returns to
        /// `.success` unlabeled.
        case diarizing(filename: String)
        /// Resilient import resume (docs/resilient-import-resume/design.md):
        /// a live dictation preempted the in-flight job. The unfinished part
        /// was captured as `pendingResume` and will auto-resume (silently)
        /// when the recorder returns to `.idle` — see `resumePendingIfNeeded()`.
        /// Non-terminal: `scheduleClear` never resets it, and `isImporting`
        /// stays `true` so the Dictate pill remains disabled.
        case pausedForDictation(filename: String)
    }

    /// Resilient import resume (docs/resilient-import-resume/design.md §1):
    /// the unfinished part of a job interrupted by a live dictation.
    /// Resume-from-scratch — a transcription-phase interrupt re-transcribes
    /// the original dropped URL (nothing was saved yet; the transcode to
    /// `.m4a` happens AFTER transcription); a diarization-phase interrupt
    /// re-runs only `DiarizationRunner` on the already-saved `Recording`.
    private enum ResumeJob {
        case transcribe(url: URL, filename: String)
        case diarize(recordingID: PersistentIdentifier, filename: String)
    }

    private enum IngestError: Error {
        case transcodeFailed
        case transcode(NSError)
        case emptySourceAudio
        /// The bundled ffmpeg helper is missing/non-executable (corrupt or
        /// incomplete install — design §8.8 "Missing" callout).
        case ffmpegUnavailable
        /// ffmpeg decoded successfully but found no audio stream to extract
        /// (design §8.8 R6 — reconciled with the §7.2 video "no audio"
        /// message rather than the generic decode-failure message).
        case ffmpegNoAudio
        /// ffmpeg exited non-zero / produced empty output for a reason other
        /// than "no audio" — an unsupported inner codec, DRM-in-mkv, a
        /// genuinely corrupt file, etc. (design §8.8 R7 — a dedicated
        /// message, not the generic "corrupted or unsupported" one).
        case ffmpegDecodeFailed
        case ffmpegTimedOut
    }

    @Published private(set) var status: Status = .idle

    /// Elapsed time since the current import job started, ticking ~2x/sec.
    /// Only meaningful (and only shown) while `status` is `.importing` with
    /// a `nil` progress fraction — the honest fallback for Nemotron / short
    /// files where a determinate percentage would be a lie (design §2).
    /// `nil` whenever no job is running.
    @Published private(set) var importElapsed: TimeInterval?

    /// Import-progress ETA (docs/import-progress-eta/design.md §1): total
    /// audio length of the current import, probed up front. `nil` when no
    /// job is running or the duration couldn't be determined. Shown
    /// regardless of which model handles transcription — pure context, no
    /// prediction involved.
    @Published private(set) var importAudioDuration: TimeInterval?

    /// Import-progress ETA (docs/import-progress-eta/design.md §2): measured
    /// countdown for the indeterminate (Nemotron one-shot) import path.
    /// `nil` until a per-machine rate has been learned from a completed
    /// import, the file is too short to bother, or the active model already
    /// reports real progress. Only ever counts down (see `startElapsedTicker`).
    @Published private(set) var importRemaining: TimeInterval?

    private let log = Logger(subsystem: "com.jot.Jot", category: "FileTranscriptionIngest")
    private let context: ModelContext
    private let transcriberHolder: TranscriberHolder
    private let recorderIsIdle: () -> Bool
    private let diarizerHolder: DiarizerHolder

    /// Advanced toggle (docs/auto-diarize-imports/design.md), default ON —
    /// read via `UserDefaults` directly rather than `@AppStorage` since this
    /// is a plain `ObservableObject`, not a `View`. `SpeakerLabelsPane` binds
    /// the same key with `@AppStorage` for the Settings toggle.
    private var autoDiarizeImports: Bool {
        (UserDefaults.standard.object(forKey: "jot.diarize.autoDetectOnImport") as? Bool) ?? true
    }

    private var currentTask: Task<Void, Never>?
    /// Bumped on every `start()` and every `cancelInFlight()`. A job cancelled
    /// mid-inference whose `Task` returns LATE (after a newer job has started)
    /// must not nil out the newer job's `currentTask` in its `defer` — that
    /// would defeat a subsequent `cancelInFlight()` (review B). The `defer`
    /// only relinquishes the slot when its captured generation is still current.
    private var generation = 0
    /// File-vs-file collisions (design §3.5): FIFO, one at a time.
    private var queue: [URL] = []
    /// Resilient import resume (design §1): set by `cancelInFlight()` when a
    /// live dictation preempts an in-flight job (and by the auto-diarize
    /// defer-not-skip path). Consumed by `resumePendingIfNeeded()` on the
    /// recorder's next `.idle` transition. In-memory only — a quit loses it
    /// (accepted v1). At most one at a time; a NEW user drop supersedes it.
    private var pendingResume: ResumeJob?
    /// Context of the job currently in `.importing` so a mid-transcription
    /// `cancelInFlight()` can capture it as `.transcribe`. Set in `start(_:)`,
    /// cleared on terminal completion (`run()`'s defer) and after capture.
    private var currentJob: (url: URL, filename: String)?
    /// Set immediately before a diarize pass runs (both the post-import
    /// auto-diarize block and the resumed-diarize path) so a mid-diarize
    /// `cancelInFlight()` can capture it as `.diarize`. Cleared when the
    /// pass finishes and after capture.
    private var currentDiarizingRecordingID: PersistentIdentifier?
    /// Auto-clears the terminal (success/failure) banner after a beat,
    /// mirroring `RecorderController.scheduleAutoRecoveryIfNeeded()`'s idiom.
    private var clearTask: Task<Void, Never>?

    /// Ticks `importElapsed` every ~0.5s while a job is running. Started in
    /// `start(_:)`, stopped on every terminal branch (success/failure/
    /// savedPending, via the `defer` in `run()`) and on `cancelInFlight()`.
    private var elapsedTickTask: Task<Void, Never>?
    private var importStartedAt: Date?
    /// Import-progress ETA (docs/import-progress-eta/design.md §2): this
    /// job's predicted total processing time, computed once at the
    /// `.importing` transition from the learned per-machine rate. `nil` when
    /// no rate has been learned yet, the file is too short, or the active
    /// model already reports real progress.
    private var estimatedImportSeconds: TimeInterval?
    /// Import-progress ETA (docs/import-progress-eta/design.md §1): this
    /// job's probed audio duration (raw, `0` when unknown — as opposed to
    /// the published `importAudioDuration`, which is `nil` in that case).
    private var currentAudioDuration: TimeInterval?

    /// Throttles `.importing` progress updates to ~10/sec (design §3.2) —
    /// FluidAudio's stream can emit more often than the UI needs to redraw.
    /// Always let a terminal `1.0` through immediately.
    private var lastProgressUpdateAt: Date = .distantPast

    init(
        context: ModelContext,
        transcriberHolder: TranscriberHolder,
        recorderIsIdle: @escaping () -> Bool,
        diarizerHolder: DiarizerHolder
    ) {
        self.context = context
        self.transcriberHolder = transcriberHolder
        self.recorderIsIdle = recorderIsIdle
        self.diarizerHolder = diarizerHolder
    }

    var isImporting: Bool {
        switch status {
        case .importing, .diarizing, .pausedForDictation, .preparing:
            return true
        case .idle, .success, .failure, .savedPending:
            return false
        }
    }

    /// Whether the dictation recorder is idle right now — the SAME injected
    /// read guard 2 uses (`enqueue`). Exposed (via `shared`) for the Library
    /// re-transcribe actions: on the multilingual Nemotron ship a
    /// re-transcribe shares the live streaming engine with dictation, so
    /// those sites must refuse to start while a dictation is in flight,
    /// mirroring this ingest's own mic → file guard.
    var recorderIsCurrentlyIdle: Bool { recorderIsIdle() }

    /// Entry point for both drag-and-drop and the "browse…" picker.
    func enqueue(_ url: URL) {
        if let message = Self.validate(url) {
            status = .failure(message: message)
            scheduleClear()
            return
        }

        // Guard 2 (§6 R1, mic → file direction): refuse to start a NEW job
        // while a dictation is in flight — see the type doc above.
        guard recorderIsIdle() else {
            status = .failure(message: "Finish dictating first, then drop the file again.")
            scheduleClear()
            return
        }

        // Resilient import resume: a genuinely NEW accepted drop supersedes
        // any interrupted job waiting to auto-resume (design §1 — "a new
        // drop, or an explicit user cancel, clears `pendingResume`").
        // Cleared only AFTER both guards pass so a rejected drop doesn't
        // silently discard the pending resume. Harmless on the resume path
        // itself: `resumePendingIfNeeded()` nils `pendingResume` before
        // re-entering here.
        pendingResume = nil

        // `currentTask != nil` rather than `isImporting`: identical for the
        // pre-existing states (`.importing`/`.diarizing` always have a live
        // task), but `.pausedForDictation` reports `isImporting == true`
        // with NO task — appending there would strand the drop with nothing
        // running to drain the queue. A new drop that reaches this point
        // while paused (recorder idle, resume not yet fired) starts now.
        if currentTask != nil {
            queue.append(url)
        } else {
            start(url)
        }
    }

    /// Called by `RecorderController.runFlow()` the INSTANT a new dictation
    /// starts, before any mic capture begins (§6 R1, preferred fix "a").
    /// Cancels the in-flight job — the mic must get the engine now — but no
    /// longer discards it (docs/resilient-import-resume/design.md, reversing
    /// the original "user re-drops" decision): the unfinished part is
    /// captured as `pendingResume` and auto-resumed by
    /// `resumePendingIfNeeded()` when the recorder returns to `.idle`.
    /// Already-queued (not-yet-started) drops stay queued — they were never
    /// in flight, and the resumed job's completion drains them as usual.
    func cancelInFlight() {
        guard currentTask != nil || !queue.isEmpty else { return }
        log.info("Live dictation started — pausing in-flight file transcription for resume")
        currentTask?.cancel()
        currentTask = nil
        generation &+= 1
        stopElapsedTicker()
        switch status {
        case .importing, .preparing:
            // Transcription-phase interrupt (including a cold-load interrupt
            // during `.preparing` — docs/import-progress-eta/design.md §3):
            // nothing saved yet (the m4a transcode happens AFTER
            // transcription) — resume re-transcribes the original dropped
            // URL from scratch. Jot is not sandboxed, so the URL stays
            // readable with no security-scope handling.
            if let job = currentJob {
                pendingResume = .transcribe(url: job.url, filename: job.filename)
                status = .pausedForDictation(filename: job.filename)
            } else {
                status = .idle
            }
        case .diarizing(let filename):
            // Diarization-phase interrupt: the Recording + transcript are
            // already saved — resume re-runs only the diarize pass.
            if let recordingID = currentDiarizingRecordingID {
                pendingResume = .diarize(recordingID: recordingID, filename: filename)
                status = .pausedForDictation(filename: filename)
            } else {
                status = .idle
            }
        case .idle, .success, .failure, .savedPending, .pausedForDictation:
            break
        }
        currentJob = nil
        currentDiarizingRecordingID = nil
    }

    /// Resilient import resume (docs/resilient-import-resume/design.md §3):
    /// called by `RecorderController` on its transition back to `.idle` —
    /// the symmetric counterpart of the dictation-start `cancelInFlight()`
    /// hook. Consumes `pendingResume` (nil'd FIRST, guarding re-entrancy):
    /// a `.transcribe` re-enters the normal `enqueue` path (Guard 2 passes —
    /// the recorder is idle by definition here); a `.diarize` re-runs only
    /// `DiarizationRunner` on the already-saved `Recording`. Silent
    /// auto-resume — no prompt.
    func resumePendingIfNeeded() {
        guard currentTask == nil, recorderIsIdle(), let job = pendingResume else { return }
        pendingResume = nil
        // Leave the paused caption behind before re-entering `enqueue` /
        // `startDiarizeResume` (both set their own in-progress status).
        if case .pausedForDictation = status { status = .idle }
        switch job {
        case .transcribe(let url, _):
            log.info("Recorder idle — resuming interrupted file transcription")
            enqueue(url)
        case .diarize(let recordingID, let filename):
            log.info("Recorder idle — resuming deferred speaker detection")
            startDiarizeResume(recordingID: recordingID, filename: filename)
        }
    }

    /// Diarize-only resume: the transcript/`Recording` already exist — only
    /// the speaker-detection pass was interrupted (or deferred because the
    /// recorder was busy). Mirrors `start(_:)`'s task/generation discipline
    /// so a fresh dictation can preempt (and re-capture) this pass too.
    private func startDiarizeResume(recordingID: PersistentIdentifier, filename: String) {
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.persistentModelID == recordingID }
        )
        guard let recording = (try? context.fetch(descriptor))?.first else {
            // The recording was deleted while paused — nothing to label.
            log.info("Resumed diarize target no longer exists — dropping resume")
            return
        }
        generation &+= 1
        let gen = generation
        currentJob = nil
        currentDiarizingRecordingID = recordingID
        status = .diarizing(filename: filename)
        startElapsedTicker()
        currentTask = Task { @MainActor [weak self] in
            await self?.runDiarizeOnly(recording: recording, filename: filename, generation: gen)
        }
    }

    /// The resumed counterpart of `run()`'s auto-diarize block — same
    /// graceful-failure contract (a diarize failure never surfaces as
    /// `.failure`; the transcript is already safe) and the same gen-guarded
    /// defer so a late return can't clobber a newer job's slot.
    private func runDiarizeOnly(recording: Recording, filename: String, generation gen: Int) async {
        defer {
            if gen == generation {
                stopElapsedTicker()
                currentTask = nil
                currentDiarizingRecordingID = nil
                processNextQueued()
            }
        }
        do {
            let outcome = try await DiarizationRunner.run(
                holder: diarizerHolder,
                audioURL: RecordingStore.audioURL(for: recording),
                transcript: recording.transcript,
                sliceTranscribe: SegmentSlicing.sliceTranscriber(using: transcriberHolder.transcriber)
            )
            if !Task.isCancelled, let payload = outcome.payload, let data = try? JSONEncoder().encode(payload) {
                recording.speakerTimeline = data
                applySlicedTranscriptIfAvailable(outcome, to: recording)
                try? context.save()
            }
        } catch is CancellationError {
            // Preempted AGAIN mid-resume — `cancelInFlight` re-captured it
            // (status was `.diarizing`, `currentDiarizingRecordingID` set),
            // so the next idle just retries. No error, no save.
            return
        } catch TranscriberError.busy {
            // The sliced pass needs the transcription engine and someone else
            // owns it right now (e.g. an Ask Jot / Rewrite voice capture that
            // slipped past the idle check). Park it again — same contract as
            // the recorder-busy defer — and let the next idle hook retry.
            pendingResume = .diarize(recordingID: recording.persistentModelID, filename: filename)
        } catch {
            log.error("Resumed diarize failed for \"\(filename, privacy: .public)\": \(String(describing: error))")
        }
        guard !Task.isCancelled else { return }
        status = .success(filename: filename)
        scheduleClear()
    }

    /// Segment-sliced transcription (docs/speaker-diarization follow-up):
    /// when the diarize pass produced per-run slice transcripts, the runs'
    /// joined text IS the recording's plain transcript for a diarized import
    /// (speaker changes = paragraph breaks) — attribution-exact, and it keeps
    /// transcript and timeline agreeing. Re-indexes for AI search since the
    /// insert-time index call used the superseded whole-file text.
    /// `rawTranscript` deliberately keeps the whole-file raw decode (its
    /// "pre-cleanup original" role is unchanged). No-op for the proportional
    /// fallback (`slicedTranscript == nil`) — the whole-file transcript the
    /// import already saved stays authoritative there.
    private func applySlicedTranscriptIfAvailable(
        _ outcome: DiarizationRunner.Outcome,
        to recording: Recording
    ) {
        guard let sliced = outcome.slicedTranscript, !sliced.isEmpty else { return }
        // A PARKED diarize pass (`runDiarizeOnly`) can fire hours after the
        // import — long enough for the user to have hand-edited the
        // transcript in the detail view. Never clobber a hand-edit: the
        // sliced timeline payload is still saved (exact attribution), but
        // the plain transcript stays the user's. `editedAt` is set by the
        // detail-view editor and cleared by re-transcribe.
        guard recording.editedAt == nil else { return }
        recording.transcript = sliced
        RecordingIndexer.shared?.index(recordingID: recording.id, text: sliced)
    }

    /// FFmpeg-only formats (design §8.5, review R5 — a FINITE explicit
    /// allowlist, never a bare "anything media-ish" / unknown-UTI
    /// catch-all). Gated by EXTENSION rather than UTType because several of
    /// these (MKV in particular) resolve to an unregistered `dyn.*` UTType
    /// that conforms to neither `.audio` nor `.movie` — a UTType-only gate
    /// would reject them before they ever reach the ffmpeg fallback. The
    /// former hard `.wma` reject (§7 F2) is REMOVED here (§8.8): WMA now
    /// decodes via ffmpeg instead of failing synchronously.
    private static let ffmpegOnlyExtensions: Set<String> = [
        "webm", "mkv", "wma", "avi", "flv", "wmv", "m4b", "asf", "3gp", "ts", "mts", "m2ts",
    ]

    // MARK: - UTType validation (accept audio OR video OR a known ffmpeg-only format; §7, §8)

    private static func validate(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()

        // §8.5: known ffmpeg-only containers/codecs AVFoundation can't read
        // at all — always routed to the bundled ffmpeg fallback (the
        // decode-resolution logic in `run()`), never attempted natively.
        if ffmpegOnlyExtensions.contains(ext) {
            guard FFmpegDecoder.isAvailable else {
                return "Can't read .\(ext.isEmpty ? url.pathExtension : ext) files — the extended decoder isn't available."
            }
            return nil
        }

        let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type = resourceType ?? UTType(filenameExtension: ext) else {
            return Self.unsupportedFormatMessage(ext: ext)
        }

        // Accept audio OR video. `.movie` is the real audio/video discriminator:
        // every video type conforms to it and NO audio type does. (Do NOT gate
        // on `.audiovisualContent` — `.audio` ALSO conforms to it, so the old
        // "reject `.audiovisualContent`" rejected every audio file, and gating
        // an accept on it would be meaningless.) Whether a `.movie` is actually
        // READABLE by AVFoundation (has an audio track; not an unreadable
        // container) is decided by the async probe in `run()` — and, per §8,
        // an unreadable container there now falls back to ffmpeg instead of
        // rejecting outright.
        guard type.conforms(to: .audio) || type.conforms(to: .movie) else {
            return Self.unsupportedFormatMessage(ext: ext)
        }
        return nil
    }

    private static func unsupportedFormatMessage(ext: String) -> String {
        let label = ext.isEmpty ? "that file" : ".\(ext) files"
        return "Can't read \(label) — try mp3, m4a, wav, FLAC…"
    }

    // MARK: - Job lifecycle

    private func start(_ url: URL) {
        let filename = url.lastPathComponent
        generation &+= 1
        let gen = generation
        // Resilient import resume: remember the in-flight job's context so a
        // mid-transcription `cancelInFlight()` can capture it for resume.
        currentJob = (url: url, filename: filename)
        currentDiarizingRecordingID = nil
        // Import-progress ETA (docs/import-progress-eta/design.md §3):
        // optimistic `.preparing` so there's no flash of stale status before
        // `run()`'s first `await` — corrected to `.importing` there once the
        // model-readiness check resolves (immediately, if already loaded).
        // `startElapsedTicker()` moved into `run()` at the `.importing`
        // transition so the elapsed clock (and any rate this job learns)
        // excludes the cold-load wait.
        status = .preparing(filename: filename)
        currentTask = Task { @MainActor [weak self] in
            await self?.run(url: url, filename: filename, generation: gen)
        }
    }

    /// Started at job launch; stopped from the `run()` completion `defer`
    /// (every terminal branch: success/failure/savedPending) and from
    /// `cancelInFlight()`. Only meaningful for the UI while `status` is
    /// `.importing` with a `nil` progress fraction (design §2/§3.2) — but
    /// it's harmless (and simpler) to just always run it for the life of a
    /// job rather than gate start/stop on which model is active.
    private func startElapsedTicker() {
        importStartedAt = .now
        importElapsed = 0
        elapsedTickTask?.cancel()
        elapsedTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, let startedAt = self.importStartedAt else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.importElapsed = elapsed
                // Import-progress ETA (docs/import-progress-eta/design.md
                // §2): only ever counts down — `max(0, ...)` clamps at zero
                // instead of going negative once elapsed overtakes the
                // estimate; HomePane reads a zero/near-zero remaining as
                // "almost done…" rather than a stuck "0:00".
                self.importRemaining = self.estimatedImportSeconds.map { max(0, $0 - elapsed) }
            }
        }
    }

    private func stopElapsedTicker() {
        elapsedTickTask?.cancel()
        elapsedTickTask = nil
        importStartedAt = nil
        importElapsed = nil
        // Import-progress ETA (docs/import-progress-eta/design.md §1/§2):
        // job-scoped state, cleared alongside the elapsed clock so a
        // finished job doesn't leave a stale length/estimate visible on the
        // next idle/terminal caption.
        importAudioDuration = nil
        importRemaining = nil
        estimatedImportSeconds = nil
        currentAudioDuration = nil
    }

    /// Calls `transcriber.transcribeFile`, forwarding a live progress
    /// callback when possible. `transcriberHolder.transcriber` is typed as
    /// `any Transcribing` (the protocol has no `progress:` parameter — it's
    /// concrete-`Transcriber`-only, see `Transcriber.swift`), so this
    /// downcasts to reach the progress-aware overload, mirroring the
    /// existing `as? DualPipelineTranscriber` runtime-downcast idiom already
    /// used elsewhere (`TranscriberHolder.probeActiveModelOnLaunch()`).
    /// When the active engine is `DualPipelineTranscriber` (Nemotron
    /// multilingual), the downcast fails and this falls back to the plain
    /// protocol call — which is exactly correct: Nemotron has no progress
    /// stream (design §1), so the UI is meant to show the indeterminate +
    /// elapsed-time treatment for that path regardless.
    private func transcribeFileWithProgress(
        _ transcriber: any Transcribing,
        url: URL,
        generation gen: Int
    ) async throws -> TranscriptionResult {
        guard let concrete = transcriber as? Transcriber else {
            return try await transcriber.transcribeFile(url, recordsProvenance: false)
        }
        return try await concrete.transcribeFile(url, recordsProvenance: false) { [weak self] fraction in
            Task { @MainActor in
                self?.updateImportProgress(fraction, generation: gen)
            }
        }
    }

    /// Hops onto the main actor (via the closure's `Task { @MainActor in }`
    /// wrapper at the call site) and updates the `.importing` fraction,
    /// throttled to ~10/sec — FluidAudio's stream can emit faster than the
    /// UI needs to redraw. A `gen` mismatch means a newer/cancelled job has
    /// superseded this one; a `status` that's no longer `.importing` means
    /// the job already reached a terminal state — both are silently ignored
    /// rather than resurrecting a stale progress bar.
    private func updateImportProgress(_ fraction: Double, generation gen: Int) {
        guard gen == generation else { return }
        guard case .importing(let filename, _) = status else { return }
        let now = Date()
        guard fraction >= 1.0 || now.timeIntervalSince(lastProgressUpdateAt) >= 0.1 else { return }
        lastProgressUpdateAt = now
        status = .importing(filename: filename, progress: fraction)
    }

    private func processNextQueued() {
        guard currentTask == nil, !queue.isEmpty else { return }
        start(queue.removeFirst())
    }

    // MARK: - Import-progress ETA (docs/import-progress-eta/design.md)

    private static let importRateDefaultsKey = "jot.import.nemotronComputeSecPerAudioSec"

    /// Per-machine measured rate (processing-seconds ÷ audio-seconds) for the
    /// Nemotron one-shot import path, persisted across launches. `nil` until
    /// the first sample is recorded — deliberately NO hardcoded seed (the
    /// design's on-device measurement found the rate varies per machine), so
    /// a fresh machine shows length + elapsed timer only (§2) until it has
    /// learned its own rate.
    private static func learnedImportRate() -> Double? {
        let stored = UserDefaults.standard.double(forKey: importRateDefaultsKey)
        return stored > 0 ? stored : nil
    }

    /// EMA-smoothed update, called once per completed Nemotron import (§2).
    /// `sample` is sanity-checked so a fluke (near-zero audio, a stray Task
    /// hiccup) can't poison the learned rate.
    private static func recordImportRate(_ sample: Double) {
        guard sample.isFinite, sample > 0, sample < 100 else { return }
        if let prior = learnedImportRate() {
            UserDefaults.standard.set(prior * 0.6 + sample * 0.4, forKey: importRateDefaultsKey)
        } else {
            UserDefaults.standard.set(sample, forKey: importRateDefaultsKey)
        }
    }

    /// Best-effort total audio length, probed up front so the caption can
    /// show it regardless of which model ends up handling transcription
    /// (§1). Tries the fast sync `AudioFormat.duration` first; falls back to
    /// `AVURLAsset.load(.duration)` for containers it can't read directly.
    /// Never throws — returns `0` when neither can determine it (e.g. an
    /// ffmpeg-only container `AVURLAsset` also can't open).
    private static func probeAudioDuration(_ url: URL) async -> TimeInterval {
        let quick = AudioFormat.duration(ofFileAt: url)
        if quick > 0 { return quick }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func run(url: URL, filename: String, generation gen: Int) async {
        defer {
            // Only relinquish the slot if THIS job is still current — a late
            // return from a cancelled-mid-inference job must not clobber a
            // newer job's `currentTask` (review B). Same guard covers the
            // elapsed-ticker stop: every exit from this function (success,
            // every failure branch, cancellation) lands here exactly once.
            if gen == generation {
                stopElapsedTicker()
                currentTask = nil
                // Terminal completion of a still-current job — clear the
                // resume-capture context (a cancelled job's late return has
                // gen != generation and must not clear a newer job's, nor
                // the context `cancelInFlight` already consumed).
                currentJob = nil
                currentDiarizingRecordingID = nil
                processNextQueued()
            }
        }
        guard !Task.isCancelled else { return }

        // Import-progress ETA (docs/import-progress-eta/design.md §1): probe
        // the source's total length up front — known before any decode/
        // transcribe work starts, so the caption can show it regardless of
        // which model ends up handling this job.
        let audioDur = await Self.probeAudioDuration(url)
        guard !Task.isCancelled else { return }

        // docs/import-progress-eta/design.md §3: a cold model load (~15s +
        // ANE warmup, measured) must not masquerade as a stalled transcribe.
        // `.preparing` stays up (no elapsed ticker) until the model reports
        // ready; the later `transcribeFile` call's own internal
        // `ensureLoaded()` is then a no-op.
        let transcriberForLoad = transcriberHolder.transcriber
        if !(await transcriberForLoad.isReady) {
            status = .preparing(filename: filename)
            try? await transcriberForLoad.ensureLoaded()
            guard !Task.isCancelled else { return }
        }

        // docs/import-progress-eta/design.md §2: the countdown only ever
        // applies to the indeterminate Nemotron one-shot path, only for
        // files long enough that a countdown is useful, and only once a
        // per-machine rate has been learned — the first import on a machine
        // shows length + elapsed only (no hardcoded seed).
        currentAudioDuration = audioDur
        importAudioDuration = audioDur > 0 ? audioDur : nil
        if audioDur >= 20, !transcriberHolder.primaryModelID.filesReportTranscriptionProgress {
            estimatedImportSeconds = Self.learnedImportRate().map { audioDur * $0 }
        } else {
            estimatedImportSeconds = nil
        }
        status = .importing(filename: filename, progress: nil)
        // Moved here from `start(_:)` so the elapsed clock — and any rate
        // this job goes on to learn — excludes the cold-load pre-phase.
        startElapsedTicker()

        // §8.8 F2: the ffmpeg-fallback temp WAV (if any) is unlinked the
        // instant this function returns, by ANY exit path below — success,
        // every failure branch, and cancellation — via a single `defer`
        // established up front, exactly the fix review bug #2 already
        // applied to the m4a destination further down (the old per-path
        // unlink idiom regressed once; don't repeat that here).
        var tempWAV: URL?
        defer {
            if let tempWAV {
                try? FileManager.default.removeItem(at: tempWAV)
            }
        }

        do {
            let ext = url.pathExtension.lowercased()
            let sourceType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: ext)

            // Decode-resolution (design §8.1): which URL does
            // `transcribeFile`/`transcode` actually read — the original file
            // (AVFoundation native path) or a temp WAV produced by the
            // bundled ffmpeg fallback? Three triggers route to ffmpeg: a
            // known ffmpeg-only extension, an unreadable video container
            // (§7.2 probe, REWRITTEN per review R6 to fall back instead of
            // reject), or — as a last resort below — an opaque `AVAudioFile`
            // decode failure on the native path.
            var decodableURL = url

            if Self.ffmpegOnlyExtensions.contains(ext) {
                // §8.5: AVFoundation cannot read this container/codec at
                // all — skip the native attempt entirely.
                let wav = try await Self.decodeWithFFmpeg(source: url, filename: filename)
                tempWAV = wav
                decodableURL = wav
            } else if sourceType?.conforms(to: .movie) == true {
                // Video source (§7.2 / §8.8 R6): probe the asset BEFORE
                // decode. `AVAudioFile` already reads the audio track out of
                // readable video containers (mp4/mov/m4v), but its failure
                // errors are too opaque to distinguish "unreadable
                // container" from "no audio track" from "DRM" after the
                // fact. Gated on `.movie` so pure-audio imports skip this
                // async round-trip.
                let asset = AVURLAsset(url: url)
                if (try? await asset.load(.hasProtectedContent)) == true {
                    status = .failure(message: "\"\(filename)\" is copy-protected and can't be transcribed.")
                    scheduleClear()
                    return
                }
                guard !Task.isCancelled else { return }

                do {
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                    guard !Task.isCancelled else { return }
                    guard !audioTracks.isEmpty else {
                        status = .failure(message: "\"\(filename)\" has no audio to transcribe.")
                        scheduleClear()
                        return
                    }
                    // Readable, has audio — fall through to the native path.
                } catch {
                    // AVFoundation can't read this container at all (e.g.
                    // WebM mislabeled/probed as `.movie`, which throws
                    // AVErrorFileFormatNotRecognized here). Per §8.8 R6 this
                    // now ROUTES TO ffmpeg instead of rejecting outright —
                    // this branch REPLACES the old synchronous reject.
                    log.info("AVFoundation can't read \"\(filename, privacy: .public)\" — falling back to bundled ffmpeg")
                    let wav = try await Self.decodeWithFFmpeg(source: url, filename: filename)
                    tempWAV = wav
                    decodableURL = wav
                }
            }

            guard !Task.isCancelled else { return }

            // Design §4.1 step 2 — `recordsProvenance: false` (review C3): a
            // file import has no correction-review UX, and `true` without the
            // paired `CorrectionProvenance.commit(transcriptID:)` (which
            // `RecordingPersister` does right after its save) would leave
            // pending vocab proposals dangling and mis-commit them against
            // the next dictation. Mirrors the list-row re-transcribe
            // (`RecordingsListView.retranscribe`).
            let transcriber = transcriberHolder.transcriber
            let result: TranscriptionResult
            do {
                result = try await transcribeFileWithProgress(transcriber, url: decodableURL, generation: gen)
            } catch let transcriberError as TranscriberError {
                // "Never lose audio" safety net
                // (docs/resilient-transcription/design.md): the source
                // decoded fine (native or ffmpeg) — only the transcription
                // ATTEMPT failed. `.busy` / model-not-ready are transient
                // and worth keeping the audio for; `.audioTooShort` /
                // `.fluidAudio` genuine ASR failures are not (a sub-1s clip
                // or a real inference error would just fail identically on
                // re-transcribe) — those still fall through to the existing
                // "no row" behavior via the rethrow below.
                if Self.isSalvageable(transcriberError) {
                    await persistPendingImport(decodableURL: decodableURL, filename: filename)
                    return
                }
                throw transcriberError
            } catch {
                guard tempWAV == nil else { throw error } // ffmpeg already tried once for this job
                guard !Task.isCancelled else { return }
                // Last-resort §8.1 trigger: the native path was attempted
                // (not a known ffmpeg-only extension, and either not a video
                // or the video probe reported it readable) but
                // `AVAudioFile(forReading:)` still threw an opaque error —
                // e.g. AC-3/DTS-in-mp4 (§7 R2, previously out of scope; now
                // closed by the ffmpeg fallback). Retry once via ffmpeg
                // before giving up.
                log.info("Native decode of \"\(filename, privacy: .public)\" failed — retrying via bundled ffmpeg")
                let wav = try await Self.decodeWithFFmpeg(source: url, filename: filename)
                tempWAV = wav
                decodableURL = wav
                guard !Task.isCancelled else { return }
                do {
                    result = try await transcribeFileWithProgress(transcriber, url: decodableURL, generation: gen)
                } catch let transcriberError as TranscriberError {
                    if Self.isSalvageable(transcriberError) {
                        await persistPendingImport(decodableURL: decodableURL, filename: filename)
                        return
                    }
                    throw transcriberError
                }
            }

            guard !Task.isCancelled else { return }

            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                status = .failure(message: "Couldn't make out any speech in \"\(filename)\".")
                scheduleClear()
                return
            }

            // Import-progress ETA (docs/import-progress-eta/design.md §2):
            // record this job's measured rate for future countdowns — gated
            // exactly like the estimate itself (long enough file, Nemotron
            // one-shot path only) so a run under different conditions can't
            // pollute the learned rate.
            if audioDur >= 20, !transcriberHolder.primaryModelID.filesReportTranscriptionProgress,
               let importStartedAt {
                Self.recordImportRate(Date().timeIntervalSince(importStartedAt) / audioDur)
            }

            // Design §4.1 step 3 — transcode (review C4), not copy-as-is: the
            // detail view plays back via `AVAudioPlayer`, whose container
            // support is narrower than `AVAudioFile`'s decode path — an
            // ogg/AMR copy would transcribe fine but be an unplayable Recents
            // row. Transcodes `decodableURL` (the temp WAV when ffmpeg ran,
            // the original file otherwise) — this re-decodes the source a
            // second time (the buffer `transcribeFile` used isn't handed
            // back) — an accepted tradeoff per the design's own note, in
            // exchange for not duplicating `Transcriber`'s private converter
            // internals here.
            let audioFileName = "\(UUID().uuidString).\(AudioFormat.storageFileExtension)"
            let destination = RecordingStore.audioDirectory.appendingPathComponent(audioFileName)
            let transcodeSource = decodableURL
            do {
                try await Task.detached(priority: .utility) {
                    try Self.transcode(source: transcodeSource, to: destination)
                }.value
            } catch {
                log.error("Transcode-to-library failed: \(String(describing: error))")
                // `AVAudioFile(forWriting:)` creates the file on disk before
                // the write; a mid-write failure leaves a partial orphan with
                // no Recording row. Clean it (review bug #2 — the cleanup
                // guarantee previously only covered the cancel/save paths).
                try? FileManager.default.removeItem(at: destination)
                status = .failure(message: "Couldn't save the audio for \"\(filename)\".")
                scheduleClear()
                return
            }

            guard !Task.isCancelled else {
                // A cancelled job must not leave an orphaned m4a with no
                // Recording row behind.
                try? FileManager.default.removeItem(at: destination)
                return
            }

            let recording = Recording(
                createdAt: .now,
                title: Recording.defaultTitle(from: result.text),
                durationSeconds: result.duration,
                transcript: result.text,
                rawTranscript: result.rawText,
                audioFileName: audioFileName,
                modelIdentifier: transcriberHolder.primaryModelID.rawValue
            )
            context.insert(recording)
            do {
                try context.save()
            } catch {
                log.error("Failed to save imported Recording: \(String(describing: error))")
                try? FileManager.default.removeItem(at: destination)
                Task { await ErrorLog.shared.error(component: "FileTranscriptionIngest", message: "SwiftData save failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
                status = .failure(message: "Transcribed \"\(filename)\" but couldn't save it to Recents.")
                scheduleClear()
                return
            }

            // AI-search Stage B, same hook `RecordingPersister` fires.
            RecordingIndexer.shared?.index(recordingID: recording.id, text: result.text)

            // Auto-diarize (docs/auto-diarize-imports/design.md): reuse the
            // exact "Detect speakers" pipeline (`DiarizationRunner`), gated
            // by the Advanced toggle. Runs AFTER the `Recording` is already
            // saved with its transcript — so any failure here (model
            // download, decode, process) is caught and logged but never
            // fails the import; the transcript is already safe. Skipped
            // entirely if a live dictation cancels this job mid-diarize.
            //
            // `recorderIsIdle()` gate: diarization holds `CoreMLInferenceGate`
            // (serialized against the mic's stop-time transcription by design
            // D6). If the user is already dictating when the import lands, we
            // DEFER auto-diarize rather than make their paste wait behind the
            // gate — resilient-import-resume upgrades the former SKIP (which
            // silently lost the labels) to a `pendingResume` that the
            // recorder-idle hook picks up. This narrows but doesn't fully
            // close the window (a dictation that STARTS mid-diarize is
            // handled by `cancelInFlight`'s `.diarizing` capture instead).
            if Features.speakerLabels && autoDiarizeImports, !Task.isCancelled {
                if recorderIsIdle() {
                    status = .diarizing(filename: filename)
                    // Resume capture context: lets a mid-diarize
                    // `cancelInFlight()` record which recording to re-diarize.
                    // Cleared by `run()`'s gen-guarded defer (or consumed by
                    // `cancelInFlight` itself).
                    currentDiarizingRecordingID = recording.persistentModelID
                    do {
                        let outcome = try await DiarizationRunner.run(
                            holder: diarizerHolder,
                            audioURL: RecordingStore.audioURL(for: recording),
                            transcript: recording.transcript,
                            sliceTranscribe: SegmentSlicing.sliceTranscriber(using: transcriberHolder.transcriber)
                        )
                        if !Task.isCancelled, let payload = outcome.payload, let data = try? JSONEncoder().encode(payload) {
                            recording.speakerTimeline = data
                            applySlicedTranscriptIfAvailable(outcome, to: recording)
                            try? context.save()
                        }
                    } catch is CancellationError {
                        // Live dictation preempted mid-diarize — no error, no
                        // save; `cancelInFlight` already captured the resume.
                    } catch TranscriberError.busy {
                        // The sliced pass needs the transcription engine and
                        // someone else grabbed it mid-pass. Park the diarize
                        // job for the idle hook — same contract as the
                        // recorder-busy defer branch below; the import still
                        // completes as `.success` (transcript already saved).
                        pendingResume = .diarize(recordingID: recording.persistentModelID, filename: filename)
                    } catch {
                        log.error("Auto-diarize failed for \"\(filename, privacy: .public)\": \(String(describing: error))")
                    }
                } else {
                    // Recorder busy → DEFER (resilient-import-resume): the
                    // transcript is already saved, so only the diarize pass
                    // is outstanding — queue it for the idle hook instead of
                    // losing the labels. The import still completes as
                    // `.success` below; the deferred pass runs silently later.
                    pendingResume = .diarize(recordingID: recording.persistentModelID, filename: filename)
                }
            }

            guard !Task.isCancelled else { return }
            status = .success(filename: filename)
            scheduleClear()
        } catch {
            guard !Task.isCancelled else { return }
            status = .failure(message: Self.errorMessage(for: error, filename: filename))
            scheduleClear()
        }
    }

    /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
    /// `.busy` / model-not-ready are transient conditions where the decoded
    /// source audio is perfectly fine — worth transcoding into the library
    /// and re-transcribing later. `.audioTooShort` / `.fluidAudio` are
    /// genuine content/inference failures that would reproduce identically
    /// on a later re-transcribe attempt, so those keep today's "no row"
    /// behavior.
    private static func isSalvageable(_ error: TranscriberError) -> Bool {
        switch error {
        case .busy, .modelMissing, .modelNotLoaded:
            return true
        case .audioTooShort, .fluidAudio:
            return false
        }
    }

    /// "Never lose audio" safety net (docs/resilient-transcription/design.md).
    /// The source decoded successfully but `transcriber.transcribeFile`
    /// threw a salvageable error (see `isSalvageable`) — transcode the
    /// already-decoded source into the library (the SAME step the success
    /// path performs below) and insert a PENDING row (empty transcript,
    /// `pendingSince = .now`) instead of just showing an error and
    /// discarding the import. The row is re-transcribable from Recents like
    /// any other pending row. Mirrors the success path's own cleanup
    /// guarantees — a transcode or save failure here still unlinks the m4a,
    /// so this never leaves an orphan either.
    private func persistPendingImport(decodableURL: URL, filename: String) async {
        let audioFileName = "\(UUID().uuidString).\(AudioFormat.storageFileExtension)"
        let destination = RecordingStore.audioDirectory.appendingPathComponent(audioFileName)
        do {
            try await Task.detached(priority: .utility) {
                try Self.transcode(source: decodableURL, to: destination)
            }.value
        } catch {
            log.error("Transcode-to-library failed while persisting pending import: \(String(describing: error))")
            try? FileManager.default.removeItem(at: destination)
            status = .failure(message: "Couldn't save the audio for \"\(filename)\".")
            scheduleClear()
            return
        }

        guard !Task.isCancelled else {
            // A cancelled job must not leave an orphaned m4a with no
            // Recording row behind — same guarantee as the success path.
            try? FileManager.default.removeItem(at: destination)
            return
        }

        let recording = Recording(
            createdAt: .now,
            title: Recording.defaultTitle(from: ""),
            durationSeconds: AudioFormat.duration(ofFileAt: destination),
            transcript: "",
            rawTranscript: "",
            audioFileName: audioFileName,
            modelIdentifier: transcriberHolder.primaryModelID.rawValue,
            pendingSince: .now
        )
        context.insert(recording)
        do {
            try context.save()
        } catch {
            log.error("Failed to save pending imported Recording: \(String(describing: error))")
            try? FileManager.default.removeItem(at: destination)
            Task { await ErrorLog.shared.error(component: "FileTranscriptionIngest", message: "Pending SwiftData save failed", context: ["error": ErrorLog.redactedAppleError(error)]) }
            status = .failure(message: "Couldn't save the audio for \"\(filename)\".")
            scheduleClear()
            return
        }

        // Deliberately no `RecordingIndexer.index` / `CorrectionProvenance.commit`
        // here — the transcript is empty, nothing to index or commit until the
        // user re-transcribes, which already does both (mirrors
        // `RecordingPersister.persistPending`).
        status = .savedPending(filename: filename)
        scheduleClear()
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            switch self.status {
            case .success, .failure, .savedPending: self.status = .idle
            // `.pausedForDictation` is non-terminal (like `.importing`) —
            // the caption stays up until the idle-hook resume replaces it.
            // `.preparing` is likewise non-terminal (docs/import-progress-eta/
            // design.md §3).
            case .idle, .importing, .diarizing, .pausedForDictation, .preparing: break
            }
        }
    }

    private static func errorMessage(for error: Error, filename: String) -> String {
        switch error {
        case TranscriberError.audioTooShort:
            return "\"\(filename)\" is too short to transcribe (needs at least 1 second of audio)."
        case TranscriberError.busy:
            return "Jot is busy — try dropping \"\(filename)\" again in a moment."
        case TranscriberError.modelMissing, TranscriberError.modelNotLoaded:
            return "The transcription model isn't ready yet — try again once it finishes loading."
        // §8.8 R7 — dedicated ffmpeg-fallback messages, not the generic
        // "corrupted or unsupported" default below.
        case IngestError.ffmpegUnavailable:
            return "Can't read \"\(filename)\" — the extended decoder isn't available."
        case IngestError.ffmpegNoAudio:
            return "\"\(filename)\" has no audio to transcribe."
        case IngestError.ffmpegDecodeFailed:
            return "Couldn't read \"\(filename)\"'s audio — it may use an unsupported codec or be copy-protected."
        case IngestError.ffmpegTimedOut:
            return "Transcribing \"\(filename)\" took too long and was cancelled — try a shorter file."
        default:
            return "Couldn't read \"\(filename)\" — the file may be corrupted or in an unsupported format."
        }
    }

    // MARK: - FFmpeg fallback (design §8)

    /// Runs the bundled ffmpeg helper and maps its errors onto the dedicated
    /// `IngestError` cases above (§8.8 R7) instead of letting the generic
    /// "corrupted or unsupported" default speak for a case we can actually
    /// name. `stderrTail`'s content (bounded — see `FFmpegDecoder`'s
    /// `TailAccumulator`) is inspected for ffmpeg's own "no audio stream"
    /// phrasing so a truly audio-less file surfaces the SAME message as the
    /// §7.2 video no-audio guard (§8.8 R6 — this reconciles detection
    /// between the two paths rather than merely prepending to it).
    private static func decodeWithFFmpeg(source: URL, filename: String) async throws -> URL {
        do {
            return try await FFmpegDecoder.decodeToTempWAV(source: source)
        } catch FFmpegDecoder.DecodeError.helperUnavailable, FFmpegDecoder.DecodeError.launchFailed {
            throw IngestError.ffmpegUnavailable
        } catch FFmpegDecoder.DecodeError.timedOut {
            throw IngestError.ffmpegTimedOut
        } catch FFmpegDecoder.DecodeError.decodeFailed(_, let stderrTail) {
            let lowered = stderrTail.lowercased()
            if lowered.contains("does not contain any stream")
                || lowered.contains("no audio")
                || lowered.contains("stream map '0:a") {
                throw IngestError.ffmpegNoAudio
            }
            throw IngestError.ffmpegDecodeFailed
        }
    }

    // MARK: - Transcode (source → 16 kHz mono AAC m4a in the library)

    /// Decode `source` (whatever format `AVAudioFile` can open — the same set
    /// `Transcriber.transcribeFile` already decodes) and re-encode it into
    /// `destination` as 16 kHz mono AAC, matching `AudioFormat.storageSettings`
    /// exactly. Mirrors `Transcriber.readMono16kFloat`'s convert step and
    /// `AudioCapture`'s `AVAudioFile(forWriting:settings:...)` write step —
    /// the two existing patterns this combines. Runs off the main actor
    /// (`nonisolated`, dispatched via `Task.detached` by the caller) so a
    /// long file doesn't hitch the UI.
    private nonisolated static func transcode(source: URL, to destination: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let processingFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw IngestError.emptySourceAudio }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            throw IngestError.transcodeFailed
        }
        try file.read(into: inBuffer)

        let mono16k: AVAudioPCMBuffer
        if processingFormat.sampleRate == AudioFormat.sampleRate,
           processingFormat.channelCount == AudioFormat.channelCount,
           processingFormat.commonFormat == .pcmFormatFloat32,
           !processingFormat.isInterleaved {
            mono16k = inBuffer
        } else {
            guard let converter = AVAudioConverter(from: processingFormat, to: AudioFormat.target) else {
                throw IngestError.transcodeFailed
            }
            let ratio = AudioFormat.sampleRate / processingFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: AudioFormat.target, frameCapacity: outCapacity) else {
                throw IngestError.transcodeFailed
            }

            var supplied = false
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return inBuffer
            }
            guard status != .error else {
                if let convertError { throw IngestError.transcode(convertError) }
                throw IngestError.transcodeFailed
            }
            mono16k = outBuffer
        }

        // Ensure the library's Recordings/ directory exists — unlike the mic
        // path (`AudioCapture.start` creates it), nothing on the file path
        // does, so a brand-new user whose FIRST action is a file drop would
        // otherwise hit a missing-parent-dir write failure and silently lose
        // the transcription (review bug #1).
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outFile = try AVAudioFile(
            forWriting: destination,
            settings: AudioFormat.storageSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try outFile.write(from: mono16k)
    }
}
