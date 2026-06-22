# FluidAudio: other Indian languages + on-device translation (Apple Translation)

Discovery doc, sibling to `backlog.md` (which covered Mandarin / Cantonese /
Vietnamese via Qwen3-ASR). This one answers two follow-ups:

1. **Which OTHER Indian languages** (beyond Hindi) can FluidAudio transcribe?
2. **Can Jot do on-device translation** of transcripts, via Apple's Translation
   framework? Coverage vs Jot's language set + a recommendation.

Date: 2026-06-22. FluidAudio pinned at **v0.14.7** (local checkout under
`~/Library/Developer/Xcode/DerivedData/Jot-*/SourcePackages/checkouts/FluidAudio`);
upstream cross-checked at **v0.15.4** (2026-06-16). No shipping code changed.

Reference enum for any future translation-target mapping:
`/Users/vsriram/code/jot/Sources/Transcription/LanguageChoice.swift`.

---

## Part 1 — Other Indian languages in FluidAudio: **Hindi only, everywhere**

**Bottom line:** No FluidAudio model — Parakeet, Qwen3, Cohere, Canary,
Nemotron, or any other — supports any Indian language beyond **Hindi**. Tamil,
Bengali, Kannada, Telugu, Marathi, Gujarati, Punjabi, Malayalam, Odia,
Assamese, Urdu, etc. are **unsupported** across the entire FluidAudio lineup.

Methodology: grepped every `Language` enum and the `Repo` model registry in the
local v0.14.7 checkout (`grep -rlE "enum Language|supportedLanguages"` →
exactly three config files), then cross-checked upstream GitHub v0.15.4, the
FluidInference HuggingFace org, and authoritative NVIDIA model cards.

### Per-model evidence (the three `Language`-bearing config files)

| Model | HF repo | Indian langs | Source file |
|---|---|---|---|
| **Parakeet TDT 0.6B v3** | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | **None.** Latin/Cyrillic European only (en, es, fr, de, it, pt, ro, pl, cs, sk, sl, hr, bs, ru, uk, be, bg, sr, …). No Indic scripts. | `Shared/TokenLanguageFilter.swift` |
| **Qwen3-ASR 0.6B** (the engine just added) | `FluidInference/qwen3-asr-0.6b-coreml` (`/f32`, `/int8`) | **Hindi (`hi`) only.** 30-case enum; only South-Asian entry is `case hindi = "hi"`. | `ASR/Qwen3/Qwen3AsrConfig.swift` |
| **Cohere Transcribe (03-2026)** | `FluidInference/cohere-transcribe-03-2026-coreml/q8` | **None.** 14 langs: en, fr, de, es, it, pt, nl, pl, el, ar, ja, zh, vi, ko. (No Hindi.) | `ASR/Cohere/CohereAsrConfig.swift` |
| Japanese hybrid | `FluidInference/parakeet-0.6b-ja-coreml` | None (ja only). | `ModelNames.swift` |
| Chinese CTC / Paraformer / SenseVoice | `parakeet-ctc-0.6b-zh-cn`, `paraformer-large-zh`, `sensevoice-small` | None (zh-centric). | repo |

### Newer upstream models (in v0.15.4 / HF, NOT in local v0.14.7) — also Hindi-only at best
- **`Nemotron-3.5-ASR-Streaming-Multilingual-0.6b`** — NVIDIA card
  (`nvidia/nemotron-3.5-asr-streaming-0.6b`): 40 locales, but the only Indian
  language is **Hindi (hi-IN)**. (A secondary blog claiming Tamil/Bengali was
  inaccurate; the model card does not list them.)
- **`canary-1b-v2-coreml`** — NVIDIA Canary-1b-v2 is **25 European languages,
  zero Indian languages** (not even Hindi). Confirmed via NVIDIA
  `supported_languages.py`.

Note: the "Whisper" references in the Qwen3 folder are just the mel-spectrogram
feature extractor (`WhisperMelSpectrogram.swift`), **not** a Whisper ASR model.
No Whisper / Seamless / IndicConformer model exists in FluidAudio.

### What it would take to support more Indian languages
FluidAudio has no Indic-capable model and FluidInference hasn't published one.
You'd need a **different upstream model**, CoreML-converted, integrated as a new
transcriber parallel to `Qwen3Transcriber`:

- **Best fit: AI4Bharat IndicConformer** (`ai4bharat/indic-conformer-600m-multilingual`)
  — Hybrid CTC-RNNT, covers **all 22 official Indian languages**. But it ships
  as **NeMo `.nemo`/PyTorch, not CoreML** → non-trivial conversion + a
  hand-written FluidAudio-style pipeline (preprocessor/encoder/decoder split,
  tokenizer, ANE tuning). Indic quality likely strong (de-facto open Indic
  ASR); on-ANE CoreML quality **Unknown** until converted/measured.
- OpenAI **Whisper large-v3** covers most Indian languages but is heavier and
  also needs CoreML work outside FluidAudio.

**macOS floor:** unchanged. Qwen3 already set the macOS 15+ floor; any new
CoreML ASR model inherits the same floor — none lowers/raises it specifically.

