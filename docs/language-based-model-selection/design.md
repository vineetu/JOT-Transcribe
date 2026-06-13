# Language-based model selection

**Status:** design / implementation source of truth. 2026-06-13.
**Owner-driven goal:** Replace the user-facing *model* selector with a *language*
selector everywhere a user encounters it (first-run Setup Wizard model step +
Settings → Transcription). Users pick a language; Jot picks the model + the
recognizer language hint automatically. Model identity is surfaced only in
Acknowledgements/About, never as the primary control.

> **Confidence protocol note.** Every code claim below is cited `file:line`.
> Findings are tagged **Confirmed** (read directly), **Likely** (inferred from
> strong evidence), or **Unknown**. The single most important finding (the
> FluidAudio language API) **reversed a first-pass research conclusion** — read
> §2 carefully, it changes the shape of the whole feature.

---

## 0. TL;DR for a reviewer (attack these hardest)

1. **The user's technical premise is *mostly* right, but the mechanism is
   coarser than assumed.** FluidAudio **0.14.7** (the pinned version) *does*
   expose a `language:` hint on every Parakeet TDT `transcribe(...)` overload —
   but it is **script-aware token filtering only** (Latin vs Cyrillic), not
   per-language conditioning, and it covers **19 languages, not 25**. Parakeet
   v3 the *model* claims 25 European languages; the SDK *hint* enum exposes 19.
   See §2. **This gap is the #1 thing to validate.**
2. **English is a model fork; the European languages share one model.** Per
   product-owner decision, **English → Parakeet v2** (best English accuracy),
   **European languages → v3** (same v3 weights, differentiated only by the
   `language:` script hint), **Japanese → `.tdtJa`**. So the map is: one shared
   v3 model for the European set, plus two single-language forks (v2 for English,
   JA for Japanese). Nemotron stays an optional, hardware-gated, Advanced-only
   English engine — never in the language picker. See §3.
3. **Jot passes `nil` for the hint today** (`Transcriber.swift:157`). Shipping
   the language hint is itself a behavior change independent of the UX.
4. **Migration must not clobber v1.4+ stored model choices.** The codebase
   already has a heavily-precedented one-shot migration pattern
   (`ModelChoiceMigration`) and a single source of truth holder
   (`TranscriberHolder`). We extend, not replace. See §6.
5. **Hardware tier policy is resolved by the matrix doc.** v2 (English) and v3
   (European) are both 0.6B batch models that run on **every** Mac — no gating.
   The only gated model is the heavy streaming **Nemotron**, offered solely on
   chip ≥ M2 Pro AND ≥ 16 GB (`docs/hardware-capability-matrix/design.md:198,206`)
   and only via the Advanced surface. So the language picker is **tier-agnostic
   and never selects Nemotron**. See §7.

---

## 1. Current state (Confirmed, with citations)

### 1.1 The model identity layer

`Sources/Transcription/ParakeetModelID.swift` is the enum that identifies every
model Jot knows how to download/cache/load/render. **Confirmed.**

- 7 cases total; only 4 are user-visible via `visibleCases`
  (`ParakeetModelID.swift:277-284`): `.tdt_0_6b_v3_eou_streaming`,
  `.tdt_0_6b_ja`, `.tdt_0_6b_v2_en_streaming` (deprecated), `.nemotron_en`.
- The hidden cases (`.tdt_0_6b_v3`, `.tdt_0_6b_v3_int4`,
  `.tdt_0_6b_v3_nemotron_streaming`) are migration/rollback anchors only
  (`isUserSelectable` false, `ParakeetModelID.swift:195-205`).
- `fluidAudioVersion` maps each case to a FluidAudio `AsrModelVersion`
  (`ParakeetModelID.swift:95-109`): the v3 family → `.v3`, `.tdt_0_6b_ja` →
  `.tdtJa`, `.tdt_0_6b_v2_en_streaming` → `.v2`. `.nemotron_en` is *not* an
  `AsrManager` model (precondition failure, `:107`).
- `isRecommended` is **true only for `.nemotron_en`** (`:262-274`), even though
  the technical fresh-install default is `.tdt_0_6b_v3_eou_streaming`. This
  asymmetry is documented at `:250-261` and is exactly the kind of confusing
  "recommended-but-not-default" wart the user wants gone. **Confirmed.**

### 1.2 The single source of truth: `TranscriberHolder`

`Sources/Transcription/TranscriberHolder.swift` — `@MainActor ObservableObject`,
the one owner of "which model is active." **Confirmed.**

- Stored key: `static let defaultsKey = "jot.defaultModelID"`
  (`TranscriberHolder.swift:42`).
- Boot default for an absent key: `.tdt_0_6b_v3_eou_streaming`
  (`TranscriberHolder.swift:54-57`).
- `setPrimary(_:)` swaps the transcriber and **persists to the legacy
  `jot.defaultModelID` key** so existing users' selection survives
  (`:71-78`). This is the precedent we mirror for migration.
- `installedModelIDs` is computed by scanning `allCases` against `ModelCache`
  (`:146-148`).
- `migrationDownloadProgress` / `startPendingMigrationDownloadIfNeeded()`
  (`:91-144`) already implement "after a migration sets a new model, download it
  with a progress banner." We reuse this path verbatim.

### 1.3 Setup Wizard model step

`Sources/SetupWizard/Steps/ModelStep.swift`. **Confirmed.** (Step `.model` is
index 2 in `WizardStepID`, between `.permissions` and `.microphone` —
`WizardStep.swift:6-42`.)

- Renders a single hardcoded "recommended" model (`.nemotron_en`,
  `ModelStep.swift:42`) plus a hand-rolled "Show N more options" disclosure over
  `visibleCases` minus the recommendation (`:48-50`, `:98-124`).
