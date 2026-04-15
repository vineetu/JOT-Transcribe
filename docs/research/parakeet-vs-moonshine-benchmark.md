# Transcription benchmark — on-device, real recordings

**Machine.** This M-series Mac running macOS 26.4, ONNX Runtime 2.0 rc12 (via `transcribe-rs` 0.3.11), FluidAudio 0.12.4, all in release mode.

**Audio corpus.** Four recordings from the user's `~/Library/Application Support/com.openvoice.app/recordings/` directory, chosen for duration spread. All are 16 kHz mono 32-bit float PCM WAV captured by the app's CPAL recorder.

- 1.0 s (near-silent setup-test tap — most engines produce empty transcript)
- 7.0 s ("It is working. I'm so happy that it is working.")
- 25.0 s (real dictation — "In 2026 April all of the coding agents have sub-agents, so can you verify if that's true…")
- 142.7 s (continuous dictation — design-doc narration)

**Protocol.** For each configuration: load model, one warmup run, then three timed runs; report median. All timings are wall-clock, inference only (warmup excluded from median).

## Results — median transcription latency (ms)

| Engine | Backend | 1.0 s | 7.0 s | 25.0 s | 142.7 s |
|---|---|---:|---:|---:|---:|
| Moonshine small-streaming (what we ship today) | CPU via ORT | 31 | 258 | 961 | **crashed** |
| Moonshine small-streaming | CoreML EP | — | — | **load error** | — |
| Moonshine base (non-streaming) | CPU via ORT | 11 | 39 | 436 | not run |
| Moonshine base | CoreML EP | 27 | 93 | 669 | not run |
| Parakeet TDT 0.6B int8 (transcribe-rs) | CPU via ORT | 48 | 200 | 667 | 5 647 |
| Parakeet TDT 0.6B int8 (transcribe-rs) | CoreML EP | — | — | 1 268 | — |
| **Parakeet TDT 0.6B v2 (FluidAudio)** | **Apple Neural Engine** | (empty) | **91** | **171** | **954** |

## Real-time factor (median ms ÷ audio ms)

| Engine | Backend | 7 s | 25 s | 143 s |
|---|---|---:|---:|---:|
| Moonshine small-streaming (current) | CPU | 0.037 | 0.039 | n/a |
| Parakeet TDT 0.6B int8 | CPU | 0.028 | 0.027 | 0.040 |
| **Parakeet TDT 0.6B v2 FluidAudio** | **ANE** | **0.013** | **0.007** | **0.007** |

FluidAudio on the Neural Engine is **5–6× faster** than what we ship today and **~3–6× faster** than the pure-Rust CPU Parakeet path on the same audio.

## Model-load latency (warm, after first-ever download)

| Engine | Cold load | Warm load |
|---|---:|---:|
| Moonshine small-streaming (CPU) | ~140 ms | ~130 ms |
| Moonshine base (CPU) | ~450 ms | ~430 ms |
| Moonshine base (CoreML) | ~1 450 ms | ~1 400 ms |
| Parakeet TDT int8 (ORT CPU) | ~560 ms | ~540 ms |
| **Parakeet FluidAudio (ANE)** | **28 700 ms** first time (download + CoreML compile) | **~170 ms** |

FluidAudio has a one-time cost on first launch: it downloads a ~600 MB Parakeet `.mlpackage` from Hugging Face and Apple's CoreML runtime compiles it for this chip. Both are cached under `~/Documents/FluidAudio/` after the first load. Subsequent cold-loads of the process are ~170 ms.

## Transcript quality — spot-check on the 25 s clip

Same audio, three engines, first 100 chars:

- **Moonshine small-streaming (CPU):** `in 2026 April all of the coding agents have sub agents so can you verify if this`
- **Parakeet ORT (CPU):** `In twenty twenty-six April all of the coding agents have sub agents, so can you verify if that's tru`
- **Parakeet FluidAudio (ANE):** `In 2026, April, all of the coding agents have subagents. So can you verify if that's true? I think u`

Parakeet (either backend) produces better casing, contractions, and punctuation. FluidAudio's output is noticeably more "post-edited" looking — numbers rendered as digits, commas between clauses.

## Failures worth flagging

1. **Moonshine small-streaming crashes on audio longer than about 30 s** inside its own ONNX graph (`axis == 1 || axis == largest was false`). The production app works around this by chunking at silence; the raw model does not handle long audio in a single call. This is a correctness gap in what we ship today.
2. **ONNX Runtime's CoreML Execution Provider refuses to load the streaming Moonshine model** at all (`Input (k_self) has a dynamic shape ({10,1,8,-1,64}) but the runtime shape ({10,1,8,0,64}) has zero elements`). Confirms that "enable `ort-coreml` and get GPU" was not the free win my earlier research doc implied.
3. **ONNX Runtime's CoreML EP is consistently slower than CPU** on this machine for both Moonshine-base and Parakeet. This matches a well-known ORT issue (microsoft/onnxruntime#9433) where the CoreML EP configures `MLComputeUnitsAll` on load but then predicts with `MLComputeUnitsCPUOnly`, so the Neural Engine and GPU never actually execute. Translation: the "CoreML" setting on ORT is, in practice, CPU with extra IPC overhead.
4. **FluidAudio emits `E5RT encountered an STL exception` runtime warnings to stderr** on every inference. Transcription proceeds correctly and output is stable — these are ANE runtime diagnostics not errors — but they will need to be suppressed or routed if we ship this path.

## Bench harness

- Rust: `/tmp/ov-bench` (transcribe-rs 0.3.11, features `onnx` + `ort-coreml`, hound for WAV). Source verbatim in `/tmp/ov-bench/src/main.rs`.
- Swift: `/tmp/ov-swift-bench` (FluidAudio 0.12.4 via SPM, AVFoundation for WAV load). Source in `/tmp/ov-swift-bench/Sources/OvSwiftBench/OvSwiftBench.swift`.

Both binaries accept `<model-path-or-ignore> <wav-path> [flags]` and emit a single machine-parseable `RESULT` line on stdout. Reusable for regression benchmarking when we add or swap engines.
