# FluidAudio languages backlog: Chinese (Mandarin / Cantonese) + Vietnamese

Discovery doc. Investigates whether Jot can add **Chinese** (the user asked about
**Cantonese**) and **Vietnamese**, what FluidAudio actually ships, an empirical
quality test, the concrete steps to integrate, and a recommendation.

Date: 2026-06-21. FluidAudio pinned at **v0.14.7**
(`Package.resolved`; checkout under
`~/Library/Developer/Xcode/DerivedData/Jot-*/SourcePackages/checkouts/FluidAudio`).
No shipping code was changed by this investigation.

---

## TL;DR / recommendation

- **Yes, all three are feasible**: Mandarin (zh), **Cantonese (yue)**, and
  Vietnamese (vi) — but **not** via the model Jot uses today (Parakeet v3). v3's
  language hint is Latin/Cyrillic only (`TokenLanguageFilter.swift`), so zh/vi/yue
  need a *different* FluidAudio model + a *different* manager class.
- **Cantonese IS available** — contrary to the assumption that NeMo Chinese is
  Mandarin-only. It is supported by **Qwen3-ASR** (`yue`), not by the Parakeet CTC
  zh-CN model (which is Mandarin-only and produced garbage on our Cantonese clip).
- **Empirical quality (Qwen3-ASR int8, macOS `say` TTS test clips):**
  - Mandarin: **character-perfect** incl. punctuation (2/2 clips).
  - Cantonese: **character-perfect** incl. Cantonese-specific chars (哋, 齊);
    only a stylistic end-punctuation difference.
  - Vietnamese: near-perfect — correct diacritics/tones; one initial-consonant
    slip (Trí→Chí) likely a TTS artifact; casing/punctuation lighter than input.
- **Recommendation:**
  - **Backlog, build behind an "Experimental / extra languages" surface** using
    **Qwen3-ASR int8** as the single engine for zh + yue + vi (it also covers
    Korean, Thai, Arabic, Hindi, etc. for free). This is the highest-quality and
    lowest-enum-churn path.
  - **Do NOT** ship the Parakeet CTC zh-CN model — it is Mandarin-only, has no
    punctuation, emits space-separated characters, and gives no Cantonese/Vietnamese.
  - **Effort: medium** (new `Transcribing` conformer + model-download wiring +
    picker entries + macOS-15 gating). **Risk: low-medium**, contained because the
    transcriber factory and `Transcriber` already switch exhaustively on model id —
    a new branch can't silently break the existing v2/v3/JA/Nemotron paths.
  - **One real blocker for "add now":** Qwen3 requires **macOS 15+**
    (`@available(macOS 15, ...)`), and Jot's shipped floor is macOS 14. Either gate
    the feature to macOS 15+ users, or wait for the planned macOS-15 deployment bump
    (already flagged in memory for the AI-search feature). Until then, zh/yue/vi can
    only be offered to macOS-15+ users.

---

## PART A — Capability research

### A.1 How Jot maps languages → models today

- `Sources/Transcription/LanguageChoice.swift` — user-facing language enum.
  `modelID(tier:)` resolves a `LanguageChoice` → `ParakeetModelID`;
  `fluidAudioLanguage` resolves → FluidAudio's v3 `Language` script hint;
  `isSpaceless` flags CJK-style no-space scripts (today only `.japanese`).
- `Sources/Transcription/ParakeetModelID.swift` — every model id maps to a
  FluidAudio batch `AsrModelVersion` via `fluidAudioVersion` (lines 102-116) and a
  cache folder via `repoFolderName` (lines 145-165). **Note:** `.nemotron_en`
  deliberately is *not* an `AsrManager` model and `preconditionFailure`s in
  `fluidAudioVersion` — it routes through a separate streaming manager. This is the
  precedent a zh/yue/vi model would follow.
- `Sources/Transcription/Transcriber.swift` — wraps FluidAudio's `AsrManager`
  (`manager.transcribe(samples, ... language: language?.fluidAudioLanguage)`,
  ~line 212). It already special-cases `.nemotron_en` to use
  `NemotronStreamingTranscriber` instead of `AsrManager` (lines ~56-74). A new
  zh/yue/vi engine would be a sibling special-case.
- `Sources/App/JotComposition.swift` `transcriberFactory` (lines 315-389) — an
  **exhaustive `switch` on `ParakeetModelID`** that builds the right
  `Transcribing` conformer. The compiler forces every new model id to be handled
  here — this is the safety net.
