# Nemotron 3.5 Multilingual — adopt, bump FluidAudio, retire Qwen

Status: **research validated, decisions locked, integration plan — pre-implementation.** Empirical eval done; a broad/adaptation tier sample is still running. No code changed yet.

## Decisions locked (2026-06-29, user)

- **Fold English into the one Latin Nemotron model** — retire the dedicated English-only Nemotron (keep it only as the <24 GB fallback path).
- **Bump to FluidAudio 0.15.4 and remove Qwen entirely** (not the 0.15.2 "keep both" path — Qwen is not wanted). Accept that <24 GB Macs lose the ex-Qwen non-European languages.
- **Keep Parakeet-v3 as the backup engine** — it stays the home for every language Nemotron can't do (cs/sk/sl/da/nb… proven by the v3 control) and the fallback for all <24 GB Macs. Nemotron is an upgrade *layered on top of* v3, never a full replacement.
- **Drop Thai** (fails Nemotron — empty decode; "no one used it").
- **Add ALL languages Nemotron officially supports** — the 40-locale tiered set below — routed to Nemotron-multilingual on ≥24 GB Macs; the tier drives how we surface each (ship / sample-validate / beta).

### Official Nemotron supported set (40 locales, 3 tiers — authoritative)

- **Transcription-ready (19):** en (US/GB), es (US/ES), fr (FR/CA), it, pt (BR/PT), nl, de, tr, ru, ar, hi, ja, ko, vi, uk — production-quality, ship.
- **Broad-coverage (13):** pl, sv, cs, **nb** (Norwegian Bokmål), da, bg, fi, hr, sk, zh, hu, ro, **et** (Estonian) — usable; sample-validate then ship.
- **Adaptation-ready (8):** el, **lt**, **lv**, **mt** (Maltese), sl, **he** (Hebrew), th, **nn** (Norwegian Nynorsk) — WEAKEST. Thai sits here and returns empty → **treat the whole tier as beta; validate each, expect some to be non-functional.**

**New languages Jot gains** (in the 40, not supported today): Norwegian Bokmål + Nynorsk, Estonian, Lithuanian, Latvian, Maltese, Hebrew.

**Ex-Qwen languages NOT in the official 40 → also dropped** (beyond the trained set, on top of the user-approved Cantonese/Filipino/Macedonian/Thai): **Persian, Indonesian, Malay.** Of the 13 Qwen languages only **6 survive** — Mandarin, Arabic, Korean, Hindi, Vietnamese, Turkish (all in the 40).

## Decision (from the eval)

Adopt **Nemotron 3.5 ASR Streaming Multilingual 0.6B** (FluidAudio CoreML) and retire the experimental Qwen3 path.

- **`latin` variant (38 MB/tier, 2828-vocab, en/es/fr/it/pt/de):** strong. FLEURS WER en 8.96 / es 4.80 / fr 9.52 / it 5.41 / pt 6.14 / de 9.83 (2240ms; FLEURS runs high vs clean dictation — our clean clips were 0% for en/fr/de). **One model replaces Parakeet-v3 (Latin langs) AND the English-only Nemotron** (Latin-model English ≈ English-only on real clips).
- **`multilingual` variant (640 MB/tier, 13087-vocab):** the "~40 trained / ~120 exposed" claim is **NOT uniformly real**. Verified by smoke test:
  - ✅ **WORK** (smoke-tested, correct-script sane output): **Hindi** (8.3% WER), **Mandarin** (0% CER, control), **Arabic** (WER is just dropped optional diacritics), **Korean** (WER is just valid word-spacing variance). Plus benchmarked **ja**.
  - ❌ **FAIL** (empty decode / wrong-script — prompt-id slot exists but language not trained): **Tamil, Bengali, Thai**. Thai is worst — empty even under `auto`.
- **Pattern:** high-resource languages work; the failures are distinct-script low-resource ones. **A prompt-id in metadata ≠ capability — every candidate needs this script-output smoke test.**
- **Confirmed-good set:** Latin-script (benchmarked 6) + Hindi + zh + ja + ar + ko. **Still untested but likely-OK** (Latin script, or Arabic-script like the working Arabic): Vietnamese, Turkish, Indonesian, Malay, Persian.
- **Dropping** (user-approved, were experimental): **Cantonese, Filipino, Macedonian** — not in Nemotron's dictionary at all.

## FluidAudio bump: 0.14.7 → 0.15.4

