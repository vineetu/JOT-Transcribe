# Parakeet vs Moonshine on Apple Silicon — research notes

**Context.** Open Voice currently transcribes with **Moonshine** (ONNX, CPU, via the `transcribe-rs` crate with `features = ["moonshine"]` — see `src-tauri/Cargo.toml:69`). The intent brief calls for a polished local-first Mac dictation app with fast feedback. This note researches whether we should (a) GPU-accelerate the current Moonshine path, or (b) switch to (or add) NVIDIA's **Parakeet** ASR, and how those options compare on Apple Silicon.

Nothing below has been tested in-tree yet — this is research. A follow-up "try it" doc will benchmark real numbers from this machine.

---

## TL;DR

1. **Moonshine can be GPU-accelerated today with a one-line Cargo feature flip.** `transcribe-rs` already exposes an `ort-coreml` feature that routes ONNX inference through Apple's CoreML Execution Provider (CPU + GPU + Neural Engine). We're leaving performance on the floor by shipping with CPU-only.
2. **Parakeet is ~3–10× faster than Whisper on Apple Silicon and rivals/beats Whisper Large v3 in accuracy.** No apples-to-apples benchmark against Moonshine was published, but Parakeet's 0.6B-TDT is in a different class of accuracy (≈50 min of audio/sec on batch-128 CoreML) at a much larger model footprint (~600 MB vs Moonshine's 49–289 MB).
3. **The cheapest Parakeet integration for us is also through `transcribe-rs`.** That crate already supports Parakeet end-to-end and can route through CoreML. No FFI, no Python, no new C++ build system. Other routes (parakeet-mlx, parakeet.cpp, CoreML-packaged FluidInference) are technically interesting but carry significantly more integration cost.
4. **Recommendation:** enable `ort-coreml` for Moonshine immediately (easy win). Prototype Parakeet behind a feature flag via the same `transcribe-rs` crate and let users choose in Settings once we validate it on-device.

---

## Current state of our pipeline

- Transcription engine: **Moonshine** (`moonshine-small-streaming-en`, `-tiny-`, `-medium-` configurable — see `src/lib/services/transcription/local/moonshine.ts:10–77`).
- Call path: JS blob → Tauri `invoke('transcribe_audio_moonshine', {audioData, modelPath})` → Rust handler → `transcribe-rs` with `moonshine` feature (`Cargo.toml:69` + `68`).
- Models shipped as `.ort` (ONNX Runtime) artifacts downloaded from `blob.handy.computer`.
- **Execution:** ONNX Runtime with default EP. Default on macOS is the CPU EP. No Metal / CoreML wired up.

## What "GPU on Mac" actually means in ONNX-land

ONNX Runtime does not have a native Metal / MPS backend. Apple-hardware acceleration goes through the **CoreML Execution Provider**:

- CoreML itself routes ops to CPU, GPU, or the Neural Engine (ANE) based on device class and op support.
- Requires macOS ≥ 10.15. Already our minimum (`src-tauri/tauri.conf.json` / `Cargo.toml` — `minimumSystemVersion: "10.15"`).
- Wired in `transcribe-rs` behind the `ort-coreml` feature flag.

**Implication:** enabling GPU/ANE for Moonshine is a feature-flag change, not a backend rewrite. The Rust API of `transcribe-rs` doesn't change; session creation internally picks up the CoreML EP when the feature is compiled in.

---

## Parakeet on Apple Silicon — the four options

| Option | Language / runtime | GPU path | Integrability into our Tauri+Rust app |
|---|---|---|---|
| **`transcribe-rs` with Parakeet feature** | Rust (ONNX Runtime) | CoreML EP (GPU/ANE) | ✅ **already a dep** — flip a feature flag |
| `parakeet-rs` (altunenes) | Rust (ONNX Runtime) | CoreML EP (GPU/ANE) | ✅ drop-in Rust crate, but duplicates `transcribe-rs` |
| **parakeet.cpp** (jason-ni) | C++ with GGML / Metal | Metal MPS via GGML | ⚠️ C++ FFI layer required, new build system, 80-bin Mel pipeline pre-baked |
| **parakeet-mlx** (senstella) | Python + Apple MLX | MLX (GPU, unified memory) | ❌ Python runtime + ffmpeg + MLX — not embeddable into a Tauri binary without bundling a Python stack |
| **FluidInference parakeet-tdt-0.6b-v2 CoreML** | `.mlmodel` package | Native CoreML (ANE preferred) | ⚠️ requires a Swift / objc2 host to call `MLModel`, plus a streaming wrapper; smallest memory footprint (~66 MB vs ~2 GB for MLX) |

