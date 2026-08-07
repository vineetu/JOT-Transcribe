# `jot` CLI — file → WebVTT transcript (optional diarization)

**Status:** v1 shipped (`tools/jot-cli/`, bundled at `Contents/Helpers/jot`). §§1–8 below are the v1 design, kept for the record; **§9 onward is the v2 design (utility transcriber)** — design stage, not implemented.
**Ask (user):** a command-line tool that takes an audio OR video file and outputs a transcription, with an option for speaker diarization. **Distribution:** bundled inside `Jot.app`. **Output format:** WebVTT.

## 1. Why a CLI (and why it's the honest home for diarization)
Diarization is only reliable on **clean, separate-audio-per-voice** input (meeting/call recordings, a video's own soundtrack) — not audio captured acoustically through speakers→mic. A CLI is exactly the right surface for that: the user feeds a known-good file (e.g. Zoom's own recording), gets labeled turns out, and there's no GUI implying "who's talking" magic. File-in / VTT-out, power-user, no over-promise. It also productizes what already works headless — the in-session `nemotron-probe` and `diarize-probe` prove the transcription and VBx engines run fine outside the app.

## 2. Interface
```
jot transcribe <file> [--diarize] [-o <out.vtt>]
```
- `<file>` — any audio/video the app import supports (native + the bundled-ffmpeg long tail: webm/mkv/wma/…).
- `--diarize` — run VBx and emit speaker-labeled cues (`<v Speaker 1>`); without it, plain timestamped cues.
- `-o <path>` — write to file; default is stdout (pipeable).
- Output is **always WebVTT** (the chosen format). Exit non-zero + stderr message on failure (unreadable file, models missing, no audio).
- `jot install` / `jot --version` / `jot --help` housekeeping (install = symlink into PATH, §5).

## 3. Reuses (all already proven headless)
- **Decode:** the bundled `Vendor/ffmpeg/ffmpeg` (or AVFoundation for native) → 16 kHz mono — the same `FFmpegDecoder` path the app import uses.
- **Transcription:** FluidAudio (Parakeet TDT / Nemotron) — same as `nemotron-probe`.
- **Diarization:** FluidAudio offline VBx — same as `diarize-probe`.
- **WebVTT formatter:** the SAME `WebVTTExporter` built for the in-app export (`docs/webvtt-export/design.md`) — one formatter, two callers. This is the shared seam that makes the CLI cheap.

## 4. The load-bearing decision — code sharing
The app is a **single Xcode executable target**; the CLI needs the transcribe + diarize + decode wrappers. Three options:

- **(A) Separate SPM executable using FluidAudio directly** (what the probes already do). Cheapest to stand up, zero coupling to the app target, builds independently. Cost: re-implements the thin transcribe/diarize wrapper (but that wrapper is small — the probes are ~200 lines) and can't share the app's exact `Transcriber`/`DiarizerHolder` without copying files.
- **(B) Extract a shared library/framework target** (`JotEngine`) that both the app and the CLI link — the "correct" long-term factoring (transcription, diarization, decode, WebVTT in one lib). Cost: a real refactor of the single-target app to pull the engine out; higher blast radius, but removes duplication and is the maintainable end-state.
- **(C) CLI Xcode target that compiles the shared source files** (same files, two targets via membership). Middle ground; avoids a formal library but couples build settings.

**Lean: (A) for v1**, matching the probes and the user's "ship it, refactor later" principle — a standalone SPM `jot` executable that links FluidAudio + a small shared `WebVTTExporter` (kept in a location both can compile). Flag **(B)** as the right follow-up if the CLI and app engine start drifting. Review should challenge this: is the wrapper duplication acceptable, or is the library extraction worth doing now?