- `Sources/Transcription/ModelCache.swift` / `ModelDownloader.swift` — cache &
  download keyed off `id.repoFolderName` + `id.fluidAudioVersion`, via FluidAudio's
  `AsrModels.download(version:)`. A non-`AsrManager` model (Nemotron, and a future
  Qwen3) uses `streamingPartialCacheURL(for:)` + a dedicated download path instead.

**Confirmed**: a `zh` value exists in FluidAudio's `AsrModelVersion`
(`AsrModels.swift:11` → `case ctcZhCn`), as noted in prior memory. But it's
**Mandarin-only CTC** and loads through `CtcZhCnManager`, not `AsrManager` — see A.2.

### A.2 What FluidAudio v0.14.7 actually ships for zh / yue / vi

FluidAudio is much broader than just Parakeet. There are **four** ASR families.
Three of them can do Chinese and/or Vietnamese:

| Engine | Manager (public API) | zh | yue (Cantonese) | vi | Punctuation | macOS floor | HF repo | On-disk |
|---|---|---|---|---|---|---|---|---|
| **Parakeet CTC zh-CN** | `CtcZhCnManager` (`AsrModelVersion.ctcZhCn`) | ✅ Mandarin | ❌ | ❌ | ❌ (greedy CTC) | 14 | `FluidInference/parakeet-ctc-0.6b-zh-cn-coreml` | ~595 MB (int8 enc) / ~1.1 GB (fp32 enc) |
| **Cohere Transcribe** | `CoherePipeline` | ✅ | ❌ | ✅ | ✅ | 14 (no `@available` guard seen) | `FluidInference/cohere-transcribe-03-2026-coreml/q8` | not downloaded in test |
| **Qwen3-ASR 0.6B** | `Qwen3AsrManager` | ✅ | ✅ `yue` | ✅ | ✅ | **15** (`@available(macOS 15...)`) | `FluidInference/qwen3-asr-0.6b-coreml/{f32,int8}` | int8 ≈ 900 MB–1 GB effective |
| Parakeet v3 (current) | `AsrManager` | ❌ | ❌ | ❌ | ✅ | 14 | `…parakeet-tdt-0.6b-v3-coreml` | (already shipped) |

Sources:
- `AsrModels.swift:5-23` (`AsrModelVersion` cases: `v2, v3, tdtCtc110m, ctcZhCn, tdtJa`).
- `CtcZhCnManager.swift` (Mandarin CTC pipeline; greedy CTC decode, no punctuation;
  `▁`→space replacement only).
- `CohereAsrConfig.swift:92-145` (`Language` enum: en/fr/de/es/it/pt/nl/pl/el/ar/
  **ja/zh/vi/ko** — **14 languages, no Cantonese**).
- `Qwen3AsrConfig.swift:75-141` (`Language` enum: 30 languages incl.
  `chinese="zh"`, **`cantonese="yue"`**, `vietnamese="vi"`, plus the file comment
  "30 languages + 22 Chinese dialects").
- `ModelNames.swift:6-41` (the HF `Repo` slugs above).
- `Qwen3AsrModels.swift:8-20` (`Qwen3AsrVariant`: `.f32` ~1.75 GB / `.int8` ~900 MB,
  "same quality" per the doc comment).