### Claimed performance numbers (from published sources — not in-tree)

- **Parakeet-MLX**: ~80 ms per short clip on M-series GPU; ~3–6× faster than Whisper; 10× faster than Whisper on a 35-min file (single end-user anecdote).
- **Parakeet.cpp**: "~27 ms encoder inference on Apple Silicon GPU for 10 s of audio (110M)". Caveat: encoder-only; feature extraction + decoder not included. Full E2E pipeline is slower.
- **FluidInference CoreML Parakeet-TDT-0.6B-v2**: RTFx ≈ 3380 at batch-128 on HF-Open-ASR leaderboard — ~56 min of audio per second under ideal batching. Single-utterance RTFx will be lower but still well above real-time.
- **Parakeet vs Whisper Large v3 accuracy**: Parakeet v3 wins on the HF Open-ASR leaderboard while being dramatically smaller and faster.
- **Moonshine vs Whisper**: Moonshine-tiny/small beat Whisper-tiny/small at a fraction of the size. No published head-to-head Moonshine vs Parakeet benchmark.

### Memory footprint on Mac (from published sources)

- Parakeet via MLX: ~2 GB working memory.
- Parakeet via CoreML (FluidInference): ~66 MB working memory — routed to Neural Engine, not GPU.
- Moonshine small: ~158 MB model on disk, working memory in the same ballpark.

**Key insight:** "GPU acceleration" on Mac sometimes means *Neural Engine* via CoreML — which is actually better for a menu-bar utility (less competition with user workloads) than raw GPU via MLX.

---

## Direct comparison for our use case

| Dimension | Moonshine (current) | Parakeet (proposed) |
|---|---|---|
| Model size on disk | 49 MB / 158 MB / 289 MB | ~600 MB |
| First-download time | Seconds–low minutes | Minute-plus on slow networks |
| Latency on short utterance (published) | Fast but CPU-bound today | 80 ms on GPU / <RTF 1 on CoreML |
| Accuracy on dictation-length English | Good (above Whisper Tiny) | Rivals/beats Whisper Large v3 |
| Languages | Mostly English (streaming variant) | Parakeet v3 supports 25 languages |
| Integration in our stack today | ✅ wired, CPU-only | ⛔ feature exists in `transcribe-rs`, not enabled |
| GPU / ANE path on Mac | CoreML EP via `ort-coreml` | CoreML EP via `ort-coreml` (or GGML/Metal via parakeet.cpp, or MLX) |
| Streaming support | ✅ (streaming variant shipped) | ✅ (parakeet-tdt streaming variant) |
| License | MIT / permissive | NVIDIA license — permits non-commercial research use; commercial usage check required |
| Download hosting | `blob.handy.computer` (3 sizes) | HuggingFace NVIDIA repo (standard) + FluidInference mirrors |

**Licensing note:** NVIDIA's licensing for Parakeet weights is looser than some of their other research artifacts but still needs a read-through before we ship Parakeet as default for commercial users. Moonshine is permissively licensed today.

---

## Recommendations

### Short term — get GPU on for Moonshine (low risk, high payoff)

1. In `src-tauri/Cargo.toml`, change the `transcribe-rs` dep from:
   ```toml
   transcribe-rs = { version = "0.2.9", features = ["moonshine"] }
   ```
   to (for macOS target):
   ```toml
   [target.'cfg(target_os = "macos")'.dependencies]
   transcribe-rs = { version = "0.2.9", features = ["moonshine", "ort-coreml"] }
   ```
   and similarly add `"ort-cuda"` / `"ort-directml"` for non-mac targets if we care.