## 5. Distribution — bundled in Jot.app
- Build the `jot` binary and place it at `Jot.app/Contents/Helpers/jot`, **code-signed with hardened runtime** — exactly the Copy/Run-Script + signing pattern the `ffmpeg` helper already uses (proven: `codesign --verify --deep --strict` passes, notarization-safe).
- **Install to PATH:** a `jot install` subcommand (or a Settings/menu action) symlinks `Contents/Helpers/jot` → `/usr/local/bin/jot` (prompt for the one-time admin write, or drop into `~/bin`). Never silently modify PATH.
- **Models:** load from the app's existing model dir (`~/Library/Application Support/Jot/Models/…`). If absent, exit with a clear message: "Open Jot once to download the transcription model, then retry." The CLI does NOT download models itself in v1 (keeps it thin; the app owns model lifecycle).

## 6. WebVTT output specifics
- **With `--diarize`:** cue-per-`SpeakerTimelineSegment`, `<v Speaker N>` voice tags, real `startSec`/`endSec` — identical to the in-app export.
- **Without `--diarize`:** we still need cue timestamps. OPEN (§8 R1): does FluidAudio expose per-segment/token timestamps for a plain transcript? If yes → timestamped cues. If no → a single cue `00:00:00.000 --> <duration>` with the whole transcript (valid VTT, just uncued). Decide from the API.

## 7. Blast radius
- New `jot` executable (SPM target, option A) — the bulk is CLI arg parsing + wiring the existing engine calls + the shared `WebVTTExporter`.
- Bundling: a build-phase copy + sign into `Contents/Helpers/jot` (mirrors ffmpeg) + `.gitattributes`.
- Install subcommand (symlink).
- **No changes to the app's transcription/diarization runtime** — the CLI is additive.

