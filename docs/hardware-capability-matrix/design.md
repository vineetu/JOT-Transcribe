# Hardware Capability Matrix — Apple Silicon × FluidAudio model/mode auto-selection

**Status:** research / decision doc. No app code changes. Owner-driven.
**Purpose:** feed two sibling plans — (a) batch-pseudo-streaming live preview, (b)
language-based model selection — with an evidence-based answer to: *which Apple
Silicon Mac (chip + RAM + macOS) can run which FluidAudio Parakeet/Nemotron model
and which transcription MODE, so Jot can AUTO-SELECT without a model picker.*

Confidence markers used throughout per the project confidence protocol:
**[Confirmed]** (direct source), **[Likely]** (strong inference), **[Possible]**,
**[Unknown]**.

---

## 0. TL;DR — the "doesn't work on M1" claim, resolved

The user's paraphrased dictation — *"the memotron streaming doesn't work on M1 but
the rest of the ones work"* — decodes to:

> **"Nemotron"** (mis-transcribed "memotron"). **Nemotron streaming** is the
> heavyweight **0.6B int8** streaming model. **EOU streaming (120M)** and the
> **batch** Parakeet models are the "rest of the ones [that] work."

**Nemotron is the HEAVIEST model to RUN, not the lightest.** This is the trap, and the
core of the product decision below:

- **Small-on-disk ≠ light-at-runtime.** Nemotron's int8 quantization makes it *small
  on disk* (~597 MB) but **expensive at runtime** — it is a 0.6B model (~5× EOU's
  120M params) whose int8 encoder is compute/ANE-heavy and carries a ~1.4 GB residency
  cost [Confirmed, `Benchmarks.md:457-460`]. The compact download is exactly why it
  reads as "light" and isn't. It runs the model continuously *during* capture, so each
  chunk must transcribe faster than audio arrives (RTF < 1).
- **Evidence it's the heaviest to run:** jot-mobile **ripped Nemotron** because *"its
  int8 encoder is too heavy for iPhone's Neural Engine to run faster than mic audio
  arrives"* — **3–5× slower than real-time, 10–15 s tail after stop**
  [Confirmed, `jot-mobile/docs/plans/nemotron-variant.md:3`]. The same Nemotron
  1120 ms tier swings **65.0× RTFx on M5 Pro down to 9.28× on an M2 Air** — a ~7×
  collapse from hardware alone [Confirmed, `benchmarks100.md` vs `Benchmarks.md`].
- By contrast EOU (120M) and the **batch** Parakeet final pass are genuinely light and
  run on *every* Apple Silicon Mac — they are the "rest of the ones that work."