- "Recommended" badge per row via `RecommendedBadge()` (`:338-340`).
- Download: `onDownload` → `holder.setPrimary(model)` then `startDownload(for:)`
  (`:68-71`); `startDownload` constructs `ModelDownloader()` and calls
  `downloadIfMissing(model) { fraction in … downloadProgress = fraction }`
  (`:275-311`).
- **Progress UX = a `ProgressView(value:)` + a `Text("\(Int(p*100))%")`
  monospaced percentage** (`:398-405`). This is the percentage the user
  references.
- Selection persists via `holder.setPrimary` → `jot.defaultModelID` (no
  `@AppStorage` in the view). On appear, if `jot.defaultModelID` is **absent**,
  the step writes `.nemotron_en` into the key (`:149-151`) — i.e. reaching this
  step silently flips a fresh user from the EOU multilingual boot default to
  English-only Nemotron. **Confirmed** — and another wart the redesign removes.
- Holder is consumed via `@EnvironmentObject` (`:10-11`), built once in
  `JotComposition.build` and injected into both the wizard coordinator
  (`SetupWizardCoordinator.swift:38-39`) and the SwiftUI environment.
- `.model` advance precondition: `installedModelIDs.contains(primaryModelID)`
  (`SetupWizardCoordinator.swift:124-125`).
- A secondary optional "vocabulary boost (CTC 110M)" bundle section exists
  (`ModelStep.swift:175-225`) and is non-blocking for Continue.

### 1.4 Settings → Transcription model picker

`Sources/Settings/TranscriptionPane.swift` (466 lines, read in full).
**Confirmed.**

- Custom radio list, not a `Picker`. Default-collapsed: only the primary row
  shows; the rest sit behind a `DisclosureGroup` "Show other models"
  (`TranscriptionPane.swift:39-61`), state in
  `@AppStorage("jot.settings.transcription.otherModelsExpanded")` (`:13-14`).
- Each row: radio (`setPrimary`, `:221-230`), display name, badges
  (`:236-244`), install-state + footprint subtitle (`:246`, `:304-323`),
  `detailText` (`:249-254`), trailing Download/Delete/progress%
  (`:275-302`).
- Selection read from `holder.primaryModelID`; written via
  `await holder.setPrimary(model)` (`:222`). No `jot.defaultModelID`
  `@AppStorage` in this file.
- **`info.circle` popovers** via `InfoPopoverButton` exist only on the
  paste/auto-Enter/clipboard toggles, all deep-linking to Help anchor
  `"dictation"` (`:85-89`, `:96-100`, `:118-122`). The **model rows have no
  info.circle popover today** — they use `.help(…)` tooltips + inline detail
  text. We will add a language-control popover (see §5.3).
- `InfoPopoverButton` (`Sources/Settings/InfoPopoverButton.swift`): the Help
  deep-link is a raw `String` anchor (no enum), posted via
  `NotificationCenter` name `"jot.help.scrollToAnchor"` after
  `setSidebarSelection(.help)` (`InfoPopoverButton.swift:23`, `:65-87`, `:97`).
- Advanced gate already present: the paste/clipboard block is hidden unless
  `@AppStorage(AdvancedFlag.storageKey)` is on (`:20-21`, `:79-129`).

### 1.5 How the recognizer is called today — the load-bearing finding

`Sources/Transcription/Transcriber.swift:137-243`,
`transcribeWithAsrManager(_:manager:)`. **Confirmed.**

```swift
var decoderState = TdtDecoderState.make(
    decoderLayers: modelID.fluidAudioVersion.decoderLayers
)
result = try await manager.transcribe(samples, decoderState: &decoderState)  // :157
```

The inline comment at `:150-153` says: *"Language hint is intentionally unused:
it's silently ignored for tdtJa … and Jot doesn't surface a per-call language
switch for v3 either."*

**So Jot currently passes no `language:` argument.** Whatever language hint
FluidAudio supports is dormant. Wiring it is part of this feature, not a free
side effect.

### 1.6 Model download + cache

- `Sources/Transcription/ModelDownloader.swift`: `public actor`, one entry
  `downloadIfMissing(_ id: ParakeetModelID, progress: @Sendable @escaping
  (Double) -> Void) async throws` (`ModelDownloader.swift:61-64`). Closure-based
  fractional progress in `[0,1]`. Per-variant branching at `:76-82`. **Confirmed.**
- `Sources/Transcription/ModelCache.swift`: `isCached(_:)` (`:103-112`),
  on-disk root `~/Library/Application Support/Jot/Models/Parakeet`
  (`:19-29`). v3 / v3_eou share the `parakeet-tdt-0.6b-v3-coreml` folder
  (`ParakeetModelID.swift:138-143`); JA → `parakeet-ja` (`:152`). **Confirmed.**

### 1.7 Advanced flag (already exists — do NOT re-invent)

`Sources/App/AdvancedFlag.swift`. **Confirmed.**

- `static let storageKey = "jot.advanced.enabled"` (`AdvancedFlag.swift:24`),
  `migratedKey = "jot.advanced.migrated"` (`:25`).
- **Default is asymmetric**, not a flat `false`: `migrateIfNeeded()` seeds the
  flag from `jot.setupComplete` — **existing users → ON**, **fresh installs →
  OFF** (`:28-34`). The prompt says "advanced DEFAULT FALSE"; the *fresh-install*
  default is already false, but existing users already have it ON. See §4 for
  how we handle that.

---

## 2. The authoritative language API (Confirmed against the pinned version)