2. Rebuild. ONNX Runtime will register the CoreML EP at session init. Expected outcome: 2–4× speedup on a warm session, larger on the first run because model graph gets CoreML-compiled and cached.
3. Watch for CoreML EP fallback: ops that don't map fall back to CPU silently. `transcribe-rs` exposes a logging hook — enable at debug level once to verify how much of the graph landed on ANE/GPU.

### Medium term — ship Parakeet as an opt-in engine

1. Add a second `transcribe-rs` feature build: `features = ["moonshine", "parakeet", "ort-coreml"]`.
2. Add a new Rust command alongside `transcribe_audio_moonshine` — e.g. `transcribe_audio_parakeet({audioData, modelPath})` — following the same signature so the frontend contract stays identical.
3. Add a new entry in the `TranscriptionPane` model picker that lists Parakeet variants. The existing `deviceConfig` key `transcription.moonshine.modelPath` becomes one of N paths — consider generalizing to `transcription.engine` + `transcription.<engine>.modelPath`.
4. Benchmark on-device: record a 30-sec sample, transcribe with both engines five times, capture median latency + transcript quality. Write results into `docs/research/parakeet-vs-moonshine-benchmark.md` (follow-up doc).
5. Gate the default engine on free RAM + first-run download size; users on slower links probably still want Moonshine by default.

### What NOT to do (yet)

- **Don't** vendor parakeet.cpp. The Metal/GGML path is appealing but adds a C++ build system, needs FFI bindings, and we don't have a proven throughput win over ORT + CoreML yet on our workload.
- **Don't** adopt parakeet-mlx. Bundling a Python + MLX runtime inside a Tauri `.app` is technically possible but doubles the installer size and adds a second dependency hell.
- **Don't** rip out Moonshine in one shot. Keep the smaller model as an option — low-RAM users and faster-download installs both matter for adoption.

---

## Open questions for the benchmark follow-up

1. CoreML EP caches compiled model graphs on disk — where, and how big? Affects first-run latency + disk use.
2. How does ORT's CoreML EP behave when the host has both GPU and ANE available? Does it pick ANE for the right sub-graphs, or do we need explicit `CoreMLFlags::USE_NEURAL_ENGINE`?
3. Parakeet via `transcribe-rs` — is the public Rust API symmetric with Moonshine (same `transcribe(blob, opts) -> String`)? If yes, the Tauri command is a one-file addition. If the streaming API diverges, it's more work.
4. Real-world throughput vs published numbers on an M1-class Mac (the published claims are mostly M2/M3-Max).
5. License — does NVIDIA's Parakeet weight license allow us to ship the model file bundled into a "Productivity" app on the Mac App Store?

---

## Sources

- [senstella/parakeet-mlx](https://github.com/senstella/parakeet-mlx)
- [jason-ni/parakeet.cpp](https://github.com/jason-ni/parakeet.cpp) · [gr3p overview](https://www.gr3p.net/article/parakeetcpp-parakeet-asr-inference-in-pure-c-with-metal-gpu-acceleration-930) · [HN discussion](https://news.ycombinator.com/item?id=47176239)
- [altunenes/parakeet-rs](https://github.com/altunenes/parakeet-rs)
- [cjpais/transcribe-rs](https://github.com/cjpais/transcribe-rs) · [docs.rs](https://docs.rs/transcribe-rs)
- [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
- [nvidia/parakeet-tdt-0.6b-v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) · [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
- [ONNX Runtime CoreML Execution Provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)
- [Whisper vs Parakeet benchmarks (Dictato)](https://dicta.to/blog/whisper-vs-parakeet-vs-apple-speech-engine/)
- [Parakeet V3 vs Whisper (Whisper Notes)](https://whispernotes.app/blog/parakeet-v3-default-mac-model)
- [MacParakeet — Whisper to Parakeet on the Neural Engine](https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/)
- [gptguy/silentkeys — Tauri + ORT + Parakeet reference](https://github.com/gptguy/silentkeys)
- [Northflank — Best open source STT 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