Sources: [canary-1b-v2](https://huggingface.co/nvidia/canary-1b-v2),
[nemotron-3.5-asr-streaming-0.6b](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b),
[FluidInference HF](https://huggingface.co/FluidInference),
[FluidAudio GitHub](https://github.com/FluidInference/FluidAudio),
[AI4Bharat IndicConformer](https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual).

---

## Part 2 — On-device translation via Apple's Translation framework

### Is it on-device? Yes (Confirmed)
`TranslationSession` translates entirely on-device with downloadable ML models.
No network at translation time once packs are installed, no API key, no
telemetry — consistent with Jot's privacy constraints.

### Availability
- **macOS 15.0+** for the programmatic `TranslationSession` / `LanguageAvailability`
  API (framework is broadly 14.4+, but the usable session API is 15.0+). Jot's
  target is already macOS 15 → satisfied.

### Model downloads
- Packs are **not bundled**; download on first use per language pair, OS-managed.
  User can pre-install via System Settings → General → Language & Region →
  Translation Languages. `prepareTranslation()` front-loads the download without
  translating. Downloads continue in background even if the app is dismissed.

### Programmatic / headless feasibility — **THE BLOCKER**
- You **cannot freely construct** a `TranslationSession`. Supported pattern is
  the SwiftUI `.translationTask(...)` modifier, which hands you a session bound
  to a **live on-screen view**; the session "may need to show system UI"
  (download permission/progress sheet) anchored to that view.
- Apple warns: **do not store a `TranslationSession` in a long-lived model**;
  its lifetime is tied to the view.
- For Jot (menu-bar utility, pill overlay, paste-at-cursor, no persistent
  visible window during dictation) this means driving translation from a
  hosted/hidden SwiftUI view that exists at translation time, and the
  **first-use download still surfaces a system sheet** you can't fully suppress
  (pre-warm via `prepareTranslation()`; subsequent calls are silent).
- `LanguageAvailability.status(from:to:)` returns `installed/supported/unsupported`
  **without a view** → availability gating is clean; only the actual
  translate/download path needs the view anchor.
- **Verdict:** headless is *possible* but not *clean*; it fights Jot's
  no-persistent-window architecture plus the unsuppressable first-run sheet.

### Coverage vs Jot's transcription set (Apple covers ~20 langs)
**Covered by Apple (20 of Jot's 27):** English, Japanese, Mandarin/Simplified
Chinese (zh), Vietnamese (vi), Spanish, French, German, Italian, Portuguese,
Russian, Ukrainian, Polish, Czech, Slovak, Dutch, Danish, Finnish, Greek,
Swedish, Romanian.

**NOT covered by Apple (8):**
- **Cantonese (yue)** — Apple has Traditional + Simplified Chinese, no Cantonese.
- **Slovenian (sl)**, **Croatian (hr)**, **Bosnian (bs)**, **Belarusian (be)**,
  **Bulgarian (bg)**, **Serbian (sr)**, **Hungarian (hu)**.

Apple also offers langs Jot doesn't transcribe (Arabic, Korean, Thai, Hindi,
Turkish, Hebrew, Catalan, Malay, Norwegian) — irrelevant unless Jot's source set
grows, though Jot's Qwen3 set advertises ko/th/hi/ar, which would be coverable
as targets.

### Gotchas
- No same-language translation (en-US ↔ en-GB unsupported) — irrelevant here.
- Per-pair model footprint; user must accept downloads (OS-managed disk usage
  Jot can't pre-bundle or fully silence).
- Session is single-shot/short-lived; `translate(batch:)` exists but is still
  view-anchored.

### Alternatives (if Apple's gaps matter)
- **MLX + NLLB-200-distilled-600M**: 200+ langs (covers all 8 Apple gaps incl.
  Cantonese), Apple Silicon ≥16 GB. **License blocker: CC-BY-NC 4.0
  (non-commercial)** → unusable for shipped Jot.
- **CTranslate2** (quantized MT, e.g. Helsinki-NLP/OPUS-MT, madlad400):
  commercially-clear but you bundle/download multi-hundred-MB weights yourself —
  big footprint and integration cost vs Apple's free OS-managed packs.

### Recommendation: **Backlog, not now.**
- When translation ships, **Apple Translation is the right primary engine**:
  free, on-device, OS-managed downloads, no telemetry, 20/27 of Jot's langs —
  aligned with Jot's privacy + Apple-native principles.
- **Two frictions argue against doing it now:** (1) the view-anchored,
  non-headless `TranslationSession` lifecycle mismatches Jot's window-less
  dictation flow (solvable with a hidden SwiftUI host + `prepareTranslation()`
  pre-warm, but it's plumbing), and (2) the unsuppressable first-run download
  sheet. Neither is a dealbreaker; both are work.
- The 8 uncovered langs (esp. **Cantonese**, just added) have **no clean
  commercially-licensed on-device fallback** (NLLB non-commercial;
  CTranslate2/madlad400 heavy). A v1 would be "Apple-covered languages only,"
  those 8 explicitly unsupported for translation.

**Suggested backlog framing:** "On-device translation via Apple Translation
framework (macOS 15+); source languages limited to the 20 Apple-covered ones;
Cantonese + small-Slavic excluded." Worth doing, not urgent; best scoped after
the Qwen3 languages are runtime-verified.

Sources:
[TranslationSession](https://developer.apple.com/documentation/translation/translationsession),
[Translating text within your app](https://developer.apple.com/documentation/Translation/translating-text-within-your-app),
[LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability),
[prepareTranslation()](https://developer.apple.com/documentation/translation/translationsession/preparetranslation()),
[Meet the Translation API — WWDC24](https://developer.apple.com/videos/play/wwdc2024/10117/),
[polpiella.dev Swift Translation API](https://www.polpiella.dev/swift-translation-api/),
[Picovoice open-source translation (2025)](https://picovoice.ai/blog/open-source-translation/),
[OpenNMT/CTranslate2](https://github.com/OpenNMT/CTranslate2).