**Pinned dependency:** FluidAudio **0.14.7**, revision
`8048812869b0c7c6fa393e564a4fb6f95126ba23`
(`Jot.xcodeproj/.../swiftpm/Package.resolved`). **Confirmed.** *(Code comments
in the repo still reference 0.13.7 — they're stale; the resolved pin is 0.14.7.)*

### 2.1 FluidAudio DOES expose a language hint (corrects an earlier draft finding)

In **0.14.7**, every Parakeet TDT `transcribe` overload takes
`language: Language? = nil`. Verified by reading the tagged source
(`Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift:357-490`):

```swift
public func transcribe(_ audioSamples: [Float],
                       decoderState: inout TdtDecoderState,
                       language: Language? = nil) async throws -> ASRResult   // :482
```

(Same `language:` param on the `AVAudioPCMBuffer`, `URL`, and `transcribeDiskBacked`
overloads, `:357`, `:381`, `:414`.) **Confirmed.**

The doc-comment is explicit about what it does:
> *"Optional language hint for script-aware token filtering (v3 only). When set,
> top-K tokens that don't match the language's script are skipped in favor of
> matching candidates. Silently ignored for v2 / tdtCtc110m / tdtJa."*

### 2.2 What the hint actually does — and its limits

`Sources/FluidAudio/Shared/TokenLanguageFilter.swift` (read in full).
**Confirmed.**

- The hint is the public `enum Language: String, CaseIterable` with **19 cases**
  (`TokenLanguageFilter.swift:4-23`): `en, es, fr, de, it, pt, ro, pl, cs, sk,
  sl, hr, bs, ru, uk, be, bg, sr`.
- Each maps to a `Script` of `.latin` or `.cyrillic` (`:25-34`).
- The filter (`TokenLanguageFilter.filterTopK`, `:108-160`) only does
  **Latin-vs-Cyrillic** partitioning of decoder top-K candidates. It is *not*
  per-language (Polish vs Czech are identical at the filter level) — the code
  comment at `:46-50` explicitly notes a per-language allowlist "could plug in
  here later." Issue #512 motivation: stop the v3 joint network emitting
  Cyrillic while transcribing Polish.

**Implication:** the hint's real signal is binary — *"this language is written in
Latin script"* vs *"…Cyrillic script."* Picking Polish vs Czech is, today,
indistinguishable to the recognizer. We still collect the precise language from
the user (future-proof + lets us pass the exact enum), but we must not over-promise
per-language accuracy in copy.

### 2.3 The 25-vs-19 gap (a real open question — flag for review)

- Parakeet **v3 the model** advertises **25 European languages** (NVIDIA model
  card, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 — **Likely**; sourced
  by research subagent, not re-verified line-by-line here).
- FluidAudio's **`Language` hint enum** exposes **19** of them
  (`TokenLanguageFilter.swift:4-23` — **Confirmed**).
- Missing from the hint enum vs the model's 25: Danish, Dutch, Estonian,
  Finnish, Greek, Hungarian, Latvian, Lithuanian, Maltese, Swedish (and the enum
  *adds* Bosnian/Belarusian/Serbian which aren't on every public 25-list). The
  exact set difference is **Likely**, pending a clean diff of the model card.

**Design decision (v1):** the user-facing language list = **the union the model
supports**, but the `language:` hint we pass = **the FluidAudio `Language` case if
one exists, else `nil`** (which falls back to v3 auto-detect, today's behavior).
A language with no hint case still works (auto-detect) — it just doesn't get the
script filter. This is the honest, non-over-promising mapping.

### 2.4 Japanese is a different model entirely

`AsrModelVersion.tdtJa` → `Repo.parakeetJa`
(`AsrModels.swift:13`, `:20`). The `language:` hint is *silently ignored* for
`.tdtJa` (per the transcribe doc-comments). So Japanese is the one language where
"pick a language" genuinely means "download/load a different model." **Confirmed.**

There is also a `.ctcZhCn` (Mandarin) model case in 0.14.7
(`AsrModels.swift:11`) — out of scope for v1 but confirms the
"new language = new model" pattern for non-European scripts.

### 2.5 Conclusion: single multilingual model vs multiple variants

| Bucket | Mechanism | Model |
|---|---|---|
| 25 European langs (English is v3-capable, but is **routed to v2** — §3) | **same weights**, optional script hint at transcribe time | Parakeet v3 (`.v3`) |
| Japanese | **different weights** (different download) | Parakeet JA (`.tdtJa`) |
| English (perf-optimized, optional) | **different weights**, English-only | Nemotron (`.nemotron_en`) |

So: **"selecting a language" reduces to "selecting a language hint" for the entire
European family on one shared model**, and only forks to a different model for
Japanese (and, later, Mandarin). The earlier "multiple per-language weights"
framing is wrong for the European set on 0.14.7. **Confirmed.**

---

## 3. The language → (model + hint + tier) mapping table

This is the spec the implementation encodes (proposed new type
`LanguageChoice`, see §5.4). **English uses Parakeet v2; European languages use
v3.** Both v2 and v3 are 0.6B batch models that run on **every** Mac — no
hardware gating applies to either (`AsrModelVersion.v2`/`.v3`,
`AsrModels.swift:6-7`; matrix §"Recommended policy" gates only the heavy
streaming Nemotron, `:206`). The language picker therefore **never** routes to
Nemotron; that lever lives only in the tabled Advanced surface (§4.1) and remains
hardware-gated (M2 Pro/16 GB).

> **Product-owner decision (supersedes earlier "English → v3").** English resolves
> to **`tdt_0_6b_v2_en_streaming` (Parakeet v2)** for better English accuracy. v2
> is **un-deprecated as the English path** — it is now a first-class default, not
> a "deprecated option" (see §4 / open question §10).
>
> **Naming note (EOU removal).** `docs/pseudo-streaming/design.md` removes the EOU
> *engine*, but the `tdt_0_6b_v2_en_streaming` / `tdt_0_6b_v3_eou_streaming`
> **enum raw values are preserved** — they come to mean "v2/v3 batch final +
> sliding-window live preview." Rows below are correct at the enum level.

| User-facing language | FluidAudio `Language` hint | Model (`ParakeetModelID`) | Live-preview behavior | Notes |
|---|---|---|---|---|
| English | **none** (v2 is monolingual; hint is v3-only) | **`.tdt_0_6b_v2_en_streaming` (v2)** | v2 batch final + live preview | First-class English default; no hint needed; runs on every Mac. Nemotron is **not** reachable here — Advanced only (§4.1) |
| Spanish, French, German, Italian, Portuguese, Romanian | matching `.es/.fr/.de/.it/.pt/.ro` | `.tdt_0_6b_v3_eou_streaming` | English live draft → v3 final | Latin script filter applies |
| Polish, Czech, Slovak, Slovenian, Croatian, Bosnian | matching case | `.tdt_0_6b_v3_eou_streaming` | same | Latin; #512 fix benefits these most |
| Russian, Ukrainian, Belarusian, Bulgarian, Serbian | matching case | `.tdt_0_6b_v3_eou_streaming` | same | **Cyrillic** filter applies |
| Other v3 model langs w/o hint case (Danish, Dutch, Finnish, Greek, Hungarian, Swedish, etc.) | `nil` (auto-detect) | `.tdt_0_6b_v3_eou_streaming` | same | Works, no script filter |
| Japanese | n/a (ignored) | `.tdt_0_6b_ja` | **none** — `supportsStreaming == false` (`ParakeetModelID.swift:182`); batch-only, no preview companion (see §5.5) | Separate download |

Notes:
- The live preview for the v3 family is the live-preview bundle, always English
  (it is "intentionally a lighter, less accurate streaming model … reads as a
  rough draft," `ParakeetModelID.swift:35-41`). A non-English user sees an
  English-ish rough draft replaced by the correct-language final at stop. That's
  an existing trait, not introduced here, but copy must not imply the *preview*
  is in the chosen language. **Open question for review (§10).**
- `.tdt_0_6b_v2_en_streaming` is now the **English language-picker default**
  (no longer "deprecated" — §3 product-owner decision). `.nemotron_en` remains
  the only English model **not** reachable from the language picker; it lives
  behind the deferred, hardware-gated Advanced surface (§4.1).
- English no-preview note: the v2 English path **does** have a live preview
  (`supportsStreaming == true`, `ParakeetModelID.swift:186-188`), unlike Japanese
  (§5.5).

---

## 4. The `advanced` flag

**Reuse the existing `AdvancedFlag`** (`Sources/App/AdvancedFlag.swift`). Do not
add a new key.

- Key: `jot.advanced.enabled` (`AdvancedFlag.swift:24`).
- Fresh-install default: **false** (matches the prompt's "DEFAULT FALSE").
- Existing-user default: **true** (seeded from `jot.setupComplete`, `:28-34`) —
  unchanged; existing users already see advanced surfaces.

### 4.1 DEFERRED / TABLED — advanced-mode model surface (do NOT design now)

> The user **explicitly tabled** the question of *what* Advanced exposes for
> model selection. This section is a placeholder, not a design.

When `jot.advanced.enabled == true`, we *may* later expose a model-level control
(e.g. "Engine: Parakeet v2 / v3 / Nemotron", int4
encoder, raw `ParakeetModelID` picker) underneath the language control. **The
shape, copy, placement, and whether it lives in `TranscriptionPane` or a new
disclosure are all OUT OF SCOPE for this document.**

> **Hardware gate on Nemotron (binding even though the surface is tabled).**
> Per `docs/hardware-capability-matrix/design.md`, Nemotron is the **heaviest**
> model and is **offered only on chip tier ≥ M2 Pro AND ≥ 16 GB RAM**
> (qualifying row: M2 Pro/Max/Ultra, `:198`; "the only mode with a real
> chip-generation question," `:206`). When the Advanced surface is built it
> **must not present Nemotron as selectable on non-qualifying Macs** — omit it or
> show it disabled/"unavailable on this Mac." English remains v3 (+ pseudo-
> streaming preview) on **every** Mac regardless — this gate governs the optional
> Nemotron engine only, never the English default.

Open sub-questions captured for the future doc:
- Does Advanced show the *model* picker we're removing, or a slimmer "engine"
  toggle?
- How does an Advanced model override interact with a language choice (does
  picking a model pin the hint, or detach it)?
- Does Advanced expose the int4 v3 encoder (`.tdt_0_6b_v3_int4`) per hardware
  tier?

Until that doc exists, Advanced changes nothing about the language control.

---

## 5. The new UX

### 5.1 Principles

- The user picks a **language**, never a model.
- Default selection = **system locale's language if it maps to a supported
  language, else English.** (Read `Locale.current.language.languageCode`;
  fall back to `.english`.)
- Model identity appears only in **About → Acknowledgements** (per the user).
- One language control, two surfaces (wizard + Settings), both backed by the
  same new `LanguageChoice` + `TranscriberHolder`.

### 5.2 Wizard "Language" step (replaces the Model step)

`ModelStep.swift` becomes `LanguageStep.swift` (rename the file/type; keep the
`WizardStepID.model` raw case to avoid renumbering the ordered enum — see §6.4).

Layout:
- Title: "What language will you speak?" Subtitle: "Jot transcribes on-device.
  You can change this anytime in Settings."
- A single searchable language list (or a `Picker`/`Menu` for ~26 entries),
  default-selected to system locale (§5.1). Each entry is just a language name +
  flag/SF-Symbol; **no model name, no footprint, no badges.**
- Below the picker: a one-line "Downloads a ~X model that runs on the Neural
  Engine" where X is derived from the resolved model's `approxBytes`
  (`ParakeetModelID.swift:72-90`) — model *name* still hidden, only size shown.
- Download/progress: reuse `ModelDownloader.downloadIfMissing` + the existing
  `ProgressView(value:)` + percentage (we keep the percentage; the user said
  "keep it simple," and it already exists). Triggered on Continue (or
  immediately on language change if we want eager download — recommend
  **on Continue** to avoid downloading a model the user is about to change away
  from).
- Advance precondition unchanged: `installedModelIDs.contains(primaryModelID)`
  (`SetupWizardCoordinator.swift:124-125`) — the resolved model for the chosen
  language must be cached.
- Keep the optional vocabulary-boost (CTC 110M) section as-is (`ModelStep.swift:175-225`).

### 5.3 Settings → Transcription "Language" control

In `TranscriptionPane.swift`, replace the radio model list
(`:39-61`, `:208-273`) with:
- A labeled `Picker`/`Menu` "Transcription language" bound to the new
  `LanguageChoice` (writes through `TranscriberHolder`, see §5.4).
- An `info.circle` `InfoPopoverButton` next to it (new — the model rows have
  none today) with "Learn more →" deep-linking to a new Help anchor
  `"transcription-language"` (§8). Body copy explains on-device, language→model,
  and "see the exact model in About → Acknowledgements."
- Below: install-state + download/delete + progress for the *resolved* model
  (reuse `rowSubtitle`/`rowTrailing` logic, `:275-323`), but labeled by language,
  not model.
- The collapsed-disclosure of "other models" (`:46-56`) is **removed** from the
  default surface and (later) folded into the deferred Advanced surface (§4.1).

### 5.4 New type: `LanguageChoice`

Add `Sources/Transcription/LanguageChoice.swift` (new file; `Sources/` is a
synchronized Xcode group per CLAUDE.md, so no `project.pbxproj` edit needed —
**but** confirm it's under `Sources/`, not `Resources/`, which is *not*
synchronized per MEMORY).

```swift
public enum LanguageChoice: String, CaseIterable, Sendable {
    case english, japanese, spanish, french, german, italian, portuguese,
         romanian, polish, czech, slovak, slovenian, croatian, bosnian,
         russian, ukrainian, belarusian, bulgarian, serbian
    // + any additional v3 model langs we choose to surface w/o a hint case
    // (danish, dutch, finnish, greek, hungarian, swedish, …) — see §2.3.

    var displayName: String { /* localized language name */ }

    /// The model the language picker resolves to. **Tier-agnostic and NEVER
    /// returns `.nemotron_en`** — English uses v2 (best English accuracy),
    /// European languages use v3, Japanese uses the JA model. v2 and v3 are both
    /// 0.6B batch models that run on every Mac, so no hardware gating applies
    /// here; Nemotron is reachable only via the tabled, M2-Pro/16-GB-gated
    /// Advanced surface (§4.1). The `tier:` parameter is plumbed for future
    /// matrix wiring but ignored in v1.
    func modelID(tier: HardwareTier) -> ParakeetModelID {
        switch self {
        case .english:  return .tdt_0_6b_v2_en_streaming   // v2: monolingual, best English accuracy
        case .japanese: return .tdt_0_6b_ja
        default:        return .tdt_0_6b_v3_eou_streaming   // European → v3 (+ script hint)
        }
    }

    /// The FluidAudio language hint. Only meaningful for the v3 European paths —
    /// it is the v3-only Latin/Cyrillic script filter (§2.2). English runs on v2
    /// (monolingual), where the hint is unused/ignored, so English returns nil.
    var fluidAudioLanguage: FluidAudio.Language? {
        switch self {
        case .english: return nil           // v2 is English-only; no hint needed
        case .japanese: return nil          // ignored by tdtJa anyway
        case .spanish: return .spanish
        // … map each v3 European case that has a TokenLanguageFilter.Language
        //    counterpart; return nil for surfaced langs without one (§2.3).
        }
    }
}
```

#### 5.4.1 Two-key reconciliation (resolves Risk #4 — explicit code, not prose)

`TranscriberHolder` now owns **two** keys: the preserved `jot.defaultModelID`
(model source of truth) and the new `jot.transcriptionLanguage`. They can
disagree (a v1.4 Nemotron user whose language migrates to `.english`). The
stored model **always wins** so we never downgrade or trigger a surprise
download — including the **grandfathered Nemotron-on-underpowered-hardware** case
below. Concretely:

```swift
// Active model = explicit stored choice if present, else the language default.
// `storedModelID` is the existing jot.defaultModelID read (TranscriberHolder.swift:54-55).
var activeModelID: ParakeetModelID {
    storedModelID ?? activeLanguage.modelID(tier: hardwareTier)
}
```

`setLanguage(_:)` must NOT call the existing `setPrimary(_:)` blindly — that
would overwrite `jot.defaultModelID` and could swap a Nemotron/v2 user onto v3
EOU plus a download. The guard:

```swift
func setLanguage(_ lang: LanguageChoice) async {
    defaults.set(lang.rawValue, forKey: "jot.transcriptionLanguage")
    let resolved = lang.modelID(tier: hardwareTier)

    // No-clobber rule for English-only stored models. Both Nemotron and v2 are
    // English-only; v2 IS the new English default (so re-picking English is a
    // no-op), and Nemotron must be grandfathered (don't downgrade). Either way,
    // if the stored model already serves English, keep it untouched.
    if let stored = storedModelID,
       stored == .nemotron_en || stored == .tdt_0_6b_v2_en_streaming,
       lang == .english {
        // Language metadata updates; MODEL is untouched. No setPrimary, no download.
        activeLanguage = lang
        return
    }

    // Otherwise the language drives the model (the common case).
    activeLanguage = lang
    await setPrimary(resolved)   // existing path: writes jot.defaultModelID + downloads if missing
}
```

This makes Risk #4 a code invariant: opening the new picker (which shows
"English" for a Nemotron user) and re-confirming English is a **no-op on the
model** — no silent v3-EOU downgrade, no surprise fetch. A Nemotron user only
loses Nemotron if they actively pick a *non-English* language (which Nemotron
can't serve), which is the correct, user-initiated swap.

**Grandfather rule — the guard is hardware-blind on purpose.** The stored-model
check at the top of `setLanguage` does **not** consult `hardwareTier`. This is
deliberate: a v1.4 user already running `nemotron_en` on a Mac **below** the new
M2 Pro / 16 GB Nemotron gate (§4.1) is **kept on Nemotron** — no clobber, no
forced re-download, no downgrade to v3 — because they already run it acceptably
today. The hardware gate governs only **new auto-selection and Advanced-surface
availability**; it must never force a migration off a working stored model. (Same
principle as `runV20DefaultStampIfNeeded`'s "explicit key already set → leave
intact," `ModelChoiceMigration.swift:202-204`.)

- Persist via the **new** key `jot.transcriptionLanguage` (raw value) on
  `TranscriberHolder`, *in addition to* the preserved `jot.defaultModelID`. The
  holder keeps `jot.defaultModelID` authoritative per §5.4.1 so all existing
  readers (RecordingPersister metadata, LogSharing, migration anchors) keep
  working unchanged.
- Wire the hint at the call site: `Transcriber.swift:157` becomes
  `manager.transcribe(samples, decoderState: &decoderState,
  language: activeLanguage.fluidAudioLanguage)` — passing the resolved hint
  instead of nothing. For English (v2) and Japanese the hint is `nil` and the SDK
  ignores it; only the v3 European paths actually exercise the script filter.
  (Requires the `Transcriber` to know the active `LanguageChoice`; thread it
  through the holder, mirroring how `modelID` is threaded.) **This is the change
  that finally activates §2.1 — for v3 European paths only.**
- **Decoder config is per-model — `previewTranscribe` must use the active
  model's decoder.** v2 and v3 are different TDT models with different decoder
  geometry: v2 `blankId == 1024`, v3 `blankId == 8192`
  (`AsrModels.swift:53-54`, **Confirmed**); the LSTM `decoderLayers` likewise
  differ per version. The pipeline already builds decoder state from
  `modelID.fluidAudioVersion.decoderLayers` (`Transcriber.swift:154-156`) — that
  must continue to read the **active** model (now v2 for English vs v3 for
  European), and any preview/streaming path (`previewTranscribe` /
  `DualPipelineTranscriber`) must derive its decoder config from the active
  model, never a hardcoded v3 assumption. A v2/v3 mismatch here would corrupt
  decoding (wrong blank token).

### 5.5 Japanese has no live-preview companion — don't assume one

`.tdt_0_6b_ja` has `supportsStreaming == false` (`ParakeetModelID.swift:182`):
it is a **batch-only** model with no EOU/streaming preview bundle. The
redesigned `LanguageStep` and the wizard advance gate
(`installedModelIDs.contains(primaryModelID)`,
`SetupWizardCoordinator.swift:124-125`) must gate on the **resolved primary
model alone** — they must NOT additionally require a preview/EOU companion to be
cached, or the Japanese path can never satisfy the advance precondition. The
download for Japanese is a single bundle (`ModelDownloader` routes JA through
`downloadSingleBundle`, `ModelDownloader.swift:81`), and the live preview is
simply absent during a Japanese recording — the pill shows the recording state
without an interim transcript, and the batch final lands at stop. Any UI copy
that says "live preview" must be conditional on
`activeModelID.supportsStreaming`.

---

## 6. Exact files/types to change + migration

### 6.1 New files
- `Sources/Transcription/LanguageChoice.swift` — the new enum (§5.4).
- (rename) `Sources/SetupWizard/Steps/ModelStep.swift` →
  `LanguageStep.swift` (keep `WizardStepID.model` raw case, §6.4).

### 6.2 Edited files
- `Sources/Transcription/TranscriberHolder.swift` — own `jot.transcriptionLanguage`;
  add `setLanguage(_:)`; keep `jot.defaultModelID` in sync; expose active
  `LanguageChoice` + resolved hint. Preserve `defaultsKey` (`:42`) and
  `setPrimary` persistence (`:76`).
- `Sources/Transcription/Transcriber.swift:157` — pass `language:` (§5.4).
- `Sources/Settings/TranscriptionPane.swift` — replace model radio list with the
  language control (§5.3); add `info.circle` → Help `"transcription-language"`.
- `Sources/SetupWizard/Steps/LanguageStep.swift` — language picker UX (§5.2).
- `Sources/Settings/AboutPane.swift` — ensure the active model name appears in
  Acknowledgements (verify current state; **Unknown** whether it's already there).
- `Sources/Help/…` — add a `"transcription-language"` anchored subsection (§8).

### 6.3 @AppStorage / UserDefaults keys
| Key | Status | Notes |
|---|---|---|
| `jot.defaultModelID` | **PRESERVE** | Still the model source of truth & migration anchor (`TranscriberHolder.swift:42`). |
| `jot.transcriptionLanguage` | **ADD** | New: raw `LanguageChoice`. |
| `jot.transcriptionLanguage.migrated` | **ADD** | One-shot migration sentinel (mirror `ModelChoiceMigration` markers, `ModelChoiceMigration.swift:39-61`). |
| `jot.advanced.enabled` | **PRESERVE** | Existing (`AdvancedFlag.swift:24`). |
| `jot.settings.transcription.otherModelsExpanded` | **DEPRECATE** | Only meaningful if the "other models" disclosure survives in Advanced (§4.1). |

### 6.4 Migration logic (no silent clobber — mirrors existing precedent)

Add `ModelChoiceMigration.runLanguageMigrationIfNeeded(defaults:)` (or a sibling
in a new `LanguageMigration.swift`), one-shot guarded by
`jot.transcriptionLanguage.migrated`, run from `JotComposition.build` alongside
the existing `runFourOptionMigrationIfNeeded` / `runV12EouRenameIfNeeded`
(`ModelChoiceMigration.swift:70`, `:122`).

Derive the initial `jot.transcriptionLanguage` from the **existing stored
`jot.defaultModelID`**, never clobbering it:

```
stored jot.defaultModelID →  initial jot.transcriptionLanguage
  .tdt_0_6b_ja                       → .japanese
  .nemotron_en                       → .english   (GRANDFATHER: keep model = nemotron even if the Mac is below the M2 Pro/16 GB gate; do NOT downgrade or re-download)
  .tdt_0_6b_v2_en_streaming          → .english   (already on v2 = the new English default; nothing to do)
  .tdt_0_6b_v3_eou_streaming / v3*   → .english   (GRANDFATHER on v3: keep their v3 model; do NOT auto-download v2; see case (b) below)
  absent (fresh install)             → system-locale language (§5.1); English resolves to v2 (~600 MB download)
```

**The three English cases, explicitly (English-default is now v2, §3):**

- **(a) NEW install / fresh English selection → v2.** A fresh install whose
  resolved language is English downloads `.tdt_0_6b_v2_en_streaming` (~600 MB on
  disk, `ParakeetModelID.swift:80-81`) via the existing percentage download UX.
  This is the genuine first-run path; the download is expected.
- **(b) EXISTING user stored on a v3 model → grandfathered on v3, NO forced
  re-download.** Migration sets `jot.transcriptionLanguage = .english` but leaves
  `jot.defaultModelID` on their v3 model. The precedence
  `activeModelID = storedModelID ?? language.modelID(tier)` (§5.4.1) yields the
  stored v3 model — they keep working on v3 with **no surprise v2 download**.
  (We do not chase a marginal accuracy gain by silently fetching v2 behind their
  back; that violates the no-surprise-download rule.)
- **(c) EXISTING user ACTIVELY re-picks "English" in the new picker → resolves to
  v2; download is acceptable.** Because the user took an explicit action,
  `setLanguage(.english)` runs the common path (`await setPrimary(.tdt_0_6b_v2_en_streaming)`)
  and a v2 download via the percentage UX is fine — they chose it. The guard at
  §5.4.1 only suppresses the swap for stored Nemotron/v2 users; a stored-v3 user
  who re-picks English *does* move to v2, but only on a deliberate pick, **never
  automatically on upgrade**.

Critical no-clobber rules:
1. If `jot.defaultModelID` is already set, **the model stays exactly what it
   is** during migration for v3 / Nemotron / v2 users — the language key is
   *additive* and the holder honors the stored model over the language→model
   default when they disagree (case (b) above; `runV20DefaultStampIfNeeded`'s
   "explicit key already set → leave intact," `ModelChoiceMigration.swift:202-204`).
   **This includes hardware-ineligible Nemotron users:** a v1.4 `nemotron_en`
   user on a Mac below the M2 Pro / 16 GB gate (§4.1) is grandfathered —
   migration leaves their stored model untouched. The hardware gate governs only
   new auto-selection / Advanced availability, never a forced migration off a
   working stored model.
2. Set the `migrated` sentinel so we never re-derive on later launches (drift
   prevention, exactly as documented at `ModelChoiceMigration.swift:42-45`).
3. The download banner path (`fourOptionDownloadPendingKey` +
   `startPendingMigrationDownloadIfNeeded()`,
   `TranscriberHolder.swift:91-144`, `ModelChoiceMigration.swift:55`) is used
   **only** for the deliberate-pick path (c) and fresh installs (a) — **never**
   triggered by the upgrade migration itself for stored-model users (b).

### 6.5 Deliberate behavior change for release notes

**Fresh English-locale installs will NO LONGER be forced onto Nemotron — they
now default to Parakeet v2.** Today `ModelStep.swift:149-151` writes
`.nemotron_en` into `jot.defaultModelID` the moment a fresh user reaches the
Model step. The new Language step removes that write entirely: a fresh English
install resolves to **`.tdt_0_6b_v2_en_streaming` (Parakeet v2)** — the
product-owner-chosen best-English-accuracy default (§3), which runs on every Mac.
This is an **intentional** change and must be called out in the release notes:
new English users get the v2 English path by default; Nemotron becomes an opt-in,
hardware-gated Advanced choice (§4.1). (No effect on existing users — their
stored `jot.defaultModelID` is preserved per §5.4.1 / §6.4; a stored-v3 user is
grandfathered on v3 and only moves to v2 if they actively re-pick English.)

---

## 7. Hardware tier dependency

**Resolved by `docs/hardware-capability-matrix/design.md`** (**Confirmed**,
2026-06-13). That doc's owner **product decision** (its §0 TL;DR, "Product
decision," and §6 "Recommended capability-gating policy for macOS") is now firm —
**not** a measurement TODO. The two facts that matter for the language picker:

- **Nemotron is a hard-gated Advanced option, never a default**, offered **only
  on chip tier ≥ M2 Pro AND RAM ≥ 16 GB.** Every Mac below that bar — **all M1
  tiers (base, Pro, Max), and M2 base** — gets **no Nemotron.** The matrix closes
  the former "M1 = Unknown" cell as a **firm product decision (M1 → no
  Nemotron)**, explicitly overriding the earlier "recommend on M2+ / pending
  measurement" framing.
- **No model the language picker uses is hardware-gated.** English → **v2** and
  European → **v3** are both 0.6B batch models that run on every Apple Silicon
  Mac. Hardware tier only ever governs the optional Nemotron engine, which the
  language picker does not touch.

**Consequence for this feature:** the language picker is **tier-agnostic and
never routes to Nemotron.** `LanguageChoice.modelID(tier:)` returns
`.tdt_0_6b_v2_en_streaming` for English, `.tdt_0_6b_v3_eou_streaming` for every
European language, and `.tdt_0_6b_ja` for Japanese, on **every** tier (§3, §5.4).
Nemotron is reachable only via the tabled Advanced surface (§4.1), and even there
it must be hidden/disabled on sub-M2-Pro/16-GB Macs. Wiring English → Nemotron
into the picker would ship exactly the regression on M1 / low-RAM Macs that the
matrix's firm decision forbids. The `tier:` parameter is plumbed for the future
Advanced engine selector (which reads the matrix's chip+RAM gate) but is ignored
by the v1 language picker.

Flag for review: **is a `HardwareTier` type already defined anywhere** (e.g. by
the matrix implementation)? Search returned nothing definitive — **Unknown**; the
implementer must reuse the matrix doc's type if one exists rather than adding a
duplicate.

---

## 8. "When you ship a feature, update these" checklist (per CLAUDE.md)

- [ ] **`docs/features.md`** — rewrite the "Transcription model picker" bullet
      (`features.md:210`) to "Transcription language picker." Note model auto-selection.
- [ ] **`docs/design-requirements.md`** — only if the product shape line on
      model selection shifts; **Likely yes** (model→language is a shape change).
- [ ] **`README.md`** — update any "choose a model" marketing bullet to "pick a
      language."
- [ ] **`website/index.html`** — per CLAUDE.md, the live site is the *separate*
      `~/code/jot-website` repo; do NOT edit `website/` here. Headline-feature
      grid only if we market multilingual.
- [ ] **`Resources/help-content.md` budget** — re-run the build-phase budget
      check after Help/Ask Jot copy changes (1500-token budget; currently 1015).
- [ ] **Shortcuts registry** — N/A (no new hotkey).
- [ ] **Status pill states** — N/A (no new in-progress state; download UX reused).
- [ ] **Menu bar** — N/A.
- [ ] **Settings pane** — the Transcription pane change *is* the feature (§5.3).
      New `info.circle` → Help deep-link required.
- [ ] **Help tab** — add a `"transcription-language"` anchored subsection
      (Basics or Advanced) and wire the new popover's deep-link to it.
- [ ] **Help infra tests** — in DEBUG, run `HelpInfraTests.runAll()`; ensure
      `InfoCircleAnchorTests` resolves the new `"transcription-language"` anchor.
- [ ] **Setup wizard** — the Model step becomes the Language step (§5.2). No new
      permission, so no new wizard *step*, just a redesigned one.
- [ ] **About → Acknowledgements** — confirm the active model name is surfaced
      there (the user's "they can see it in Acknowledgements" promise).

---

## 9. Risks

1. **Over-promising per-language accuracy.** The hint is Latin-vs-Cyrillic only
   (§2.2). Copy must not imply Polish-vs-Czech precision. (Medium.)
2. **Activating the hint is a behavior change.** Today `nil` is passed
   (`Transcriber.swift:157`); turning on script filtering could regress edge
   cases (e.g. a German speaker quoting an English brand name gets the brand
   filtered oddly). Needs runtime A/B per MEMORY's "audio-capture changes require
   runtime verification" discipline. (Medium-High.)
3. **The English live preview for non-English languages** reads wrong during
   recording (English-ish draft for Spanish speech). Pre-existing, but the
   language picker makes the mismatch more salient. (Medium — see §10.)
4. **Migration mis-mapping a Nemotron/v2 user.** If migration naively maps
   "English" → v3 EOU and *changes their model*, it clobbers their choice and may
   trigger a surprise download. §6.4 rule #1 prevents this — must be implemented
   exactly. (High if mishandled.)
5. **25-vs-19 language gap** surfaces languages with no hint + (for some) no
   strong v3 coverage. (Low-Medium.)

---

## 10. Open questions (attack these)

1. **Does the v3 model card's 25-language list exactly contain FluidAudio's 19
   hint cases, and which model-supported languages have *no* hint?** (§2.3,
   **Likely/Unknown**.) Resolve before finalizing `LanguageChoice` cases.
2. **Live-preview language mismatch:** for non-English languages, do we (a) keep
   the English EOU draft, (b) suppress the live preview entirely, or (c) ship a
   note? Affects `DualPipelineTranscriber` and pill copy. **Unresolved.**
3. **English language migration mapping:** existing users (any stored model) map
   to language "English" but keep their stored model (§6.4 case (b)). Confirm:
   should the fresh-install default be system-locale or always English? §5.1
   proposes system-locale (which then resolves English → v2).
4. **Hardware tier matrix** — policy resolved (§7; per-language default —
   English→v2, EU→v3, neither gated; Nemotron Advanced-only, gated to ≥ M2 Pro
   AND ≥ 16 GB; never on M1). Remaining: does a `HardwareTier` type
   already exist from the matrix implementation to reuse? (**Unknown**.) Note the
   language picker no longer routes English → Nemotron under *any* tier — that's
   strictly an Advanced/engine concern.
5. **Advanced model surface** — entirely TABLED (§4.1). Needs its own doc.
6. **Does About/Acknowledgements already show the model name?** Unverified
   (`AboutPane.swift` not read). The user's promise depends on it.
7. **Should picking a non-English language auto-disable English-only features**
   (Nemotron, custom-vocab acoustic rescoring which is English/JA-specific per
   `Transcriber.swift:163-203`)? Interaction not designed here.
8. **(Non-blocking) Confirm Parakeet v2 stays maintained in FluidAudio.** Now
   that v2 is the first-class English default (not a deprecated option), verify
   FluidAudio keeps shipping it. It **is present in the pinned 0.14.7**
   (`AsrModelVersion.v2` → `.parakeetV2`, `AsrModels.swift:6,17` — **Confirmed**),
   so there is no immediate risk; flag for the next SDK bump. If FluidAudio ever
   drops v2, the English default falls back to v3 (the European path) with no
   UX change.

---

## 11. Out of scope

- The Advanced model-selection surface (§4.1 — tabled by the user).
- Mandarin / `.ctcZhCn` and any non-European, non-JA language.
- Per-language post-processing profiles (tracked separately in
  `docs/plans/multi-language-readiness.md` F5).
- Localizing the *app UI* into the chosen language (that's
  `japanese-ui-localization.md`, a different effort).
- Changing the live-preview engine (EOU) — only its copy is in question (§10.2).