**Product decision (owner, overrides earlier "M1 = Unknown / recommend on M2+"):**
Nemotron is a **hard-gated advanced option, NOT the default.** It is offered **only on
chip tier ≥ M2 Pro AND RAM ≥ 16 GB.** Every Mac below that bar — **all M1 (including
Pro/Max/Ultra), all M2/M3/M4 *base*, anything < 16 GB** — is **walled out of Nemotron**
and uses the **per-language default** (all 0.6B batch models that run on every Apple
Silicon Mac): **English → `tdt_0_6b_v2_en_streaming` (v2); the 19 European languages →
`tdt_0_6b_v3_eou_streaming` (v3) + script hint; Japanese → `tdt_0_6b_ja`.** Live
preview on the v2/v3 paths is driven by **`PreviewScheduler`** (a fresh-state
sliding-window pass over the batch model — see decision #2 below). This **resolves the
former "M1 = Unknown" cell as a firm product decision (M1 → no Nemotron)** — not a
measurement TODO. No measurement is required to ship the gate; a deferred RTF probe
(§5, v2) only ever *widens* eligibility later, never narrows it.

> **Key framing:** the only model that is **hardware-gated is Nemotron.** Every other
> model (v2, v3, JA) runs on every Mac — there is **no single universal v3 default**;
> the default is *per-language*, decided by the language-selection sibling plan.

> **Note vs shipped code:** today the app badges `nemotron_en` "Recommended" with no
> hardware gate [`ParakeetModelID.swift:262-264`]. **That is the current shipped-code
> state this work CHANGES** — the target is Nemotron as an Advanced-only, gated option
> (≥ M2 Pro AND ≥ 16 GB). The sibling plans implement the change; the code does not
> match the target yet.

---

## 1. What Jot ships today (code facts)

| Fact | Source |
|---|---|
| Pinned FluidAudio version | **0.14.7** [Confirmed, `Package.resolved`] |
| Fresh-install technical default (current code) | `tdt_0_6b_v3_eou_streaming` [Confirmed, `TranscriberHolder.swift:56`]. **Being changed → per-language default** (English→v2, EU langs→v3, JA→`tdt_0_6b_ja`) by the language-selection sibling plan. |
| `nemotron_en` "Recommended" badge | **Current shipped-code state, being CHANGED by this work.** Code badges it Recommended with no gate [Confirmed, `ParakeetModelID.swift:262`]; **target = Advanced-only + hardware-gated** (≥ M2 Pro AND ≥ 16 GB), not a default. |
| User-visible picker (4 options) | `tdt_0_6b_v3_eou_streaming`, `tdt_0_6b_ja`, `tdt_0_6b_v2_en_streaming` (deprecated), `nemotron_en` [Confirmed, `ParakeetModelID.swift:277-283`] |
| Nemotron loaded outside `AsrManager` | via `StreamingNemotronAsrManager`, chunk hardcoded `.ms1120`, `computeUnits = .cpuAndNeuralEngine` [Confirmed, `NemotronStreamingTranscriber.swift:29-31`] |
| Download flow | thin wrapper over FluidAudio `AsrModels.download` / `DownloadUtils.downloadRepo`; cache root `~/Library/Application Support/Jot/Models/` [Confirmed, `ModelDownloader.swift`] |
| **Existing hardware gate precedent** | `SortformerHardwareGate.isSupported = physicalMemory >= 16 GB` [Confirmed, `SortformerHolder.swift:257-261`] |
| No chip/sysctl detection exists today | only `ProcessInfo.physicalMemory` (Sortformer) + `operatingSystemVersionString` (logs). **No `hw.model`/`machdep.cpu` reads anywhere** [Confirmed, grep] |

**Visible ≠ all cases.** The enum has **7** cases; only **4** are user-selectable
(`visibleCases`). `tdt_0_6b_v3_int4` and `tdt_0_6b_v3_nemotron_streaming` exist as
real cases (for migration anchors / rollback caches) but are **not** in the picker
[Confirmed, `ParakeetModelID.swift:277-283`]. The catalog in §2 covers what Jot can
actually *use*, not just the visible four.

**`tdt_0_6b_v3_eou_streaming` no longer means a separate EOU model.** The EOU streaming
engine is being **deleted** and replaced by **`PreviewScheduler`** (a fresh-state
sliding window re-run over the *batch* model — no second live model). The raw value
`tdt_0_6b_v3_eou_streaming` is retained for migration, but now denotes **"v3 batch +
sliding-window preview."** Treat any "EOU live preview" phrasing in older notes as the
PreviewScheduler path.

**Key architectural fact:** Nemotron has **no batch backend** — it is streaming-only;
when selected it powers *both* the live preview and the final transcript
[Confirmed, `ParakeetModelID.swift:44-45,162-174`]. So on a chip where Nemotron
can't keep up, the *final transcript* is affected too — unlike the v2/v3 paths, where
the final is always the batch pass and the preview (`PreviewScheduler`) is a throwaway
sliding-window draft over that same batch model.

---

## 2. FluidAudio model catalog (evidence-based)

All sizes are exact HuggingFace blob bytes unless noted; all perf is FluidAudio's own
docs. **Caveat:** current FluidAudio docs are HEAD/v0.15.3; Jot pins **0.14.7**. The
Nemotron **2240 ms** tier, B1-fused decode, and the whole **`parakeetUnified`** family
are **HEAD-only and do NOT exist in 0.14.7** [Confirmed via `git show v0.14.7`].

### Models Jot can actually use at 0.14.7

| Model | Params | Type | On-disk | RAM @ infer | English/multi | Source |
|---|---|---|---|---|---|---|
| **Parakeet TDT v3** (default for EU langs) | 0.6B | BATCH | enc fp16 424.6 MB / int4 284.1 MB; repo ~2.85 GB | process peak **~1.5 GB** | multilingual (25 EU langs) | HF API; `Benchmarks.md:272` |
| **Parakeet TDT v2** (default for English) | 0.6B | BATCH | repo 2.58 GB; has int4 enc | not separately found [Unknown] | English | `Models.md`; HF UI |
| **Parakeet TDT-CTC 110M** | 110M | BATCH (+ Jot's vocab aux) | preproc 205.9 + dec 7.5 + joint 2.7 MB | "reduced" (no number) [Unknown] | English | HF API; `Models.md` |
| **Parakeet Japanese** (default for JA; **no live preview**) | 0.6B | BATCH | not measured [Unknown] | Japanese | `Models.md` |
| ~~**Parakeet EOU streaming** (160/320/1280 ms)~~ — **being deleted; replaced by `PreviewScheduler`** | 120M | (was STREAMING) | ~419–429 MB per variant | n/a | English | HF API `parakeet-realtime-eou-120m-coreml` |
| **Nemotron streaming EN** (560/1120 ms @ 0.14.7) — **the only hardware-gated model** | **0.6B** | STREAMING | **enc int8 ~562 MB** + dec 13.8 + joint 17 MB → **~597 MB/variant** | iOS: **~1.4 GB residency** for the 24-layer encoder | English (int8 only) | HF API `nemotron-speech-streaming-en-0.6b-coreml`; `Nemotron.md`; `Benchmarks.md:457-460` |

### Performance (FluidAudio's own LibriSpeech test-clean numbers)

| Model / tier | WER | RTFx | Hardware measured | Source |
|---|---|---|---|---|
| Nemotron 560 ms | 2.28% | 42.1× | **M5 Pro** | `Benchmarks.md:437-449` |
| Nemotron 1120 ms | 2.28% | 65.0× | **M5 Pro** | `Benchmarks.md:437-449` |
| **Nemotron 1120 ms** | 1.99% | **9.28×** | **MacBook Air M2** | `benchmarks100.md:20` |
| EOU 320 ms | 4.88% | 19.25× | **Apple M2** | `Benchmarks.md:404-417` |
| EOU 160 ms | 8.23% | 5.78× | **Apple M2** | `Benchmarks.md:404-417` |
| Parakeet v3 batch | 2.6% avg | ~110× | M4 Pro | `Benchmarks.md` |

**The load-bearing rows:** Nemotron 1120 ms = **65× on M5 Pro vs 9.28× on M2 Air**.
RTFx is whole-pipeline desktop throughput, not live streaming RTF, but the **~7×
hardware spread on the identical model** is the evidence that the slowest ANEs (M1
base, then M2 base) are where Nemotron streaming gets marginal. EOU at 320 ms is only
~120M and still 19× on M2 — it has huge headroom on every Mac.

### iOS / ANE notes (why Nemotron is "heavy")

- FluidAudio recommends running the Nemotron int8 encoder on **CPU on iOS** because
  4-way ANE sharding is *slower* there (~33 RTFx ANE vs ~66 RTFx CPU) and ANE load
  costs ~130 s / ~1.4 GB residency [Confirmed, `Benchmarks.md:457-460`]. Jot's macOS
  Nemotron path uses `.cpuAndNeuralEngine` [Confirmed, code] — on a Mac the ANE is
  much faster, but the ~1.4 GB residency cost still applies.
- 6-bit palettization (422 MB, +9% RTFx, 2.24% WER) is documented as the planned
  replacement for the int8 encoder but **not yet shipped** as of v0.15.3 [Confirmed].

**Min platform:** FluidAudio `Package.swift` declares `.macOS(.v14)`, `.iOS(.v17)`
[Confirmed]. **No explicit minimum-chip (M1) statement exists** [Confirmed — not
found]. ANE-only marketing in README, no per-generation table.

---

## 3. jot-mobile's RAM-wall logic (for comparison)

[Confirmed, `jot-mobile/.../DeviceCapability.swift` + `docs/plans/batch-only-streaming.md`]

- `is600MCapable = physicalMemory >= 4_600_000_000` (~6 GB-class). Threshold chosen
  because `physicalMemory` reports **below nominal** (kernel carve-out): 6 GB devices
  report ~5.5–5.9e9, 4 GB report ~3.7e9; 4.6e9 splits the classes with uniform
  margin. A naive `>= 6e9` would misclassify real 6 GB hardware [DeviceCapability.swift:9-25].
- Tri-state `liveTextEnabled`: explicit `"on"`/`"off"` wins; `"auto"` → `is600MCapable`
  [DeviceCapability.swift:34-40]. Read at recording start, never mid-session.
- Rationale for **RAM not chip**: 600M is ~2 GB resident; jetsam (the hard crash
  limit) is RAM-bound; every new iPhone is 8 GB+ so a RAM gate auto-qualifies future
  devices with no device-ID table to maintain [batch-only-streaming.md:390-408].
- The earlier (superseded) 4-tier resolver used **7.0 / 4.6 / 3.3e9** thresholds with
  uniform margins for nominal 8/6/4 GB [batch-only-streaming.md:457-462].
- Final iPhone direction: **600M-only, hard wall below 6 GB** — *"only support
  something which is good"*; sub-6 GB devices get dictation hard-walled (library
  stays usable), not a degraded mode [batch-only-streaming.md:50-94].

**Does the iPhone wall apply to macOS? — NO (analysis).** Every Apple Silicon Mac
ships **≥ 8 GB** RAM, and macOS `physicalMemory` does **not** carry the iOS kernel
carve-out the same way (a Mac reports close to nominal; 8 GB ≈ 8.0–8.6e9). So:

- The iPhone **6 GB hard wall is moot on Mac** — no Mac is below it. We should **not
  hard-wall any Mac out of dictation.** [Decision]
- The RAM thresholds that *do* matter on Mac are higher and concern **co-residency
  and big-model headroom**, not "can it run at all": e.g. Sortformer's existing 16 GB
  gate, and the question of whether an 8 GB Mac can hold v2/v3 batch (~1.5 GB) + the
  `PreviewScheduler` re-transcribe loop without pressure.

---

## 4. The Mac capability decision matrix

**Axes that matter on Mac (different from iPhone):**
1. **Chip generation + tier → ANE throughput** governs *Nemotron eligibility*. Nemotron
   is the heaviest model to run (§0); it is **hard-gated to chip tier ≥ M2 Pro**.
   Everything else runs everywhere.
2. **RAM** governs *co-residency / big-model headroom* and is the **second half of the
   Nemotron gate** (≥ 16 GB, reusing the Sortformer precedent). It is *not* a dictation
   floor — every Mac runs its per-language default.
3. **macOS version** governs only Apple-Intelligence-adjacent features, not Parakeet.
   FluidAudio min is macOS 14; all Parakeet/Nemotron run on 14/15/26 identically
   [Confirmed — no per-OS model gating in FluidAudio]. **macOS version is NOT a
   model-selection axis** for transcription.

**The hard gate (definitive product decision, §0):** Nemotron is available **only when
chip tier ≥ M2 Pro AND `physicalMemory` ≥ 16 GB.** Both conditions required. Everything
below uses the **per-language default** — English → v2, EU langs → v3, Japanese → JA;
all 0.6B batch models that run on every Apple Silicon Mac. Live preview on the v2/v3
paths is `PreviewScheduler` (sliding window over the batch model); Japanese has none.

**Modes:**
- **Batch** = full pass on stop (always available, RTF ~0.003 even for 10 min;
  never real-time-bound). All three per-language defaults (v2/v3/JA) are batch.
- **Live preview (`PreviewScheduler`)** = re-transcribe a trailing window on a cadence
  over the *batch* model (sibling plan a; replaces the deleted EOU engine). Bursty but
  bounded. Available on the v2/v3 paths; **not** on Japanese.
- **True streaming = Nemotron only** (heavy), runs continuously during capture; must
  keep up with real-time. The EOU streaming engine is gone.

### Compact matrix (chip tier × RAM)

The **per-language default** (v2/v3/JA batch + `PreviewScheduler` preview on v2/v3)
runs on **every** cell — that column is intentionally all ✅. The only gated column is
**Nemotron**, which requires chip tier ≥ M2 Pro **AND** ≥ 16 GB.

| Chip tier | Typical RAM | Per-language default (v2/v3/JA batch) | Live preview (PreviewScheduler) | **Nemotron** (advanced, gated) | Sortformer (16 GB) |
|---|---|---|---|---|---|
| **M1 base** | 8 / 16 GB | ✅ runs [Confirmed] | ✅ (v2/v3; not JA) | ❌ **walled out** (M1) | ✅ only at 16 GB |
| **M1 Pro/Max/Ultra** | 16–128 GB | ✅ | ✅ (v2/v3; not JA) | ❌ **walled out** (M1, any tier) | ✅ |
| **M2 base** | 8 / 16 / 24 GB | ✅ | ✅ (v2/v3; not JA) | ❌ **walled out** (base tier) | ✅ at ≥16 GB |
| **M2 Pro/Max/Ultra** | 16–192 GB | ✅ | ✅ (v2/v3; not JA) | ✅ **eligible** (≥16 GB) | ✅ |
| **M3 base** | 8–24 GB | ✅ | ✅ (v2/v3; not JA) | ❌ **excluded v1** (no suffix; see §5 edge) | ✅ at ≥16 GB |
| **M3 Pro/Max** | 18–128 GB | ✅ | ✅ (v2/v3; not JA) | ✅ **eligible** (≥16 GB) | ✅ |
| **M4 base** | 16–32 GB | ✅ | ✅ (v2/v3; not JA) | ❌ **excluded v1** (no suffix; see §5 edge) | ✅ |
| **M4 Pro/Max** | 24–128 GB | ✅ | ✅ (v2/v3; not JA) | ✅ **eligible** (≥16 GB) | ✅ |

**Reading the matrix:**
- **Most Macs = no Nemotron; everyone gets their per-language default + PreviewScheduler.**
  No Mac is walled out of core dictation — the default runs everywhere
  [Confirmed: batch RTF headroom on all three 0.6B models]. **No model except Nemotron
  is hardware-gated.**
- **Nemotron is the only gated column** — heaviest model to run (§0), restricted to
  ≥ M2 Pro **and** ≥ 16 GB. **All M1 (incl. Pro/Max/Ultra), all M2/M3/M4 base, and
  anything < 16 GB are ❌.** The former "M1 = Unknown" cell is now a firm ❌ — a product
  decision, not a measurement TODO.
- **Known v1 edge — base M3/M4 conservatively excluded.** Base-tier M3/M4 carry no
  Pro/Max suffix in the chip string but may match or exceed M2 Pro performance. v1's
  suffix-based gate **excludes them**; the deferred RTF probe (§5, v2) is what would
  later *admit* them. Erring toward exclusion is deliberate (never ship a model that
  can't keep up).
- **macOS 14 vs 15 vs 26 does not change any cell** for Parakeet/Nemotron.

### What auto-select should pick (policy, ties to sibling plans)

- **Per-language default for everyone** (sibling plan b is authoritative): **English →
  `tdt_0_6b_v2_en_streaming` (v2)**; **the 19 European languages →
  `tdt_0_6b_v3_eou_streaming` (v3) + script hint**; **Japanese → `tdt_0_6b_ja`.** All
  three are 0.6B batch models that run on every Apple Silicon Mac. Live preview on v2/v3
  is `PreviewScheduler` (sliding window over the batch model); **Japanese has no live
  preview.** There is no single universal v3 default — language picks the model.
- **Nemotron (`nemotron_en`) is an ADVANCED option, not a default, and not blanket
  "Recommended."** It is surfaced/auto-eligible **only** on qualifying hardware
  (≥ M2 Pro AND ≥ 16 GB, §5). On non-qualifying Macs it should be **hidden or disabled
  in the picker** — not silently selectable — so a user can never land on a model their
  hardware can't run. (The current code's blanket "Recommended" badge must be removed /
  gated by the sibling plans.)
- **Never auto-select a model that requires a download the user hasn't made**;
  selection collapses to "what's installed + what the chip supports."

---

## 5. Runtime detection on macOS — concrete APIs

### RAM — use this, it's the reliable axis
```swift
let bytes = ProcessInfo.processInfo.physicalMemory   // UInt64, ~nominal on Mac
```
- On Mac this reports close to nominal (8 GB ≈ 8.0–8.6e9). Unlike iOS, **no large
  kernel carve-out**, so a `>= 8 GB` style check is safe — but still pick thresholds
  with margin (e.g. `>= 15 GB` for the 16 GB Sortformer gate, as the code already
  does: `16 * 1_073_741_824` is exact 16 GiB — verify real 16 GB Macs report ≥ that;
  if any report slightly under, drop to ~15 GB). [Confirmed precedent: `SortformerHolder.swift:259`]
- Equivalent sysctl: `hw.memsize` (returns bytes as `Int64`). `ProcessInfo` is
  simpler and is what the codebase already uses.

### Chip tier — the chip half of the Nemotron gate (≥ M2 Pro)
There is **no first-party "ANE generation/tier" API.** The v1 gate keys off the chip
*name string*; read "The Nemotron gate" below for how the two halves combine.

```swift
func sysctlString(_ key: String) -> String? {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}
```

1. **`machdep.cpu.brand_string`** (sysctl, string). On Apple Silicon returns the chip
   name. **Verified on M2 Pro: returns `"Apple M2 Pro"`** — i.e. Pro/Max/Ultra carry a
   trailing token. The base-chip form (whether a base M1 returns the *bare* string
   `"Apple M1"` with no trailing token) **could NOT be verified — no M1 hardware was
   available to the reviewer.**
   ```swift
   let cpu = sysctlString("machdep.cpu.brand_string")   // CONFIRMED: "Apple M2 Pro" on M2 Pro
   // v1 gate keys off the Pro/Max/Ultra SUFFIX + generation ≥ 2:
   func chipClearsNemotronTier(_ cpu: String) -> Bool {
       guard cpu.contains("Apple M") else { return false }            // Apple Silicon
       let hasProTier = cpu.contains("Pro") || cpu.contains("Max") || cpu.contains("Ultra")
       let gen2Plus  = cpu.contains("M2") || cpu.contains("M3")
                    || cpu.contains("M4") || cpu.contains("M5")        // extend per release
       return hasProTier && gen2Plus    // ≥ M2 Pro. Base M3/M4 (no suffix) → false (v1 edge)
   }
   ```
   **[Pitfall #1 — the base-M3/M4 edge, known + accepted]** Base-tier M3/M4 carry **no**
   Pro/Max suffix, so `hasProTier` is false and they are **excluded in v1** even though
   they may match/exceed M2 Pro. This is the deliberate conservative call (§4); the v2
   RTF probe is what later admits them. **[Pitfall #2]** Do NOT exact-match a bare
   `"Apple M1"` — the base-chip string form is `[UNVERIFIED]` (no M1 hardware to the
   reviewer). The suffix+generation predicate above sidesteps it: any M1 string fails
   `gen2Plus`, so all M1 (base and Pro/Max/Ultra) are excluded without needing the exact
   base form. **[Pitfall #3]** Under Rosetta/translation this can misreport; gate on
   `hw.optional.arm64 == 1` first. **[Pitfall #4]** Fragile across future chip names —
   each new generation adds a token to `gen2Plus` (annotated above).

3. **`hw.optional.arm64`** (sysctl, Int 0/1) — confirms Apple Silicon. Always 1 on a
   native arm64 build on Apple Silicon; use as a sanity guard, not a generation signal.

4. **`hw.model`** (sysctl, string, e.g. `"Mac14,2"`). Listed above for completeness;
   board identifier, maps to product not chip, needs a maintained lookup table.
   **Not recommended** for the chip gate — exactly the device-ID table jot-mobile
   rejected for iPhone.

### The Nemotron gate (this is THE answer for §4)

**Both halves required: `chipClearsNemotronTier(cpu) && physicalMemory ≥ 16 GB`.**

**v1 / ship this — definitive, no measurement needed.** The gate is two conjoined
checks:
- **RAM half:** reuse the confirmed Sortformer precedent verbatim —
  `physicalMemory >= 16 * 1_073_741_824` [`SortformerHolder.swift:257-261`]. (Verify a
  real 16 GB Mac reports ≥ that; if any reports slightly under, drop to ~15 GB margin,
  same caveat as the RAM section above.)
- **Chip half:** `chipClearsNemotronTier(cpu)` above — Pro/Max/Ultra suffix **and**
  generation ≥ M2, guarded by `hw.optional.arm64 == 1`.

This is a **firm product decision, not a stopgap that might be wrong**: M1 (all tiers)
and base M2/M3/M4 are excluded *by design* (§0), so the gate's conservatism is the
intended behavior, not an accuracy compromise. Nemotron is **hidden/disabled in the
picker** on non-qualifying Macs — not silently selectable.

**v2 / the RTF probe — a WIDENER, not a ship-blocker.** The deferred on-device probe
exists only to *admit more hardware later* (chiefly base M3/M4, Pitfall #1) by
measuring keep-up directly instead of inferring it from the chip string. It never
narrows v1 eligibility. Spec, fully defined:

- **Single bar: RTF ≤ 0.6** (≥ ~1.67× faster than real-time) — transcribing audio
  takes ≤ 60% of its wall-clock duration; comfortable margin below the 1.0 keep-up
  cliff. ≤ 0.6 → admit Nemotron; else stay on the per-language default.
- **What it runs:** a small **bundled WAV of real speech** (~3–5 s clean read-style
  English), *not* silence — silence can short-circuit the decoder and under-measure
  cost, giving a falsely optimistic RTF.
- **CRITICAL — cold-ANE trap:** the **first** inference after a cold ANE load pays the
  ~130 s / ~1.4 GB residency wall (`Benchmarks.md:457-460`) and measures pathologically
  slow — it would wrongly **fail an otherwise-capable chip.** So **warm first, then
  time:** run ≥ 1 discarded warmup inference (or discard the first timed run) to exclude
  residency/compile cost, then average ≥ 2 warm runs for the decision. Never gate on a
  cold first run.
- **Cache the result** (per chip, in `UserDefaults`) so the probe runs once, not every
  launch — re-run only on a FluidAudio version bump (which can change the encoder).

### macOS version
```swift
ProcessInfo.processInfo.operatingSystemVersion   // .majorVersion, .minorVersion
ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 15, minorVersion: 0, patchVersion: 0))
```
- Already used (as string) in `LogSharing.swift`. **Not a transcription model-selection
  axis** — only relevant if Apple-Intelligence-coupled features ever gate on it.

### Recommended detection stack
1. `physicalMemory >= 16 GB` → RAM half of the Nemotron gate; reuse
   `SortformerHardwareGate` verbatim [`SortformerHolder.swift:257-261`]. Also the
   universal-default has no RAM floor (every Mac ≥ 8 GB runs it).
2. `chipClearsNemotronTier(machdep.cpu.brand_string)` (≥ M2 Pro suffix), guarded by
   `hw.optional.arm64` → chip half of the gate. Both halves AND'd = Nemotron eligible.
3. **v2 RTF probe** is the *widener* for base M3/M4 (and future chips), not the v1 gate —
   the chip-string + RAM gate ships first and stands on its own.

---

## 6. Recommended capability-gating policy for macOS

1. **Do NOT hard-wall any Mac out of DICTATION.** All Apple Silicon Macs are ≥ 8 GB and
   run their per-language default (v2/v3/JA batch + `PreviewScheduler` preview on v2/v3)
   with headroom. The iPhone 6 GB wall is moot on Mac. The Nemotron gate below walls a
   *model*, never the app. **No model except Nemotron is hardware-gated.** [Decision, §3]
2. **HARD-gate Nemotron (the heaviest model to run, §0), and hide it where it doesn't
   qualify.** Nemotron is an advanced option, available **only** when
   `chipClearsNemotronTier(cpu) && physicalMemory ≥ 16 GB` (≥ M2 Pro AND ≥ 16 GB, §5).
   On every other Mac — all M1, base M2/M3/M4, < 16 GB — it is **hidden/disabled in the
   picker**, not silently selectable; the per-language default (English→v2 / EU→v3 /
   JA→`tdt_0_6b_ja`, with `PreviewScheduler` preview on v2/v3) is the only path. This
   is a firm product decision, not a "power users opt in at their own risk" tri-state.
   `nemotron_en` is **no longer blanket-"Recommended"** — that badge must be gated by
   the sibling plans.
3. **Gate live-preview *loop aggressiveness* (cadence/cap) by RAM on 8 GB Macs**, per
   sibling plan (a): smaller trailing-window cap on 8 GB to bound the per-refresh
   ~1.5 GB v3 burst. This is a knob, not a wall — measurement-gated, not pre-emptive.
4. **Reuse the tri-state `auto | on | off` pattern** from jot-mobile for any user
   override of the streaming/live-preview setting, so a future default revision reaches
   `auto` users without clobbering explicit choices.
5. **Keep Sortformer's existing 16 GB gate** — it is the one real RAM wall and it's for
   the dual-ANE-pipeline case, not core dictation. [Confirmed it already exists.]
6. **Resolve at recording start, never mid-session** (jot-mobile invariant — avoids the
   visible model-swap flip).

---

## 7. Citations

**Code (file:line):**
- `jot-mobile/.claude/worktrees/batch-only-streaming/Jot/Shared/DeviceCapability.swift:9-40` — `is600MCapable` 4.6e9, tri-state `liveTextEnabled`.
- `jot-mobile/docs/plans/batch-only-streaming.md:50-94,390-462,524-533` — 6 GB hard wall, RAM-not-chip rationale, 7.0/4.6/3.3e9 tiers, Nemotron "ripped for iPhone RTF".
- `jot-mobile/docs/plans/nemotron-variant.md:3,13,99` — Nemotron 3–5× slower than real-time on iPhone ANE, streaming-only, 560 vs 1120 ms.
- `Sources/Transcription/ParakeetModelID.swift:20-285` — model enum, sizes, Nemotron not an AsrManager model, `nemotron_en` Recommended, visible picker.
- `Sources/Transcription/NemotronStreamingTranscriber.swift:29-31` — `.ms1120`, `.cpuAndNeuralEngine`.
- `Sources/Transcription/TranscriberHolder.swift:56` — fresh-install default `tdt_0_6b_v3_eou_streaming`.
- `Sources/Transcription/ModelDownloader.swift` — download wrapper, cache root.
- `Sources/Transcription/Sortformer/SortformerHolder.swift:257-261` — existing 16 GB `physicalMemory` gate.
- `Sources/Privacy/LogSharing.swift:22,47` — only existing OS-version read.

**External (URL):**
- FluidAudio streaming enum: https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/ASR/Parakeet/Streaming/ParakeetModelVariant.swift
- FluidAudio model docs: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md
- FluidAudio Nemotron doc: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Nemotron.md
- FluidAudio benchmarks (M5 Pro Nemotron, M2 EOU, iOS ANE residency): https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- FluidAudio benchmarks100 (M2 Air Nemotron 9.28× RTFx): https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/benchmarks100.md
- FluidAudio Package.swift (min macOS 14 / iOS 17): https://github.com/FluidInference/FluidAudio/blob/main/Package.swift
- HuggingFace model sizes: nemotron-speech-streaming-en-0.6b-coreml, parakeet-realtime-eou-120m-coreml, parakeet-tdt-0.6b-v3-coreml (FluidInference org on huggingface.co).
- FluidAudio releases (v0.15.3 latest 2026-06-13; v0.14.7 = Jot's pin): https://github.com/FluidInference/FluidAudio/releases

---

## 8. Open questions + biggest uncertainty

**Biggest uncertainty (attack this first):**
> **The M1 question is now CLOSED by product decision, not by measurement** — M1 (all
> tiers) is walled out of Nemotron regardless of RTF (§0). The remaining live
> uncertainty is the **v2 widener's boundary**: which base M3/M4 (and future base chips)
> the RTF probe should *admit*. We have no Jot-side RTF data on those base chips, so the
> v1 conservative exclusion stands until the probe ships. This no longer blocks v1 —
> the gate is firm without it.

**Open questions:**
1. **v2 probe boundary on base M3/M4.** These are excluded in v1 (no Pro/Max suffix) but
   may clear RTF ≤ 0.6. When the probe lands, confirm the bar admits the right base chips
   and not borderline ones. (Separately: the 560 ms tier is ~2× faster than the
   hardcoded `.ms1120` [`NemotronStreamingTranscriber.swift:31`] — dropping to 560 ms is
   another lever to widen eligibility; out of scope for the gate but noted.)
2. **Warm-probe latency.** Is the warm-then-time probe (§5) cheap enough to run once at
   warmup without a noticeable stall? Cache mitigates repeat cost; first-run cost is the
   open item.
3. **8 GB Mac + `PreviewScheduler` loop** — does the repeated ~1.5 GB v2/v3 burst
   create real memory pressure under normal multi-app load? Measure on an 8 GB M1/M2
   Air before choosing the trailing-window cap (sibling plan a). (Note: this is the
   *per-language default*, which runs on 8 GB — distinct from the Nemotron gate.)
4. **`machdep.cpu.brand_string` robustness** — confirm the suffix+generation predicate
   (`chipClearsNemotronTier`, §5) classifies correctly across real Macs and doesn't
   break under Rosetta/translation. The base-M1 *exact* string is now moot (any M1 fails
   `gen2Plus`), so that specific verification is no longer on the critical path.
5. **macOS-26 / FluidAudio version bump.** If Jot ever moves off 0.14.7 to v0.15.x,
   the Nemotron **2240 ms** tier and **6-bit encoder** (422 MB, +9% RTFx) land — both
   would *improve* the M1 margin and could change the gate. Re-evaluate on upgrade.
6. **Does v2/v3 batch RAM footprint differ enough to matter on 8 GB?** Only v3's ~1.5 GB
   process peak is documented; v2 RAM is [Unknown]. Confirm before any 8 GB gating.

## Addendum: Nemotron auto-upgrade for existing English users

A one-shot, launch-time migration (`NemotronAutoUpgradeMigration`) silently moves
**existing English** users onto Nemotron when the hardware clears a *stricter* bar than
the run/offer gate above:

- **Run/offer floor** (`HardwareTier.nemotronEligible`): chip ≥ M2 Pro **and ≥ 16 GB** —
  the threshold at which Nemotron is allowed to run / be manually picked.
- **Auto-swap gate** (`HardwareTier.autoUpgradeToNemotronEligible`): chip ≥ M2 Pro **and
  ≥ 24 GB**. The chip predicate is identical (`chipClearsNemotronTier`); only the RAM
  floor differs. The swap is unsolicited, so we require comfortable headroom (24 GB)
  before pushing the heavier model — a 16–24 GB English user keeps their current model
  and can still pick Nemotron manually.

**Safety (no broken dictation).** The migration only sets a pending marker
(`autoUpgradePendingKey`); it never writes `jot.defaultModelID`. The actual swap is
**download-first-then-flip**, performed by
`TranscriberHolder.startPendingNemotronUpgradeIfNeeded()`: the user's current model stays
active while Nemotron downloads in the background (reusing the existing
`migrationDownloadProgress`/`migrationDownloadError` banner), and `setPrimary(.nemotron_en)`
runs only after the download fully succeeds. There is never a window where the active
model points at an uninstalled bundle. On failure the pending marker is left set so the
next launch retries (there is no manual picker for this auto path).

**Gate (all must hold):** `autoUpgradeToNemotronEligible` AND
`jot.transcriptionLanguage == "english"` AND the stored model resolves to a non-Nemotron
model. Ordering: runs **after** `LanguageMigration` (which seeds the language key).
