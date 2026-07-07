# Transcribe an audio file (drop or pick on the Home dictate zone)

**Status:** design — **reviewed** (independent adversarial pass integrated below). Not implemented.
**Scope:** audio (shipped) **+ video (§7, extension — awaiting review)**. Let a user drop an audio *or video* file on Home's dictate area, or pick one, and get a transcript (and optional speaker labels) that lands in Recents like a dictation.

> **Review-mandated changes (all folded in below):** (C1) a live dictation must never be lost to a running file job — gate at record START, not stop; (C2) drop the §4.4 disk-backed path for v1; (C3) `recordsProvenance: false`; (C4) transcode the stored audio to m4a (copy-as-is is unplayable for ogg/AMR). Open questions resolved: **transcode** (not copy), **queue** dropped files, UX Opt-1 vs Opt-2 remains a pure design call.

---

## 1. Goal

On the Home landing pane, next to the existing **Dictate** pill, add a way to transcribe an existing audio file:
- **Drag-and-drop** a file onto the dictate zone, OR
- **Click to pick** a file (fallback for non-drag users).

The file is decoded → 16 kHz mono → run through the *same* transcriber as live dictation → saved as a normal `Recording` (shows in Recents, playable, re-transcribable, diarizable). No paste-at-cursor (there's no dictation cursor context for a file import).

---

## 2. Feasibility (settled by investigation)

- **Formats — no FFmpeg needed.** Empirically (15 real files through Jot's exact `AVAudioFile` decode path on Apple Silicon), AVFoundation natively decodes **mp3, m4a/AAC, ALAC, wav, aiff, caf, FLAC, ogg-Vorbis, ogg-Opus, AAC-ADTS, AMR, mp4**. Only **WMA** and **WebM** fail (container-level `'typ?'`). So v1 ships zero extra binaries; WMA/WebM get a clear "unsupported format" message. (A decode-only FFmpeg for the long tail would be 3–8 MB — under the 30 MB bar — but not worth it for audio; revisit for the video story.)
- **Ingest seam already exists:** `Transcribing.transcribeFile(_ url:recordsProvenance:)` (`Sources/Transcription/Transcriber.swift:548`) opens any `AVAudioFile`, resamples to 16 kHz mono Float32 (`readMono16kFloat` `:562`), and runs the identical `transcribe(samples:)` path used by the mic. It already backs Library "Re-transcribe."
- **Long files:** FluidAudio's `AsrManager` auto-slides ~14.96 s windows with 2 s overlap over arbitrarily long input — **no Jot-side chunking**. One caveat: `transcribeFile` materializes the whole decoded buffer as `[Float]` (~230 MB for 1 h). FluidAudio also exposes a **disk-backed, constant-memory** `transcribe(url:)`; we add a URL path on the `Transcriber` actor for large files (see §4.4).
- **Not sandboxed** (`Resources/Jot.entitlements`), so a dropped/picked file is readable by direct path — no security-scoped bookmarks.
- **Transcriber constraints to respect:** single in-flight (`.busy` if a transcription is already running, `Transcriber.swift:149`) and a `< 1 s` `.audioTooShort` reject (`:150`).

---

## 3. UX design

House style (from `Sources/Home/HomePane.swift`): restrained, semantic system colors, `Capsule()` + `RoundedRectangle(cornerRadius:16, style:.continuous)`, `.regularMaterial`, point-sized system fonts, tight spacing, one branded red (`#E0483D`) reserved for the recording state. The `RecordPill` (`HomePane.swift:99`) is a 34 pt-tall capsule: `mic.fill` + "Dictate". There is **no existing drag-drop anywhere**, so this is net-new and must match that idiom.

### 3.1 Resting state
Under the `RecordPill`, add a subtle secondary affordance — NOT a second loud button. Two options for review:

- **Opt-1 (recommended): a quiet "or drop an audio file" line + whole-zone drop target.** The existing dictate `VStack` (`HomePane.swift:36-78`) becomes a `.dropDestination(for: URL.self)`. Below the caption, a tertiary line: `↧ Drop an audio file, or browse` where "browse" is a `.link`-styled button opening an `NSOpenPanel`/`.fileImporter` scoped to audio UTTypes. Minimal visual weight; discoverable without competing with Dictate.
- **Opt-2: a sibling capsule** ("Transcribe a file", `waveform`/`arrow.down.doc`) next to Dictate. More discoverable, but doubles the primary affordance and crowds the hero.

### 3.2 Drag-over state
On `.dropDestination(isTargeted:)` true: the dictate zone gets a **dashed rounded border** (`RoundedRectangle(16, .continuous).strokeBorder(style: StrokeStyle(dash:))`, `Color.accentColor.opacity(0.6)`) and a faint `Color.accentColor.opacity(0.06)` fill — the standard macOS "drop here" cue, in semantic colors. Caption swaps to "Release to transcribe."

### 3.3 In-progress state
A file transcription is a discrete job (unlike the live pill). Show progress inline where the drop line was: a small determinate/indeterminate bar + "Transcribing <filename>… ". Because the transcriber is single-in-flight, while a file job runs the **Dictate pill is disabled** with a tooltip ("Finishing a file transcription…"). Long files can take a while — surface elapsed/percent if FluidAudio's progress callback is available; otherwise indeterminate.

### 3.4 Terminal states
- **Success:** the new `Recording` appears at the top of Recents (the list is right below); a brief inline "Transcribed <filename>" confirmation, then clear. Selecting it opens the normal detail view (play, transcript, re-transcribe, Detect speakers).
- **Unsupported format (WMA/WebM/non-audio):** inline error "Can't read <ext> files — try mp3, m4a, wav, FLAC…". No crash, no row.
- **Too short (<1 s) / decode failure / empty transcript:** inline explanatory error, no row.

### 3.5 Multi-file / edge
- v1: accept **one file at a time**. If several are dropped, queue them (transcribe sequentially, single-in-flight) or take the first + note "one at a time" — decide in review (queue preferred if cheap).
- Reject obvious non-audio by UTType before decoding; still guard the decode with a try/catch for mislabeled files.

*(A visual mockup will accompany review; the design language is fully specified above so it can be built native-first.)*

---

## 4. Technical design

### 4.1 New: `FileTranscriptionIngest` (App or Library layer)
A small **`@MainActor`** service (not routed through `VoiceInputPipeline`/`RecorderController`, which are mic-coupled). MUST run on the main actor and use the same UI `ModelContext` the app injects (the SwiftData context is main-actor-bound — `RecordingPersister` is `@MainActor`; saving that context is what makes `RecordingsListView`'s `@Query` auto-refresh). Responsibilities:
1. Validate the UTType is audio AND **reject video** — `UTType.movie`/`audiovisualContent` conformers, and treat `mp4`/`mov` as video (they decode via `AVAudioFile` but are out of scope). Reject early with a typed error.
2. `let result = try await transcriber.transcribeFile(url, recordsProvenance: false)` — **`false`** (review C3): a file import has no correction-review UX, and `true` without the paired `CorrectionProvenance.commit(transcriptID:)` (which `RecordingPersister` does at `:87-88`) would leave pending vocab proposals dangling and mis-commit them against the next dictation. Use `false`, exactly like the list-row re-transcribe (`RecordingsListView.swift:656`). `result.duration` gives `durationSeconds` (no `AVURLAsset` needed).
3. **Transcode** the source audio to AAC m4a (`AudioFormat.storageSettings`) into `~/Library/Application Support/Jot/Recordings/` (dir at `JotComposition.swift:260`, `RecordingStore.audioDirectory` `:34`), fresh UUID filename. **NOT copy-as-is** (review C4): the detail view plays via `AVAudioPlayer(contentsOf:)` (`RecordingDetailView.swift:626`), whose container support is narrower than `AVAudioFile`'s — an ogg/AMR copy would transcribe fine but be an unplayable Recents row. Note: `transcribeFile` doesn't hand back the decoded buffer, so a naive transcode is a *second* full decode; prefer decoding once and both transcribing + writing the m4a from the same buffer.
4. Insert a `Recording` (`Sources/Library/Recording.swift:44`): `createdAt`, `title = Recording.defaultTitle(from: transcript)`, `durationSeconds` (= `result.duration`), `transcript`, `rawTranscript`, `audioFileName`, `modelIdentifier`. `context.insert` + `context.save()` on the main UI context — mirroring `RecordingPersister.persist` (`:52-68`).
5. Fire the same side-effects mic recordings get, if cheap: `RecordingIndexer.shared?.index(...)` (search). Diarization stays manual (the user clicks Detect speakers later), so no auto-diarize here.

Rationale for a dedicated service over reusing the `RecorderController.$lastResult` publisher: the file flow shares nothing with the mic (no paste, no disconnect salvage, no streaming preview), so coupling it to the mic controller's state just to reuse the persister sink is the wrong seam. Explicit insert is clearer and testable.

### 4.2 Home wiring
`HomePane.swift` `topContent` gains the drop target + pick affordance (§3), calling into a `HomeViewModel`/state object that owns the ingest job + progress + error, and disables the `RecordPill` while `isImporting`.

### 4.3 Reuse, don't duplicate, the decode
`transcribeFile` + `readMono16kFloat` already do AVFoundation → 16 kHz mono. Do NOT add a second decoder. The same converter shape is validated in `tools/diarize-probe`'s `loadMono16k`.

### 4.4 Large-file memory path — DEFERRED to a follow-up (review C2)
Originally proposed adding `Transcriber.transcribeFileDiskBacked(url:)` delegating to FluidAudio's `AsrManager.transcribe(url:)`. **Dropped for v1** because a thin delegate bypasses everything the in-memory path does (`Transcriber.transcribeWithAsrManager` :201-332): the `isTranscribing` busy guard (would silently defeat single-in-flight — makes the C1 collision worse), paragraph segmentation, vocabulary rescore, and the v2 cleanup chain — and it doesn't even exist for `nemotron_en` (a `NemotronStreamingTranscriber`, no `transcribe(url:)`) or the multilingual models (`DualPipelineTranscriber`). v1 uses the in-memory `transcribeFile`; the ~230 MB/hour is transient and one-at-a-time. A proper disk-backed path (routed through the same post-processing + busy guard + all model kinds) is a future optimization, not a v1 requirement.

---

## 5. Blast radius

| Area | Change | Risk |
|---|---|---|
| `Sources/Home/HomePane.swift` (+ small state object) | drop target, pick button, progress/error UI, disable-pill-while-importing | medium — new UI, must match idiom |
| New `FileTranscriptionIngest` service | decode(reuse) → transcribe → transcode-into-Recordings → insert `Recording` | medium — persistence + file I/O |
| `Sources/Transcription/Transcriber.swift` | + `transcribeFileDiskBacked(url:)` for large files | low — additive, delegates to SDK |
| `docs/features.md` | new bullet | none |

No new permission (not sandboxed), no migration (additive `Recording` rows), no new SwiftData model, no new pipeline/pill state (file job has its own inline UI), no hotkey.

---

## 6. Risks & open questions

**R1 — Single-in-flight collision with live dictation (CRITICAL — review C1, data loss).** The transcriber is one-at-a-time. Disabling the pill is NOT sufficient: the **global dictation hotkey** doesn't go through the pill and doesn't check `busy` at record *start* — so a user can record a full utterance during a running file job, then at stop `transcribe` throws `.busy` (`Transcriber.swift:149`) → `PipelineError.transcribeBusy` → `state = .error(...)`, `$lastResult` never fires, and **the spoken recording is thrown away entirely** (no row, no salvage). The file job is long, so this window is its whole duration. REQUIRED fix (choose in impl, but a live dictation must NEVER be lost):
  - **(a) Preempt (preferred):** make the `FileTranscriptionIngest` job cancellable; if the dictation hotkey fires while a file job runs, cancel the file job and let the mic proceed (live speech beats a re-runnable file). The cancelled file can be retried.
  - **(b) Refuse-at-start:** check the busy/importing flag at record START (before capturing audio) and show a toast ("Finishing a file transcription…") instead of recording-then-losing. No data loss, but blocks live dictation briefly.
  Do NOT rely on the pill's `.disabled` alone. File-vs-file collisions are handled by queuing (§3.5).

**R2 — Transcode vs copy the source into the library.** Transcoding to AAC m4a keeps Recents uniform + playable and small, but re-encodes (quality/time); copying as-is is simpler but leaves arbitrary formats in the library (playback via `AVAudioPlayer` — does it handle all of them? FLAC/ogg playback in the detail view needs checking). Lean transcode-to-m4a; confirm in review.

**R3 — Progress granularity.** Does FluidAudio's batch `transcribe([Float])` expose a progress callback for the determinate bar, or only the diarizer's `process(progressCallback:)`? If ASR has none, the bar is indeterminate for the whole job. Verify.

**R4 — Very long / huge files.** Even with the disk-backed path, a 3-hour podcast is a multi-minute job on-device. Decide a soft cap or just let it run with progress + cancel. No hard limit needed technically.

**R5 — Duration for the `Recording` row.** `durationSeconds` should come from the file (`AVURLAsset.duration` / `AVAudioFile.length / sampleRate`), not the resampled buffer, to display correctly.

**Open for review:**
1. UX Opt-1 (quiet drop line, recommended) vs Opt-2 (sibling capsule)?
2. Transcode-to-m4a vs copy-as-is for the stored audio (R2)?
3. Queue multiple dropped files vs one-at-a-time-first (§3.5)?

---

## 7. Video support (extension) — reviewed + implemented

**Status:** implemented. Independent review caught a critical error in the first draft (below) — the gate predicate — which was fixed before/at implementation.

> **Review outcome (integrated):**
> - **F3 (critical, also a pre-existing AUDIO bug):** `public.audio` conforms to `public.audiovisual-content`, so the *shipped audio* `validate()` (`if .movie || .audiovisualContent → reject`) was rejecting EVERY audio file as "Video files aren't supported." Live UTType test confirmed (mp3/m4a/wav/… all `audiovisualContent=true`). Fixed: accept `type.conforms(to: .audio) || type.conforms(to: .movie)`. `.movie` is the true audio/video discriminator (every video conforms, no audio does; MKV `dyn.*` conforms to neither → rejected).
> - **F1:** the async probe is gated on `.movie` (NOT `.audiovisualContent`), so audio imports skip it and ogg/Opus/AMR are not false-rejected.
> - **R1 (DRM):** the probe checks `asset.load(.hasProtectedContent)` → clear "copy-protected" message for FairPlay video.
> - **R3 (cancellation):** a `guard !Task.isCancelled` follows the probe await so a job cancelled during `loadTracks` never grabs the transcriber slot.
> - **F2 (WMA):** explicit `.wma` reject with a clear message (it conforms to `.audio`, would otherwise hit a generic decode error).
> - **R2 (AC-3/DTS-in-mp4):** NOT handled for v1 (uncommon for user drops; AAC/ALAC — phone video, screen recordings — is the norm). An `AVAssetReader` fallback would close it; deferred. A passing-probe-then-decode-fail surfaces the generic error.

**Goal:** drop or pick a **video** (`.mp4/.mov/.m4v`) and transcribe + diarize it, on-device, **no FFmpeg**. A video is just an audio track in a video wrapper; everything downstream (transcribe → the stored m4a → "Detect speakers") is unchanged.

### 7.1 Approach — widen the gate, no new extraction pipeline (empirically settled)
An investigation probed real media (H.264+AAC in `.mp4/.mov/.m4v`, plus no-audio / silent / short / WebM / MKV) on this macOS:
- **`AVAudioFile(forReading:)` already reads the audio track from every AVFoundation-native video container** (mp4/mov/m4v), producing 16 kHz mono output identical to `AVAssetReader`. So `Transcriber.transcribeFile` (`:559`, via `AVAudioFile` at `:565`) and `FileTranscriptionIngest.transcode()` (`:329`) **work on video unchanged** and produce a playable library m4a (verified via `AVAudioPlayer`).
- Therefore we do **not** add an `AVAssetReader` branch — it would duplicate the existing converter for zero behavioral gain on readable containers.

**Tradeoff (for review):** this relies on `AVAudioFile` decoding video containers — undocumented but empirically reliable across the three native containers. The robustness guarantee comes not from `AVAudioFile` but from the readability probe in §7.2, which is the authoritative "can we read this?" gate *before* decode. If review prefers belt-and-suspenders, an `AVAssetReader` fallback on `AVAudioFile` throw is a cheap addition — but not required.

### 7.2 The one genuinely new piece: an audio-track readability probe
`AVAudioFile`'s failure errors are opaque (`dta?` for no-audio, `typ?` for unreadable container) — unusable for user-facing distinctions. So before decode, in `FileTranscriptionIngest.run(...)` (right before the `transcribeFile` call ~:213), probe the asset — but ONLY for video sources (skip for pure audio to avoid the async round-trip):

```
if type.conforms(to: .audiovisualContent) {              // it's a video
    let asset = AVURLAsset(url: url)
    let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
    // loadTracks THREW (nil→[]) ⇒ unreadable container (WebM/MKV): reject
    //   "Can't read this video format — try MP4, MOV, or M4V."
    // audioTracks EMPTY ⇒ video has no audio: reject "That video has no audio to transcribe."
    // non-empty ⇒ readable video with audio ⇒ fall through to the existing path
}
```
Verified: no-audio mp4 → `loadTracks` returns `[]` (clean, no crash); WebM/MKV → `loadTracks` throws `-11828` (`AVErrorFileFormatNotRecognized`). This probe is the exact seam separating readable-with-audio from unreadable/audio-less.

### 7.3 UTType gate change (`validate(_:)` ~:151-168)
Remove the blanket video reject. New accept set: `type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)` (`.movie` conforms to `.audiovisualContent`, so one check covers both). Still rejected synchronously here: WMA, and MKV (its `dyn.*` UTType conforms to neither). WebM (conforms to `.audiovisualContent`) passes this sync gate but is caught by the §7.2 async probe.

### 7.4 Edge cases (all handled by existing guards + the probe)
- **No audio track** → §7.2 probe rejects gracefully.
- **WebM / MKV** → rejected (MKV at the sync gate, WebM at the async probe). These are the only formats that would ever need FFmpeg — out of scope.
- **Silent video** → decodes, empty transcript → existing empty-transcript guard (`:218`).
- **Very short (<1 s)** → existing `.audioTooShort` guard (`:308-309`).

### 7.5 What does NOT change
`Transcriber` (no new method), `transcode()` (works on video as-is), the transcode→m4a→`Recording` insert, the collision handling, and **diarization** (runs post-hoc on the stored m4a via "Detect speakers", identical to a mic recording). Net new code ≈ the §7.2 probe + the §7.3 gate change + copy/UX wording ("or a video").

### 7.6 Blast radius
Tiny: `FileTranscriptionIngest.validate` (gate) + `run` (probe branch), plus HomePane/features.md copy ("audio or video"). No new pipeline, no new permission, no `Transcriber` change, no diarization change.

**Open for review (video):**
1. Widen-gate (rely on `AVAudioFile` for video decode) vs. an explicit `AVAssetReader` fallback on `AVAudioFile` throw — is the empirical reliability enough, or add the fallback?
2. Should the drop zone advertise "audio or video" up front, or keep it "audio file" and just accept video silently?

---

## 8. Bundled FFmpeg fallback — support the long tail (WebM/MKV/WMA/AVI/…) — awaiting review

**Status:** designed; investigation verified feasibility end-to-end (built the binary, decoded real files, signed it). Extends §1–§7.

**Goal:** transcribe + diarize *any* audio or video with a decodable audio track, still 100% on-device, no network. AVFoundation handles the native set (§2, §7); a bundled **decode-only FFmpeg** handles everything AVFoundation can't read (WebM, MKV, WMA, AVI, FLV, ogg-in-exotic-containers, AC-3/DTS-in-mp4, …).

### 8.1 Architecture — AVFoundation-first, FFmpeg-fallback
A new `DecodedSource` resolution step decides how to get an AVFoundation-readable file:
- **Native path (unchanged):** audio + mp4/mov/m4v → used directly (AVAudioFile decodes them; fast, no subprocess).
- **FFmpeg fallback:** a container AVFoundation can't read (the §7.2 probe throws, or an `AVAudioFile` decode fails, or the UTType is a known FFmpeg-only format like `.webm`/`.mkv`/`.wma`) → run the bundled `ffmpeg` to decode it into a **temp 16 kHz mono WAV**, then feed that temp WAV to the existing `transcribeFile` + `transcode` path. Temp WAV deleted after.

Invocation (argv, never a shell string): `ffmpeg -nostdin -y -i <input> -vn -ac 1 -ar 16000 -f wav <temp.wav>`. If ffmpeg exits non-zero or produces no/empty output → reject with a clear message (this is also the readability + no-audio test for FFmpeg-decoded formats — replaces the §7.2 "reject WebM" branch, which now instead *succeeds* via ffmpeg).

### 8.2 The binary (verified)
- **FFmpeg 7.1.1, arm64 static, decode-only + PCM-WAV-encode, `--disable-network`.** Built size **2.92 MB stripped** (well under the 30 MB bar). Exact `./configure` recipe recorded in this repo (see §8.6). No external dylibs (only system frameworks) — native FFmpeg opus/vorbis/wma/aac/ac3/mp3/flac decoders need no libopus/libvorbis/etc.
- Committed to the repo at `Vendor/ffmpeg/ffmpeg` (a vendored binary; ~2.9 MB direct commit, no LFS). Because it's committed once (not per-release), it does not need to be in the release-commit allowlist; confirm it's tracked before the first release that bundles it.

### 8.3 Bundling + signing (verified)
- **Xcode Copy Files build phase** → destination `Contents/Helpers`, file = `Vendor/ffmpeg/ffmpeg`, **"Code Sign On Copy" ON.** This bundles + signs it in **every** build (Debug test installs AND Release archive), with hardened runtime in Release (`ENABLE_HARDENED_RUNTIME=YES`) — so notarization passes with no `build-dmg.sh` change. **No entitlement required** (static, no JIT, no dylib loading).
- Verified the release re-sign is safe: `build-dmg.sh:129` re-signs the app with `--force --options runtime --entitlements … ` **without `--deep`**, which preserves the already-signed nested `ffmpeg` and re-seals `CodeResources`. Notarization covers the nested helper (whole `.app` submitted + stapled). Implementer MUST verify after first archive: `codesign -dvv Contents/Helpers/ffmpeg` shows Developer ID + `runtime` flag, and `spctl -a -t exec` on the DMG passes.
- pbxproj risk: adding a Copy Files phase + a `Vendor/` file reference is a finicky multi-edit (cf. the "Resources/ needs 4 pbxproj edits" gotcha). Implement carefully and verify the phase runs (binary present + signed in the built `.app`).

### 8.4 Runtime (verified)
Resolve at `Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")` (the `forAuxiliaryExecutable:` API only searches `Contents/MacOS`, returns nil for Helpers). Invoke via `Process` with `executableURL` + `arguments` array. Non-sandboxed, so no permission issue; Developer-ID-signed + notarized helper launches without Gatekeeper friction (same Team ID as parent). Run off the main actor (like `transcode()`), with a timeout/cancellation so a wedged decode can't hang an import (and honors the mic-preempt collision logic — a cancelled import must kill the ffmpeg `Process`).

### 8.5 Gate change
`validate()` widens again: accept `.audio || .movie` **plus** the FFmpeg-only types (WebM `.webm`, Matroska `.mkv`/`dyn.*`, WMA — currently explicitly rejected). Simplest: accept if `type.conforms(to: .audio) || type.conforms(to: .movie) || <known ffmpeg ext/UTI>`. The WMA explicit reject (§7 F2) is REMOVED — WMA now decodes via ffmpeg. Only truly unknown/non-media files are rejected up front; anything media-ish is attempted (native, then ffmpeg), and a genuine failure surfaces a clear per-file error.

### 8.6 LGPL compliance (documentation task, not technical)
The build is **LGPL v2.1+** (no `--enable-gpl`, no GPL codecs). Static-linking LGPL obligates: (a) ship the FFmpeg license text (bundle `LICENSE`/`COPYING.LGPLv2.1` + a notice in About/Help), and (b) offer the corresponding source + the exact `./configure` recipe + a way to relink. Record the recipe + FFmpeg version in the repo (e.g. `Vendor/ffmpeg/BUILD.md`). Standard, well-trodden for FFmpeg-bundling apps. (An `--enable-shared` variant avoids the static-relink obligation but adds dylib-bundling plumbing for no functional gain — not worth it.)

### 8.7 Blast radius
Medium: new `Vendor/ffmpeg/ffmpeg` (+ `BUILD.md` + license), one pbxproj Copy Files phase, a `FFmpegDecoder`/`DecodedSource` helper + its wiring into `FileTranscriptionIngest.run()` (decode-resolution + temp cleanup + widened `validate()`), an About/Help license notice, and `features.md`. No `Transcriber` change, no new permission/entitlement, no `build-dmg.sh` change (Copy Files handles signing). Touches the RELEASE artifact (a nested signed binary) — the highest-risk part; verify signing/notarization on the first DMG.

**Open for review (ffmpeg):**
1. Copy Files build phase (signs in every build) vs. sign-in-`build-dmg.sh` (Release-only, but no pbxproj edit) — the design picks Copy Files so Debug test installs also have working ffmpeg. Right call?
2. Decode-resolution trigger: by UTType (known-ffmpeg-formats always use ffmpeg) vs. try-AVFoundation-then-fallback-on-failure. Former is simpler/predictable; latter maximizes the fast native path. Which?
3. Temp-WAV lifecycle + cancellation (killing the ffmpeg `Process` on mic-preempt) — get this right so no orphaned temp files or zombie processes.

### 8.8 Review outcome — MANDATORY tightenings before implementation
Independent review confirmed the architecture + signing are sound (and `build-dmg.sh:140`'s `codesign --verify --deep --strict` catches an unsigned nested helper *before* notarization). Signing choice: **Copy Files + Code Sign On Copy is correct** (auto identity per config, covers Debug). Required fixes:

- **F1 (critical) — cancellable subprocess.** Do NOT model the ffmpeg call on `transcode()`'s `Task.detached` (`FileTranscriptionIngest.swift:278`) — `Task.detached` does NOT inherit cancellation, so a mic-preempted import would leave a **zombie ffmpeg + leaked temp WAV** running the whole decode. Model it on **`LMStudioSetup.runProcess` (`Sources/LLM/LMStudio/LMStudioSetup.swift:633-716`)**: `withTaskCancellationHandler { withCheckedThrowingContinuation … } onCancel:` that actually `process.terminate()` / `kill(-pid, SIGTERM)` (with `setpgid`), a `DispatchSource` watchdog **timeout**, and a resume-once guard. `cancelInFlight()` (`RecorderController.runFlow():253`) must reach this so a live dictation truly kills the decode.
- **F2 — temp WAV cleanup.** Create the temp WAV in `FileManager.default.temporaryDirectory` (NOT `RecordingStore.audioDirectory`), and unlink it with a single `defer { try? FileManager.default.removeItem(at: tempWav) }` established the instant the URL is created — covering ALL ~7 exit paths (the current per-path unlink idiom already regressed once → bug #2).
- **F3 — pipe/timeout.** Drain or discard ffmpeg's stderr (redirect to `/dev/null`; argv already has `-nostdin`) — an undrained full pipe deadlocks a long decode. Add the watchdog timeout from F1.
- **R5 — finite allowlist gate.** Do NOT accept "anything media-ish" (a `dyn.*` UTI matches any unknown extension → junk routed to ffmpeg). Keep `.audio || .movie` and OR in an EXPLICIT set `{webm, mkv, wma, avi, flv, wmv, m4b, …}` by extension/UTI. Remove the WMA hard-reject (`:161-163`).
- **R6 — §7.2 probe rewrite.** The existing `.movie` probe REJECTS unreadable containers (`:236`). §8 changes that branch to route to ffmpeg instead of rejecting; reconcile the no-audio-track detection between the AVAsset probe and ffmpeg (ffmpeg on a truly-audioless file exits non-zero or empty → map to "no audio"). §8 rewrites §7.2 semantics, not merely prepends.
- **R7 — dedicated error messages.** Add `IngestError` cases so an ffmpeg failure (unsupported inner codec, DRM-in-mkv, no audio) surfaces "couldn't read this file's audio" — NOT the generic `:357` "corrupted or unsupported."
- **Missing:** commit the binary mode `100755` (else `Process` → `EACCES`) and add `.gitattributes` `Vendor/ffmpeg/ffmpeg binary` (prevent EOL/text normalization corrupting it); a `Process`-launch-failure/corrupt-binary path → "extended decoder unavailable" message; note ~115 MB temp WAV/hour (bounded, one-at-a-time).
- **R3 caveat:** `Vendor/` is outside the release allowlist (add-only staging keeps the committed binary, but a *rebuilt* binary must be committed by hand or a release ships a stale ffmpeg). **R4:** the Copy Files pbxproj edit is 5 coordinated objects with no in-repo template — implement carefully and verify (`Contents/Helpers/ffmpeg` present + `codesign -dvv` shows Developer-ID + `runtime` on the built .app). Since the Xcode GUI isn't drivable here, hand-edit is required — consider a single `PBXShellScriptBuildPhase` (copy + `codesign --options runtime -s "$EXPANDED_CODE_SIGN_IDENTITY"`) as a lower-object-count alternative if the 5-object Copy Files edit proves fragile.
- **LGPL:** drop the FFmpeg license text into `NOTICE` "Third-party software" + `AboutPane.swift:445` Acknowledgements; record the exact recipe in `Vendor/ffmpeg/BUILD.md`. (Separate-executable-invoked-via-`Process` trivially satisfies the relink obligation.)