## 8. Risks / open questions
- **R1 — non-diarized timestamps** (§6): does FluidAudio give segment timestamps for plain transcription? Determines whether non-diarized VTT is properly cued or one big cue. LOAD-BEARING for output quality.
- **R2 — code sharing** (§4): (A) duplicates a thin wrapper; (B) is a real refactor. Pick with eyes open.
- **R3 — binary size / model loading:** the CLI links FluidAudio (CoreML). Confirm it loads the app's on-disk models headless (the probes already do this — low risk) and the binary size is acceptable in the bundle.
- **R4 — signing/notarization:** the bundled `jot` must sign + notarize clean like `ffmpeg` (hardened runtime, `--deep --strict`). Proven pattern, but verify for a Swift executable (not just a C binary).
- **R5 — install UX / PATH:** symlink into `/usr/local/bin` needs admin; `~/bin` may not be on PATH. Decide the least-surprising install path.
- **R6 — diarization honesty:** the CLI should still say (in `--help` / on a single-speaker result) that diarization needs clean per-voice audio — carry the same honest framing as the GUI note (task #17).

---

# v2 — utility transcriber: cleaned text, vocabulary, stdin streaming

**Status:** design — not implemented.
**Ask (user):** evolve the bundled CLI into a standalone-feeling utility: plain *cleaned* text out by default, custom vocabulary applied (optionally off), **streaming** where audio is piped in as it plays (mic optional, not required), installable from the command line (installing the CLI installs the app), and a good man page. The app and the CLI run in parallel and never talk at runtime — shared **on-disk conventions only** (model dir, `vocabulary.txt`). No history: the CLI never touches the app's SwiftData library.

## 9. Principle — everything substantive comes from `jot-shared`

No new package, no new repo. The CLI becomes a real consumer of the existing shared package, which grows where needed:

| Capability | Source | State |
|---|---|---|
| Cleanup chain (segment → filler-clean → number-normalize) | `JotTextPipeline` | exists — CLI adds the dependency |
| Final whitespace/punctuation pass (`PostProcessing`) | move from `Sources/Transcription/` into `JotTextPipeline` | small jot-shared update; app switches to the moved copy |
| Vocabulary | `JotVocabCore` — **model-free** `VocabularyCorrector` + `VocabularyGate` + `VocabularyFile` | exists — no CTC spotter, no CoreML, no extra model downloads; ideal for a headless binary |
| Engine orchestration (batch + streaming) | new third target/product in jot-shared (working name `JotEngine`), lifted from the app's `Transcriber` / `NemotronStreamingEngine` seam (`ensureLoaded` / `start(onPartial:)` / `enqueue(samples:)` / `finish`) | Phase 2 (§13) |

Accepted consequence of the engine target: `jot-shared` gains FluidAudio as a *package-level* dependency. Consumers of the text/vocab products don't link it (SPM links per-product), but it enters their dependency resolution; the engine target floors at macOS 15 while the package floor stays iOS 17 / macOS 14 for the existing products.

## 10. Interface v2

```
jot transcribe <file> [--vtt] [--diarize] [--raw] [--no-vocab] [--vocab <file>]
                      [--language <code>] [-o <path>] [--model-dir <dir>]
jot stream [--mic] [--format s16le|f32le] [--raw] [--no-vocab] [--vocab <file>]
           [--language <code>] [--model-dir <dir>]
jot --help | --version
```

- **Default output flips to plain cleaned text** (v1 emitted WebVTT unconditionally; v1 shipped bundled-only, so the break is acceptable — `--vtt` restores cue output, and `--diarize` implies `--vtt`).
- **Text mode** runs the full chain: vocab corrections → segment → filler-clean → number-normalize → `PostProcessing`. `--raw` skips the cleanup chain (vocab still applies unless `--no-vocab`).
- **VTT mode** keeps v1 behavior for cue text (timings own the words; fillers/ITN would desync cues). Vocab corrections *do* apply per-cue — word-for-word swaps are timing-safe.
- **Vocabulary** is on by default when the well-known file exists (`~/Library/Application Support/Jot/Vocabulary/vocabulary.txt` — the same file the app writes, already in FluidAudio's simple format). `--vocab <file>` points elsewhere; `--no-vocab` disables. Reading a documented path is a convention, not a runtime dependency — the parallel-tools property holds.
- **`--language <code>`** mirrors the app's gating: the English-only stages (filler list, spelled-number ITN) are skipped for non-English, and the code is passed to FluidAudio as the script hint. Default `en`.
- Everything still writes to **stdout** (shell redirection is the interface); `-o` stays for parity with v1.

## 11. Streaming (`jot stream`)

The primary input is **piped audio on stdin** — some other process produces audio as it plays and pipes it in. No microphone required.

- **stdin contract:** raw PCM, 16 kHz mono, `s16le` by default (`--format f32le` accepted). A leading RIFF/WAV header is autodetected and skipped. Anything else is the user's job to convert — the man page carries the recipes:
  ```sh
  ffmpeg -i input.webm -f s16le -ar 16000 -ac 1 - | jot stream
  ffmpeg -f avfoundation -i ":0" -f s16le -ar 16000 -ac 1 - | jot stream   # live capture
  ```
- **Engine:** the same streaming seam the app uses (Nemotron streaming via `JotEngine`), loading from the app's model dir. If the streaming model isn't downloaded: exit non-zero with "Open Jot once to download the streaming model, then retry" — the CLI still never downloads models.
- **Output behavior:** partial hypotheses are shown only when **stdout is a TTY** (single line, carriage-return rewrite); when piped, partials are suppressed so downstream consumers see only final text. On stdin EOF (or SIGINT) the engine finalizes, the cleanup + vocab chain runs over the final transcript, the result prints to stdout, exit 0.
- **`--mic`** switches the source to the default input device via `AVAudioEngine` (the terminal app owns the mic TCC prompt — documented in the man page). Stop with Ctrl-C → same finalize path.

## 12. Distribution & man page

- **Bundled (unchanged):** `Contents/Helpers/jot`, signed, built from `tools/jot-cli/`, ffmpeg sibling.
- **Command-line install:** a Homebrew **cask** whose artifact is the Jot.app DMG, with a `binary` stanza exposing the bundled CLI on PATH and a `manpage` stanza — "installing the CLI installs the app" is literally how a cask works. The DMG remains the primary channel; the cask is an alternate front door to the same artifact.
- **Name collision (decide before the cask ships):** macOS ships BSD `jot(1)` at `/usr/bin/jot`, and `/usr/local/bin` precedes it on PATH — installing as `jot` shadows a system tool and its man page. Recommendation: the *installed* name (binary + man page + cask token) is **`jot-cli`**; the in-bundle helper keeps its `jot` name. Flag for review.
- **Man page:** `tools/jot-cli/jot-cli.1` (troff, checked in, versioned with the source). Sections — NAME, SYNOPSIS, DESCRIPTION (two modes, parallel-to-the-app framing), COMMANDS, OPTIONS, STREAMING (stdin contract + ffmpeg recipes), FILES (model dir, `vocabulary.txt`, both marked "shared conventions with Jot.app"), EXIT STATUS, EXAMPLES (pipe to file, pbcopy, live ffmpeg), SEE ALSO (`jot(1)` BSD, Jot.app help). "Just the right amount": one screen of DESCRIPTION, recipes over prose.

## 13. Phasing

- **Phase 1 — no engine extraction:** add the jot-shared dependency to `tools/jot-cli`; text-default output + cleanup chain + `JotVocabCore` vocabulary; move `PostProcessing` into `JotTextPipeline` (app switches import); man page; cask. The CLI keeps its small v1 `AsrEngine` for batch.
- **Phase 2 — engine into jot-shared:** lift the batch + streaming orchestration into the `JotEngine` target; CLI gains `jot stream`; app and CLI both consume the shared engine. This is the point where v1's deliberate wrapper duplication (§4 option A) is retired, on the trigger v1 itself named: the surfaces started drifting.

## 14. Risks / open questions (v2)

- **R7 — text-default break:** anyone scripting against v1's VTT-on-stdout gets text after upgrade. Judged acceptable (bundled-only, one release old); call it out in release notes.
- **R8 — streaming finalization quality:** cleanup runs once on the final transcript, so paragraph segmentation depends on the streaming engine returning usable timings; if Nemotron streaming yields none (as in batch), streamed output is a single block — same honest degradation the app has.
- **R9 — vocab parity with the app:** the CLI uses only the model-free corrector; the app can additionally use the acoustic rescorer. Same `vocabulary.txt`, slightly different recall. Document in the man page FILES section rather than pretending parity.
- **R10 — cask naming/shadowing (§12):** confirm `jot-cli` vs `jot` before publishing the cask.

---

# v2.1 — Call Assist: machine streaming mode + setup

**Status:** design — not implemented. Supersedes §11's output behavior for machine consumers; §11's TTY/EOF behavior survives as the human mode.
**Consumer:** Call Assist puts an AI agent on a live phone call; `jot --stream` is the agent's ear. Its requirements (live segment-by-segment text, ~2 s commit SLA, whole-call sessions with hold music, text-only, fail-loud) are the contract this section designs to.

## 15. Machine streaming mode

```
jot --stream --language <code> --rate 16000 --encoding s16le [--no-vocab]
```

- **Engine: Nemotron 3.5 streaming only** (`en` → English bundle, others → Multilingual). No Parakeet batch models involved; `--language` is fixed per invocation (no mid-call switching).
- **Output: NDJSON on stdout, flushed per line.** `{"type":"final","text":"..."}` per committed segment; `{"type":"partial",...}` optional (nothing breaks if never emitted). This is a protocol another product depends on: additive changes only.
- **Incremental finals via append-only partials.** Nemotron's partial hypothesis only ever grows — it does not revise committed text. Finals are derived by forwarding each stable extension of the partial string at commit boundaries. No engine API change needed; the existing `onPartial` callback carries everything.
- **No cleanup chain.** Call Assist needs words promptly, no punctuation/paragraph guarantees. `JotTextPipeline` stages do not run in this mode (they are held-back-for-context by nature). Raw engine text per segment, vocab-corrected only (below).
- **Vocabulary: chunked CTC spot+gate per segment, inside the 2 s SLA.** `StreamingCtcSpotter` already streams the expensive log-prob inference across the audio (FluidAudio-identical 15 s chunks, 2 s overlap) so per-segment cost is only the cheap DP + gate: on each Nemotron commit, run the DP over that segment's audio window (overlapped ~2 s into the previous segment to catch boundary-straddling terms), gate detections through the same Nemotron spot+gate path the app's dual pipeline uses, emit the corrected final. Fallback when the CTC model is absent: the model-free `JotVocabCore` corrector (zero download, per-segment safe). `--no-vocab` disables both.
- **Fail loudly — inverted error philosophy.** The app's engine wrappers log-and-continue on `process()` errors and return silently if `ensureLoaded()` fails mid-stream; both are exactly the "silently deaf agent" failure Call Assist names as worst-case. In `--stream`: any engine error → stderr + non-zero exit. No fallback, no retry, no degraded continuation.
- **Long-run hygiene (minutes to an hour, hold music, silence):** riding through non-speech without exiting is required; emitting nothing during quiet is correct. Session-recycling during silence is kept in reserve as a hygiene mechanism (bounded engine state, hallucination-on-music guard), not for correctness. Validate memory behavior on hour-long streams before shipping.
- `--rate` accepts only `16000` and `--encoding` only `s16le`/`f32le`; anything else exits non-zero at startup (predictable > permissive).

## 16. Setup — `jot setup`, no GUI required

The CLI's only real setup is **models** (no TCC for file/stdin paths; `--mic` triggers the system prompt on first use, attributed to the invoking terminal). v1's "open Jot once to download" rule breaks for Call Assist-style headless deployment, so:

- **`jot setup --language <code> [--streaming|--batch]`** downloads exactly the bundles that mode+language needs (stream: Nemotron + CTC spotter model; batch: Parakeet v3 / JA). Idempotent. `jot setup` with no args prints status: what's on disk, what each mode would need.
- **Explicit, never automatic.** A transcribe/stream invocation that finds models missing fails loudly with the exact `jot setup` command to run — it never silently pulls 500 MB+ mid-command.
- **Peer, not owner.** Download logic is the app's `ModelDownloader`, moved into the `JotEngine` target — one implementation, two callers, identical directory layout. `ModelCache.isCached()` already decides "downloaded" by disk presence, so CLI-fetched models are simply there for the app and vice versa. Advisory lock file per bundle prevents app/CLI download races.
- Headless deployment path: `brew install jot-cli` → `jot setup --language en --streaming` → `jot --stream ...`, no window ever opened.

## 17. Risks / open questions (v2.1)

- **R11 — append-only assumption is load-bearing:** the finals derivation is correct only if Nemotron partials truly never revise. Verify against FluidAudio 0.15.4 behavior (including across chunk boundaries) before freezing the protocol.
- **R12 — segment→audio-window mapping:** Nemotron returns no token timings; the per-segment DP window is derived from sample counts at commit boundaries. Validate placement quality; the gate remains the placement authority.
- **R13 — non-speech stretches:** hour-scale sessions are field-proven — the app's Nemotron dictation path runs this engine continuously for 30–60 min recordings and ships `finish()` as the final transcript. What dictation never feeds it is minutes of continuous hold music / silence (the classic hallucination surface) — probe that specifically; promote silence-recycling from reserve to required only if the probe shows drift or emissions on non-speech.
- **R14 — SLA measurement:** 1120 ms chunk cadence + inference + DP + gate must be measured end-to-end against the 2 s commit SLA on target hardware, not asserted.
