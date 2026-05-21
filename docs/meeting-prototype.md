# Meeting Mode Prototype

## Purpose

This prototype validates the end-to-end meeting pipeline before any Jot
integration work: record microphone audio, run Parakeet TDT 0.6B v2 batch ASR,
run Sortformer diarization, align ASR token timings to speaker spans, and save a
speaker-labeled transcript.

It is standalone because the risk is mostly model/runtime behavior on real Apple
Silicon: model download/load time, ANE contention, Sortformer API stability, and
actual diarization quality. Keeping it in `prototypes/meeting-mode/` avoids
touching Jot's menu bar, hotkey, SwiftData, release, or package-resolution paths.

## Architecture

```text
AVAudioEngine
  -> AVAudioConverter
  -> 16 kHz mono Float32 samples + audio.wav
      -> Parakeet v2 batch ASR -> text + token timings
      -> Sortformer diarization -> speaker timeline
  -> AlignmentEngine
  -> final transcript display + transcript.json
```

| Stage | Prototype component | Output |
| --- | --- | --- |
| Capture | `AudioRecorder` | `[Float]` samples and `audio.wav` |
| ASR | `AsrManager` with Parakeet v2 | raw text and token timings |
| Diarization | `SortformerDiarizer` | speaker spans for slots 0-3 |
| Alignment | `Alignment.align` | `DiarizedSegment` values |
| Storage | `Storage.saveSession` | `transcript.json` |

## Model Variants

| UI mode | Sortformer config | Use |
| --- | --- | --- |
| Off | none | Validate Parakeet-only baseline and storage without segments |
| Live | `SortformerConfig.default` | Low-latency streaming Sortformer speaker timeline, about 1 second |
| Offline | `SortformerConfig.highContextV2_1` | Post-stop complete-buffer Sortformer pass with high context |

Sortformer is a streaming diarization model with fixed four-speaker slots. The
prototype uses its complete-buffer API for the Offline mode; it does not use
FluidAudio's separate pyannote/VBx offline diarization pipeline.

## Alignment Algorithm

```text
sort tokens by token start time
sort diarization spans by span start time
spanIndex = 0

for token in tokens:
    midpoint = (token.startSec + token.endSec) / 2

    while spanIndex can advance and spans[spanIndex].endSec <= midpoint:
        spanIndex += 1

    if spans[spanIndex] contains midpoint:
        speaker = spans[spanIndex].speaker
    else:
        speaker = 0

    if previous output segment has same speaker:
        append token text and extend segment end
    else:
        create a new DiarizedSegment
```

Display formatting adds one to the zero-based Sortformer slot, so speaker slot
`0` renders as `Speaker 1:`.

## Open Questions

- What DER does Sortformer produce on real meetings captured with built-in Mac,
  AirPods, and external USB microphones?
- Does the FluidAudio main-branch Sortformer API stay stable enough to integrate
  before a tagged release?
- How long do Parakeet v2 and Sortformer take to download, compile, and load on
  M1, M2, M3, and M4 machines?
- Does running Parakeet and Sortformer together contend for ANE resources enough
  to affect perceived stop-to-transcript latency?
- Does `SortformerConfig.highContextV2_1` improve practical speaker continuity
  enough to justify its post-stop latency?
- How often are Parakeet token timings missing, sparse, or shifted relative to
  Sortformer's 80 ms frames?
- Are four fixed speaker slots enough for the target meeting use cases?
- How should Jot display low-confidence or missing speaker spans?

## Path To Jot Integration

- Upgrade Jot's FluidAudio dependency to a Sortformer-capable release.
- Add a meeting-mode diarization setting with Off, Live, and Offline choices.
- Add a transcript storage schema for speaker-labeled segments and raw text.
- Decide whether meeting recordings live beside dictation recordings or in a
  separate library section.
- Add model download UI for Sortformer and clear cache/reset behavior.
- Share Jot's existing 16 kHz mono capture path while avoiding regressions to
  dictation hotkey latency.
- Add final transcript UI that can render speaker labels, timestamps, and raw
  fallback text.
- Decide whether live Parakeet EOU preview is worth shipping or whether batch ASR
  should remain authoritative with no live text.

## Build & Run

```sh
cd prototypes/meeting-mode
swift run
```

First run downloads roughly 600 MB of Parakeet v2 assets and roughly 250 MB of
Sortformer assets to FluidAudio's cache directory. Build verification should be
run locally outside this scaffolding step because the sandbox used to create the
prototype does not have package network access.
