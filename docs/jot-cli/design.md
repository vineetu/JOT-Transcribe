# `jot` CLI — file → WebVTT transcript (optional diarization)

**Status:** design — awaiting independent review. Not implemented.
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
