# Cohere Transcribe vs. Jot's current ASR models — quick CLI quality benchmark

**Date:** 2026-06-22
**FluidAudio:** v0.14.7 checkout
**Cohere model:** `FluidInference/cohere-transcribe-03-2026-coreml` (q8), `CoherePipeline`,
v2 (ANE-friendly) decoder, `computeUnits: .all`
**Comparison models:** Parakeet TDT 0.6b **v3** (European) and **Qwen3-ASR int8** (Asian/MidEast),
both as Jot ships them today.
**Harness:** `/tmp/jot-fluid-test/harness` — SwiftPM exe depending on the local FluidAudio checkout.

## The big caveat (read this first)

This was run on **clean macOS `say` TTS audio**, one short sentence per language. TTS is
unrealistically clean — no real microphones, accents, disfluency, background noise, or
coarticulation. **This is a sanity signal of "is Cohere broadly better / worse / same on the
languages we already cover," not a WER benchmark.** Real-world WER on these models will be
materially higher than what you see below, and the *relative* ordering can shift with real audio.
Treat exact-match here as "the model handled an easy case," not "the model is this good."

Ground truth = the exact text handed to `say`, so accuracy is judged directly.
Voices used: de `Anna`, fr `Thomas`, es `Paulina`, zh `Tingting`, ko `Yuna`, ja `Kyoko`,
ar `Majed` (the requested `Maged` does not exist on this machine; `Majed`/`ar_001` was used instead).

## Results — side by side

| Lang | Reference (`say` input) | Cohere q8 | Comparison model | Verdict |
|---|---|---|---|---|
| **de** | Herr Schmidt fährt am 15. März um 8 Uhr nach München. | ✅ exact | Parakeet v3 — ✅ exact | **Tie** (both perfect) |
| **fr** | Marie a payé 250 euros pour son billet de train à Bordeaux. | ✅ exact | Parakeet v3 — ✅ exact | **Tie** (both perfect) |
| **es** | El doctor García llegó a Madrid el 3 de octubre a las 9. | ✅ exact | Parakeet v3 — ✅ exact | **Tie** (both perfect) |
| **zh** | 张伟昨天下午三点去北京开了一个重要的会议。 | ✅ exact | Qwen3 int8 — ✅ exact | **Tie** (both perfect) |
| **ja** | 田中さんは来週の月曜日に東京で大切な会議があります。 | ✅ exact | Qwen3 int8 — ✅ exact | **Tie** (both perfect) |
| **ko** | 김민준 씨는 내일 오후 **두 시에** 서울역에서 친구를 만납니다. | 김민준 씨는 내일 오후 **도시의** 서울역에서 친구를 만납니다. | Qwen3 int8 — 김민준 씨는 내일 오후 **도시에서 울력에서** 친구를 만납니다. | **Both wrong; Cohere closer.** Both fail "두 시에" (2 o'clock)→"도시…". Cohere drops one phrase; Qwen3 also corrupts "서울역"→"울력". Cohere's error is smaller. |
| **ar** | ذهب أحمد **إلى** المطار **في الساعة السابعة صباحًا** يوم الإثنين. | ذهب احمد **للمطار** في **ساعه** السابعه **الصباحا** يوم الاثنين | Qwen3 int8 — ذهب أحمد **للمطار** في **ساعة** السابعة **الصباح** يوم الاثنين | **Both wrong; roughly even, edge to Qwen3.** Both rewrite "إلى المطار"→"للمطار" and drop "ال" on الساعة. Cohere additionally **strips diacritics / mangles spelling** (صباحًا→الصباحا, ساعة→ساعه with ه not ة) and drops final punctuation. Qwen3's Arabic spelling is cleaner. |

## Errors in plain terms

- **5 of 7 languages: exact match for both** (de, fr, es, zh, ja). On clean audio, Cohere and the
  current models are indistinguishable for the easy European + zh/ja cases.
- **Korean:** both models miss the time expression "두 시에" (at 2 o'clock). Cohere collapses it to
  "도시의" and otherwise nails the sentence; Qwen3 collapses it to "도시에서" **and** corrupts the
  station name "서울역"→"울력에서". **Cohere is the closer of two imperfect outputs.**
- **Arabic:** both rewrite "إلى المطار" → "للمطار" and drop the definite article on "الساعة". The
  difference is spelling fidelity: **Cohere strips short-vowel diacritics and uses ه where ة is
  correct** (ساعه, الصباحا) and drops the trailing period; Qwen3 keeps proper Arabic orthography
  (ساعة, الصباح). On this clip **Qwen3's Arabic is slightly cleaner.**

## Size & latency

| | Cohere q8 | Parakeet v3 | Qwen3 int8 |
|---|---|---|---|
| **On-disk (files actually loaded)** | **~2.1 GB** (encoder 1.8 GB + v2 decoder 305 MB + vocab) | ~461 MB | ~2.8 GB |
| Full HF download footprint | ~3.0 GB (also pulls redundant `.mlpackage` + v1 decoder) | — | — |
| Cold model load | **~16.7 s** (first-load CoreML/ANE compile of 48-layer encoder) | fast | fast |
| Warm latency / clip (~6–8 s audio) | **~0.7–0.8 s** (one outlier 1.8 s) | **~0.1 s** | **~0.7–2.4 s** |

Latency notes: Cohere is consistently sub-second warm and roughly **on par with Qwen3** for the
Asian/MidEast clips, but ~**7–8× slower than Parakeet v3** for European (v3 is ~0.1 s/clip).
Cohere pads every clip to a fixed 35 s window, so its per-clip cost is flat regardless of how short
the utterance is — that flat ~0.7 s floor will look worse on very short dictations and better on
long ones than these numbers suggest.

## Verdict

**No — Cohere is not worth adopting for the languages Jot already covers, on this evidence.**

- On clean audio it ties the current models on 5/7 languages and there is **no language where Cohere
  is meaningfully better.** Its one "win" (Korean) is just being less wrong on a case both models fail.
- Against **Parakeet v3** (European): Cohere matches accuracy but is **~4.5× larger (2.1 GB vs 461 MB)**
  and **~7–8× slower per clip**. Pure regression on cost for zero accuracy gain.
- Against **Qwen3 int8** (Asian/MidEast): Cohere is **smaller (2.1 GB vs 2.8 GB)** and comparable in
  speed, accuracy a wash — slightly worse Arabic orthography, slightly better Korean. **Not a clear
  enough win to justify shipping a second ~2 GB encoder download** when Qwen3 already covers these.

Where Cohere *might* still be interesting (not tested here): a single model covering all 14 of its
languages could simplify Jot's current two-model (Parakeet + Qwen3) split, and it may behave
differently on **real, noisy** audio — TTS hides exactly the robustness differences that matter.
If revisited, benchmark on real recordings (and ideally with a WER metric), not `say` output.

## Reproduce

```
# audio: macOS `say` -> afconvert -d LEF32@16000 -f WAVE -c 1  (16 kHz mono f32)
# harness: /tmp/jot-fluid-test/harness  (Package.swift -> .package(path: <FluidAudio checkout>))
cd /tmp/jot-fluid-test/harness && swift build -c release && ./.build/release/zhvi
```

Models cache under `~/Library/Application Support/FluidAudio/Models/`. Cohere downloads via
`DownloadUtils.downloadRepo(.cohereTranscribeCoreml, to:)` — note its `vocab.json` lives at the HF
**repo root**, not under `q8/`, while `CoherePipeline.loadVocabulary` expects it in the model dir;
the file had to be copied into `q8/` by hand for loading to succeed.