**Mandarin vs Cantonese clarification (the user's question):** the *Parakeet*
Chinese model is Mandarin (zh-CN) only — consistent with the usual NeMo Chinese
assumption. But **Qwen3-ASR explicitly distinguishes Cantonese (`yue`) from
Mandarin (`zh`)** and our test confirms it actually transcribes Cantonese
correctly. So "Cantonese support" = use Qwen3, not Parakeet CTC.

### A.3 What it would take to add zh / yue / vi to Jot

Picking **Qwen3-ASR int8** as the single engine (covers all three, best quality):

1. **`ParakeetModelID`** (`ParakeetModelID.swift`) — add one case, e.g.
   `case qwen3_multilingual`. Like `.nemotron_en` it is **not** an `AsrManager`
   model: make `fluidAudioVersion`/`encoderPrecision` `preconditionFailure`,
   `usesBatchAsrManager == false`, give it a `repoFolderName`
   (`"qwen3-asr-0.6b-int8"`), `approxBytes ≈ 950_000_000`, and add it to the
   relevant `switch`es (the compiler will list them).
   *(The enum is named `ParakeetModelID` but already hosts the non-Parakeet
   Nemotron; one more non-Parakeet engine is consistent with that.)*
2. **`LanguageChoice`** (`LanguageChoice.swift`) — add `.mandarin`, `.cantonese`,
   `.vietnamese` cases: `displayName`, `modelID(tier:)` → the new id,
   `fluidAudioLanguage` (return `nil` — Qwen3 takes its own language string, not
   v3's `Language`), `isSpaceless` (**`true` for mandarin + cantonese**, `false`
   for vietnamese), `fromLanguageCode` (`"zh"`,`"yue"`,`"vi"`), `presentationOrder`.
   Thread the Qwen3 language string ("zh"/"yue"/"vi") through to the new transcriber
   (a small extra property, since `fluidAudioLanguage` is v3-typed).
3. **New `Transcribing` conformer** — e.g. `Qwen3Transcriber` (sibling of
   `NemotronStreamingTranscriber`): wraps `Qwen3AsrManager`, `ensureLoaded()` calls
   `loadModels(from:)`, `transcribe()` calls
   `manager.transcribe(audioSamples:language:)`. Gate the whole type with
   `@available(macOS 15, *)`.
4. **Model download** — add a Qwen3 download path (mirror the Nemotron
   `downloadStreamingBundle` flow in `ModelDownloader.swift`, or call
   `Qwen3AsrModels.download(variant: .int8)`), and a `streamingPartialCacheURL`-style
   cache entry in `ModelCache.swift`.
5. **`JotComposition.transcriberFactory`** (lines 315-389) — add the `case` that
   builds `Qwen3Transcriber`. No live-preview scheduler initially (Qwen3 is batch /
   autoregressive; treat like JA/Nemotron — either no pill preview, or a simple
   batch-pseudo-stream later). `isSpaceless` is already honored by `PreviewScheduler`
   if a preview is added.
6. **Post-processing** — `PostProcessing.swift` already collapses internal
   whitespace and is CJK-aware-ish (the JA path). For Mandarin/Cantonese set
   `isSpaceless = true`; Qwen3 already emits spaceless CJK + punctuation, so little
   work. Vietnamese is space-separated Latin-with-diacritics — the existing Latin
   path applies; only casing/sentence punctuation may want light normalization.
7. **Vocabulary** — the custom-vocabulary gate (CTC-110M spotter / Nemotron-vocab
   work) is English/Latin-oriented. **Disable custom vocab for the Qwen3 path**
   initially (mirror how `.nemotron_en` advertises "doesn't support custom
   vocabulary"). Not a blocker.
8. **macOS 15 gate** — Qwen3 is `@available(macOS 15, *)`. Either:
   (a) hide mandarin/cantonese/vietnamese in the language picker on macOS 14, or
   (b) ride the planned macOS-15 deployment bump (see memory note
   `project_ai_search_macos15` — the AI-search feature already wants macOS 15).
   This is the single hard blocker to "ship to everyone today."
9. **Checklist items from CLAUDE.md** — `docs/features.md`, language-picker copy,
   Help tab prose, About model identity, Settings deep-links, and the
   `HelpInfraTests` anchors if any new info-circle is added.

**Alternative if macOS-14 support is mandatory now:** use **Cohere Transcribe**
(no `@available(15)` guard observed) for zh + vi — but it has **no Cantonese**, so
the user's specific ask (Cantonese) would be unmet. Cohere would also be a second
manager type to maintain. Not recommended over waiting for the macOS-15 bump.

---

## PART B — Empirical CLI quality test

**Method.** Built a tiny SwiftPM harness depending on the local FluidAudio v0.14.7
checkout (`/tmp/jot-fluid-test/harness`). Test audio generated with macOS `say`
(voices: Mandarin **Tingting** `zh_CN`, Cantonese **Sinji** `zh_HK`, Vietnamese
**Linh** `vi_VN`) → `afconvert -d LEF32@16000 -f WAVE -c 1` → loaded via FluidAudio's
`AudioConverter`. Ran two engines: `CtcZhCnManager.load()` and
`Qwen3AsrManager` (int8). Models downloaded to the standard FluidAudio cache
(`~/Library/Application Support/FluidAudio/Models/…`): CTC zh-CN ≈ 595 MB (int8
encoder) and Qwen3 int8 ≈ 900 MB–1 GB. Host: macOS 26.5, Apple Silicon.

> Caveat: `say` TTS is clean, accent-neutral studio audio — real-world WER on noisy
> conversational speech will be worse than these numbers. Treat as a "does the model
> work and is it sane" signal, not a benchmark.

### Results — Qwen3-ASR (int8)

| Clip | Lang | Expected | Got | Verdict |
|---|---|---|---|---|
| zh1 | zh | 你好，今天天气很好，我们一起去公园散步吧。 | 你好，今天天气很好，我们一起去公园散步吧。 | **Perfect** (incl. punctuation) |
| zh2 | zh | 人工智能正在改变我们的生活方式。 | 人工智能正在改变我们的生活方式。 | **Perfect** |
| yue1 | **yue** | 你好，今日天氣好好，我哋一齊去公園散步啦。 | 你好，今日天氣好好，我哋一齊去公園散步啦～ | **Perfect chars** (incl. 哋/齊); end punct `～` vs `。` |
| vi1 | vi | Xin chào, hôm nay trời đẹp, chúng ta cùng đi dạo trong công viên nhé. | xin chào hôm nay trời đẹp chúng ta cùng đi dạo trong công viên nhé | All words/diacritics right; lowercase, no punct |
| vi2 | vi | Trí tuệ nhân tạo đang thay đổi cách chúng ta sống. | Chí tuệ nhân tạo đang thay đổi cách chúng ta sống. | 1 initial-consonant slip (Trí→Chí), else perfect |

Latency: 0.8–5.8 s per clip (first call ~5.8 s ANE warm-up, then ≤1.7 s). Same
single-load-then-hot pattern Jot already uses for Parakeet.

### Results — Parakeet CTC zh-CN (Mandarin only)

| Clip | Got | Verdict |
|---|---|---|
| zh1 | 你 好 ， 今 天 天 气 很 好 ， 我 们 一 起 去 公 园 散 步 吧 。 | Correct chars but **space-separated**; would need `isSpaceless` join |
| zh2 | 人 工 智 能 正 在 改 变 我 们 的 生 活 方 式 。 | Same |
| yue1 (Cantonese through Mandarin model) | 后 雅 听 黑厚 厚 ，莫德亚 才黑 … | **Garbage** — confirms no Cantonese |

**Read:** CTC zh-CN gets Mandarin characters right but is clearly inferior to Qwen3
(spaced output, no real punctuation, zero Cantonese/Vietnamese). Qwen3 is the
obvious choice.

---

## PART C — Effort / risk and final call

- **Add Mandarin + Cantonese + Vietnamese together via Qwen3-ASR int8.** One model,
  one new transcriber, three picker entries. Bonus: the same model unlocks Korean,
  Thai, Arabic, Hindi, Indonesian, Malay, Filipino, Persian, etc. at no extra
  integration cost (all in `Qwen3AsrConfig.Language`).
- **Effort:** medium — new `Transcribing` conformer, download/cache wiring, enum
  cases, picker/Help/About copy. No changes to the existing v2/v3/JA/Nemotron paths.
- **Risk:** low-to-medium. The transcriber factory + `Transcriber` switch
  exhaustively on `ParakeetModelID`, so the compiler enforces handling the new
  case everywhere; the new engine is isolated behind its own conformer.
- **Hard prerequisite:** macOS 15 (Qwen3 `@available`). Recommend bundling this
  with the already-planned macOS-14→15 deployment bump rather than maintaining a
  macOS-14 Cohere fallback (which can't do Cantonese anyway).
- **Why not ship now in this PR:** crosses the macOS-14 promise and needs the full
  feature checklist (features.md, Help, Settings, picker, vocab gating). It is a
  real feature, not a low-risk drop-in — so it is **backlogged**, not implemented
  here.

### Suggested sequencing
1. Land the macOS-15 deployment bump (shared with AI-search).
2. Add `Qwen3Transcriber` + download/cache + one `ParakeetModelID` case.
3. Add `.mandarin` / `.cantonese` / `.vietnamese` to `LanguageChoice` (+ spaceless
   flags) and the factory branch; gate vocab off for this engine.
4. Picker / Help / About / features.md copy; mark "Experimental."
5. Optional later: batch-pseudo-streaming live preview for the pill (reuse
   `PreviewScheduler` with `spaceless` already wired).

---

## Reproduction

- Harness: `/tmp/jot-fluid-test/harness` (SwiftPM, deps on the local FluidAudio
  checkout). `swift build -c release && ./.build/release/zhvi`.
- Test audio: `/tmp/jot-fluid-test/audio/*.wav` (16 kHz mono f32 from `say`).
- These live in `/tmp` and are disposable; not committed.