- Pin in `Jot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (currently v0.14.7, rev 8048812…). Update to 0.15.4.
- **API risk low:** `ASRConfig`, `AsrManager.transcribe`, `AsrModelVersion` unchanged across 0.14.7→0.15.4 (no breaking-change notes). Parakeet v2/v3/JA + English-Nemotron paths port unchanged.
- **Removes:** Qwen3 ASR backend + Parakeet-CTC-zh-CN (both dropped in **0.15.3**) — so the bump *forces* the Qwen retirement.
- **Adds:** `StreamingNemotronMultilingualAsrManager` (0.15.0) + English 2240ms tier (0.15.1).
- **New model API** (validated in the eval harness):
  ```
  let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(languageCode: "es-ES", chunkMs: 2240)
  let m = StreamingNemotronMultilingualAsrManager(); try await m.loadModels(from: dir)
  await m.setLanguage("de-DE")            // per-utterance prompt-id
  _ = try await m.process(samples: float16kHzMono); let text = try await m.finish(); await m.reset()
  ```
  `downloadVariant` routes a latin hint → `latin/`, a non-latin hint → `multilingual/`, and pulls only the requested tier.

## Hardware gate: Nemotron-multilingual on Macs ≥24 GB

`Sources/Transcription/HardwareTier.swift` already has the pieces:
- `nemotronEligible` = ≥M2 Pro AND ≥16 GB (current English-Nemotron run floor).
- `autoUpgradeToNemotronEligible` = ≥M2 Pro AND **≥24 GB** ← the gate the user wants.

**Plan:** add `nemotronMultilingualEligible` = `isAppleSilicon && hasTwentyFourGBOrMore && chipClearsNemotronTier(...)` as **its own member** with a doc comment marking it a **capability gate** (can this Mac run the 640 MB multilingual model), distinct from `autoUpgradeToNemotronEligible`, which is an **auto-swap policy gate** (should we silently swap an unsuspecting English user). They are numerically equal today (both 24 GB) but mean different things — do **not** reuse `autoUpgradeToNemotronEligible` for capability decisions (review MAJOR-1); a future change to auto-swap headroom must not silently move the capability wall. Every capability/migration site references `nemotronMultilingualEligible`.

> ⚠️ The 24 GB floor is a **conservative ship bar, not a measured one.** It was chosen for unsolicited-auto-swap headroom on the *English* Nemotron; we have **no eval of the heavier 640 MB multilingual model's real-time throughput on a 16–24 GB Mac.** Ship at 24 GB; a later RTF probe can lower it per-tier. Note this in the `nemotronMultilingualEligible` doc comment so the number isn't mistaken for a benchmarked threshold.

**Fallback for <24 GB Macs:** Latin langs + English fall back to today's models — **Parakeet-v3 for es/fr/it/pt/de**, **Parakeet-v2 for English** (exactly the current non-Nemotron path). No regression for those.

## Routing changes — `LanguageChoice.modelID(tier:)` (`Sources/Transcription/LanguageChoice.swift:171`)

After the change:
```
english + {es,fr,it,pt,de}:  nemotronMultilingualEligible ? .nemotron_multilingual : (english ? .v2_en : .v3_eou)
surviving Qwen langs (zh/ar/ko/hi/vi/tr): nemotronMultilingualEligible ? .nemotron_multilingual : (hidden in picker; existing users fall back to English + notice — §3)
japanese:                    .tdt_0_6b_ja (unchanged)
other European (ro/pl/cs/.../ru/uk/.../da/nl/...): .tdt_0_6b_v3_eou_streaming (unchanged — v3 keeps these)
```
- The per-language **prompt-id** (`setLanguage("es-ES")` etc.) replaces `fluidAudioLanguage` for the Nemotron path; keep `fluidAudioLanguage` for the v3 fallback path.
- Delete `qwen3Language` — but `isExperimental` is **derived from it** (`LanguageChoice.swift:165`: `qwen3Language != nil`) and drives the picker beta badge (`LanguagePickerField.swift:111`). Replace it with a fresh `isBeta` source listing the unvalidated Nemotron languages (review MINOR-2) — the new languages want a beta badge anyway. Delete the property only together with its replacement, never alone.

## Qwen removal — full site list (delete)

- `Sources/Transcription/Qwen3Transcriber.swift` (whole file).
- `ParakeetModelID.swift` — `.qwen3_multilingual` case + its `displayName`/`approxBytes`/etc. branches (`:60,77,79,…`).
- `LanguageChoice.swift` — re-point the `modelID` switch arm at `:377-386` off `.qwen3_multilingual`. **Delete ONLY the 7 dropped-language enum cases** (yue/fa/th/id/ms/fil/mk); **keep the 6 surviving cases** (zh/ar/ko/hi/vi/tr) and re-route them to `.nemotron_multilingual` (≥24 GB) / hidden (<24 GB). Deleting a case makes its stored `jot.transcriptionLanguage` rawValue undecodable — see the retirement migration (§3), which must run **before** any case is removed in a shipped build.
- `ModelDownloader.swift` — `downloadQwen3` (the custom staging path, ~`:304-374`).
- `ModelCache.swift` — `.qwen3_multilingual` cache cases (`:174-176`).
- `PostProcessing.swift:30`, `ModelChoiceMigration.swift:92-94` — Qwen branches.
- The transcriber factory branch that builds `Qwen3Transcriber` (in `TranscriberHolder.transcriberFactory` — referenced from `ModelDownloader.swift:47`).
- Migration: add a `ModelChoiceMigration` rule mapping a stored `.qwen3_multilingual` → the new model (or to a sensible per-language default) so existing Qwen users don't dangle.

## New model wiring (mirror the existing Nemotron-en path)

- `ParakeetModelID` — add `.nemotron_multilingual` (+ displayName/size/streaming flags). The existing `.nemotron_en` is the template.
- `ModelCache` — cache path for the latin (and optionally multilingual) bundle under `~/Library/Application Support/Jot/Models/Parakeet/nemotron-multilingual/<tier>/`.
- `ModelDownloader` — route to `StreamingNemotronMultilingualAsrManager.downloadVariant`.
- **Transcriber factory / `DualPipelineTranscriber`** (`Sources/Transcription/DualPipelineTranscriber.swift`) — the new model is a streaming manager like Nemotron-en, so it slots into the same `.nemotron` engine arm; wrap `StreamingNemotronMultilingualAsrManager` in a transcriber conforming to the streaming path, and thread the per-language `setLanguage` hint.
- Vocabulary/CTC spotter: the CTC-110m spotter is Latin/English-oriented — keep it for the Latin path; it won't help (and shouldn't run for) non-Latin languages.

## Language disposition after the change

Routing principle: **≥24 GB + ≥M2 Pro → Nemotron-multilingual for all 40 locales; otherwise fall back per language.**

| Bucket | Languages | <24 GB fallback |
|---|---|---|
| Has a Parakeet path | en (→v2), es/fr/it/pt/de + ro/pl/cs/sk/sl/hr/bs/ru/uk/be/bg/sr/da/nl/fi/el/hu/sv (→v3) | yes — Parakeet v2/v3 |
| Japanese | ja | yes — tdt_0_6b_ja |
| **Nemotron-only (≥24 GB required)** | ar, ko, hi, vi, tr, zh + NEW: he, nb, nn, et, lt, lv, mt | **none — hide/disable on <24 GB** |
| **Dropped** | th (fails), yue, fil, mk, fa, id, ms (not in the official 40) | — |

On a <24 GB Mac the Nemotron-only languages have no backend → the language picker must **hide them or show them disabled with a "requires 24 GB" note.**

## Decisions resolved
1. English → folded into the Latin model (English-only Nemotron kept only as the <24 GB fallback). ✓
2. <24 GB loses the Nemotron-only languages → accepted. ✓
3. Thai → dropped. ✓

## Remaining validation (non-blocking)
- Broad-coverage + adaptation-ready tier sample (running) — drop any adaptation-ready locale that returns empty, Thai-style.
- Smoke-test the last two surviving Qwen langs not yet run: **vi, tr** (both transcription-ready, so expected to work).

## User transition / migration (how existing users move to the new model)

Build on the proven launch-migration pattern (`Sources/Transcription/NemotronAutoUpgradeMigration.swift` + `ModelChoiceMigration.swift`). The golden rule it already enforces: **never uninstall the active model — set a one-shot *pending* marker, download the new model in the background, and flip the active model ONLY after the download fully succeeds.** The user keeps dictating on their current model the whole time; the swap resolves at recording start, never mid-session.

**1. The bump itself.** Edit `Package.resolved` → FluidAudio 0.15.4; build; confirm the Parakeet v2/v3/JA + Nemotron-en paths still compile (APIs stable). This is the only "code upgrade" step.

**Migration ordering (corrected):** `QwenRetirementMigration` (§3) runs **first — before `LanguageMigration` and before `TranscriberHolder` is constructed** — so dropped/surviving languages are reclassified off the raw string while the enum still has nothing to coerce them to, and the corrected `jot.transcriptionLanguage` then seeds `activeLanguage`. `NemotronMultilingualMigration` (this step) runs after `LanguageMigration`.

**2. New `NemotronMultilingualMigration` (mirror `NemotronAutoUpgradeMigration`).** One-shot, runs in `JotComposition.build` AFTER `LanguageMigration` (which seeds `jot.transcriptionLanguage`). Gate (all must hold):
- `HardwareTier.nemotronMultilingualEligible` (≥24 GB + ≥M2 Pro — the capability gate, NOT `autoUpgradeToNemotronEligible`);
- active language is in the **Nemotron-verified set** (NOT cs/sk/sl/da/nb/etc.);
- stored `jot.defaultModelID` ≠ `.nemotron_multilingual`.
→ set `jot.nemotron.multilingualUpgradePending = true` (never writes `jot.defaultModelID`). `TranscriberHolder.startPendingNemotronMultilingualUpgradeIfNeeded()` downloads the bundle (latin 38 MB / multilingual 640 MB per language) with the existing progress banner, then flips the active model on success; retries across launches on failure (pending marker cleared only on success).
- This **supersedes** today's `NemotronAutoUpgradeMigration` (English → nemotron_en): existing English users on ≥24 GB now upgrade to the multilingual model instead (one model). 16–24 GB English users keep `nemotron_en`; <16 GB keep v2.

**3. Qwen retirement migration (the tricky one — corrected per review CRITICAL-1/2).**

The original draft reasoned about the stored **model ID** (`jot.defaultModelID`). That is the wrong key: after the already-shipped `LanguageMigration`, routing is computed **from the language** (`LanguageChoice.modelID(tier:)`, `LanguageChoice.swift:171`), and `TranscriberHolder.init` resolves the active language from `jot.transcriptionLanguage` (`TranscriberHolder.swift:138-140`). So the failure mode is an undecodable **language**, not an undecodable model:

> A stored `jot.transcriptionLanguage = "cantonese"` (or any dropped case) → `LanguageChoice.init(rawValue:)` returns `nil` → falls to `fromStoredModelID(stored)`; the stored Qwen model ID *also* no longer decodes → `.tdt_0_6b_v3_eou_streaming` → `fromStoredModelID` → `.english`. Result: a **silent reset to English with no notice** — and the draft's notices were therefore *unreachable*, because the coercion happens at `init` before any model-ID migration can see what the user originally had. This even hits *surviving* languages (a Korean user lands on English silently).

**Corrected design — a standalone `QwenRetirementMigration` that runs FIRST**, before `LanguageMigration` *and* before `TranscriberHolder` is constructed (so the corrected keys seed `activeLanguage` directly). It reads the **raw** `jot.transcriptionLanguage` string and matches it against a **hardcoded literal map** — the enum cases are about to be removed, so we cannot use `LanguageChoice(rawValue:)` to classify them:

```
let retiredLangs: [String: Disposition] = [
  // dropped — no backend in the official 40
  "cantonese": .dropped, "persian": .dropped, "thai": .dropped,
  "indonesian": .dropped, "malay": .dropped, "filipino": .dropped, "macedonian": .dropped,
  // surviving — Nemotron-multilingual on ≥24 GB, else fall back + notice
  "mandarin": .surviving, "arabic": .surviving, "korean": .surviving,
  "hindi": .surviving, "vietnamese": .surviving, "turkish": .surviving,
]
let raw = defaults.string(forKey: TranscriberHolder.languageKey)   // literal, NOT enum
```
- **.dropped** → set language to `.english` (or system-locale match), set one-shot `jot.qwenRetirement.notice = "retired:<lang>"`.
- **.surviving + `nemotronMultilingualEligible`** → keep the language (rewrite its rawValue; surviving enum cases are NOT deleted), set `jot.nemotron.multilingualUpgradePending = true` to queue the download.
- **.surviving + <24 GB** → set language to `.english`, set `jot.qwenRetirement.notice = "needs24GB:<lang>"`.
- In the same pass, rewrite a dead `jot.defaultModelID == "qwen3_multilingual"` to a decodable value (`.tdt_0_6b_v3_eou_streaming` or the resolved target) so nothing dangles.
- Stamp `jot.qwenRetirementMigrated`; early-exit thereafter.
Surface `jot.qwenRetirement.notice` once via the existing migration-banner / toast, then clear it. **Only ship the enum-case deletions in a build that already carries this migration** (the literal map is what bridges the gap).

**3a. No-working-model window for surviving-Qwen users (review MAJOR-2 — the real "no model" hole).** A surviving-Qwen user on ≥24 GB (e.g. Korean) is standing on the Qwen bundle, which **FluidAudio 0.15.4 can no longer load** — and `installedFallbackModel(for:excluding:)` returns `[]` for these languages (`TranscriberHolder.swift:692-696`, *"Only the Qwen3 bundle serves these; no Parakeet fallback exists"*). So from new-build first launch until the 640 MB multilingual download flips, Korean has a dead active model **and** no same-language Parakeet fallback → cannot transcribe at all. "Never uninstall the active model" is true but moot: the active model is *uninstalled-in-effect* the moment the SDK can't load it.

> **Why the obvious fix does NOT work (verified, round 2).** The Phase-5 transient fallback in `resolveSessionTranscriber` (`TranscriberHolder.swift:635-663`) cannot be naively extended: it is **gated on `repairState != nil`** (`:637`, returns `.active` otherwise), and the only thing that sets `repairState` — `beginSelfHeal` via the launch probe — **early-returns while an upgrade download is pending** (`:478-481` defers self-heal when `fourOptionDownloadPendingKey`/`autoUpgradePendingKey` is set; our new `multilingualUpgradePending` is a sibling marker). So for exactly this user `repairState` stays nil, `resolveSessionTranscriber` returns `.active` = the dead Qwen transcriber, and even if it did run, `installedFallbackModel(for: .korean)` returns `[]`. The repair machinery is the wrong lever.

**Corrected fix — a proactive cross-language flag, read ahead of the repair gate:**
- `QwenRetirementMigration` sets `jot.qwen.pendingCrossLanguageFallback = true` for a surviving-Qwen user whose active model is the now-dead Qwen bundle with a pending multilingual download.
- `resolveSessionTranscriber` reads this flag **at the very top, before the `:637` `repairState` guard**. When set:
  - Pick the **best installed English model explicitly** (`.tdt_0_6b_v2_en` / `.tdt_0_6b_v3_eou_streaming`) — do NOT route through the language-gated `installedFallbackModel` (it returns `[]` for Korean). Load it, return `.transient(englishModel, notice: "Transcribing in English until the <language> model finishes downloading")`.
  - **If no English bundle is cached** (a Korean-only user may never have downloaded one — `installedFallbackModel`/`ModelCache` can't conjure one), return `.blocked` with a *download-progress* notice ("Downloading <language> model — N MB left"), NOT a false promise of English. The persistent repairing/downloading pill covers this.
- Clear the flag when the multilingual flip succeeds (alongside clearing `multilingualUpgradePending`).
- This is gated to exactly the pending-Qwen-migration window — not a general behavior change.

**4. Disk cleanup — deferred (review MAJOR-2).** Remove the orphaned Qwen bundle (`~/Library/Application Support/Jot/Models/Parakeet/qwen3-asr-0.6b-int8/`, ~950 MB) — mirror `ModelCache.removeOrphanedEouBundle` — but **never while a surviving-Qwen user's multilingual download is still pending.** Gate deletion on `!defaults.bool(forKey: multilingualUpgradePendingKey)` (same deferral discipline already at `TranscriberHolder.swift:339-341, 478-480`). For a dropped-Qwen user (no pending download) it's safe immediately. This avoids deleting the bundle (and any chance of a future resume) before the replacement is in place.

**5. Idempotency + safety.** Every migration stamps a `…Migrated` sentinel and exits early on later launches (so a user who manually changes their model post-migration isn't re-flagged) — same discipline as the existing migrations. Download-then-flip means no active model is *deleted*; §3a covers the case where the active model is *unloadable* (dead Qwen) so the user is never left with nothing.

**Migration test matrix (must verify — expanded per review §4):**
1. **Fresh install** — defaults to the right model per tier.
2. **English user 16 / 24 / 32 GB** — 16 keeps `nemotron_en` (no code change, `modelID` English arm gates on 16 GB `nemotronEligible`, `LanguageChoice.swift:173-177`); 24/32 upgrade to multilingual.
3. **es/fr Latin user 16 / 24 GB** — v3 (16) / multilingual (24).
4. **Undecodable-language boot (CRITICAL-1):** seed `jot.transcriptionLanguage = "cantonese"` / `"thai"` / `"korean"` with the case removed → assert the *intended* disposition **and the notice fires**, NOT a silent English reset. (This is the test that catches the core gap.)
5. **Surviving-Qwen ≥24 GB, kill app mid-640 MB download + relaunch (MAJOR-2):** assert (a) the user can still dictate via the English transient fallback, (b) download restarts cleanly (no resume in v1 — `isCached` is presence-only), (c) Qwen bundle is NOT deleted until the flip succeeds.
6. **Surviving-Qwen <24 GB (Korean on 16 GB):** assert fallback-to-English + "needs 24 GB" notice, and that the dead Qwen bundle on disk doesn't break boot.
7. **Dropped-Qwen user (Cantonese):** language reset + "retired" notice; bundle removed.
8. **Disk-full during multilingual download:** pending marker stays set, fallback model still works, retry next launch.
9. **Picker rendering (MINOR-2):** dropped languages absent from `presentationOrder`; surviving-but-gated language (Korean on 16 GB) explicitly filtered/disabled-with-note (the picker enumerates `allCases`, `LanguagePickerField.swift:28`, so removed cases auto-disappear but gated ones must be filtered); beta badge still resolves after `qwen3Language` deletion.
10. **FluidAudio 0.15.4 API-stability is a GATING build step**, not an assertion: compile-check the Parakeet v2/v3/JA + `nemotron_en` paths against 0.15.4 before anything else (Qwen's removal in 0.15.3 proves the SDK drops symbols between minors).
11. **Surviving-Qwen ≥24 GB with NO English/Parakeet bundle on disk (review round 2):** the §3a cross-language fallback has nothing to fall back to → assert a graceful "Downloading <language> model — N MB left" state with the persistent pill, NOT a crash, a dead pill, or a false "transcribing in English" promise.
12. **Already-migrated precondition (review round 2 — the COMMON real-world state):** existing Qwen users already ran `LanguageMigration` on their old build, so `migratedKey` is set and `jot.transcriptionLanguage` is already `"korean"`. Assert `QwenRetirementMigration` reclassifies off that **already-seeded raw string** and does NOT depend on `LanguageMigration` re-running this launch. Split the surviving-Qwen case into ≥24 GB (keep + pending download) and <24 GB (English + "needs 24 GB" notice) so both dispositions are exercised through a real boot.

## Validation results (smoke tests + v3 control)

- **Nemotron VERIFIED-works:** en/es/fr/it/pt/de + zh/hi/ar/ko + sv/hr/pl/ro/fi/hu (broad) + el/he (adaptation) + ja(benchmarked). Transcription-ready tier (19) trusted per user, untested.
- **Nemotron FAILS — real gap (v3 control proved clips good, v3 transcribes them):** **cs, sk, sl, da, nb** → **stay on Parakeet-v3** (routing to Nemotron = regression). ta/bn/th also fail (no fallback → dropped).
- **Untested (no macOS TTS voice):** bg, et (broad); lt, lv, mt, nn (adaptation) → **keep on Parakeet-v3** (v3's `Language` set already covers bg/et/lt/lv/mt; Norwegian works via v3 auto-detect). No download/test needed to ship — testing on Nemotron would only reveal a possible *upgrade*, which we can revisit later per-language with one real clip.
- **Confirmed:** tier labels + prompt-id slots do NOT predict capability — every language needs an individual script smoke-test before routing.

## Checklist touchpoints
- `docs/features.md` (language list changes), `docs/hardware-capability-matrix/design.md` (the new ≥24 GB gate), CLAUDE.md (model line: Parakeet TDT v3 → + Nemotron-multilingual).
- Settings → Transcription language picker (remove dropped langs; filter gated surviving langs on <24 GB; replace `isExperimental`→`isBeta` source; mark beta where unvalidated).
- `QwenRetirementMigration` (new, runs first — §3) + deferred Qwen disk cleanup (§4); supersedes the old "`ModelChoiceMigration` for stored `.qwen3_multilingual`" note.
- `HardwareTier.nemotronMultilingualEligible` as a distinct capability gate (§ Hardware gate); Phase-5 cross-language English fallback for the pending-Qwen window (§3a).
- Re-run `help-content.md` budget if language copy changes.
</content>
