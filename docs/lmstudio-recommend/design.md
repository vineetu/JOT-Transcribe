# LM Studio as the Recommended Local AI — Design

Status: **design-reviewed, pre-implementation.** Decisions locked with the user; the adversarial review (2026-06-23) findings are folded in below; remaining items are flagged as Open questions.

## Overview

Make **LM Studio** the *recommended local AI provider* in Jot on capable Apple-Silicon Macs, via an **in-app, hardened, headless install** of LM Studio's `llmster` daemon + the recommended model, with thinking disabled and the params we benchmarked. LM Studio is **not** the default — it's opt-in, badged **"Recommended (local)"** on public / **"Local option"** on Sony. The app default stays Apple Intelligence (public, macOS 26+) / PFB Haiku (Sony).

Why: LM Studio (MLX) is the fastest local stack on Apple Silicon (~30–50% over llama.cpp), fully on-device (fits Jot's privacy stance), and OpenAI-API-compatible (already wired as `.lmStudio`). The friction today — install app, click through onboarding, find+download a model, disable Qwen's thinking — is exactly what this removes.

## Locked decisions

1. **Positioning:** LM Studio = opt-in, **not the default**. Default stays Apple Intelligence (public) / PFB Haiku (Sony). Label is **per-flavor** (decision #4): public **"Recommended (local)"**, Sony **"Local option"**.
2. **Recommended model:** **Qwen 3.5 9B (MLX 4-bit)** — `qwen/qwen3.5-9b` (resolves to `lmstudio-community/Qwen3.5-9B-MLX-4bit`, ~6 GB). The model id persisted into config must be the id `/v1/models` reports, not the alias.
3. **RAM gate:** recommend only when **physical RAM > 16 GB**. At ≤16 GB, don't surface LM Studio as recommended and don't offer install. Single model for all qualifying machines; **warn (not block, not downshift) on tight RAM (18 GB)** — see UX flow.
4. **Flavor scope:** **both** public and Sony get the recommend + install — but Sony badges it **"Local option"** (not "Recommended"), so it never reads as competing with the IT-sanctioned PFB Enterprise default. PFB stays Sony's default + sanctioned path.
5. **Thinking-off (REVISED per review F2):** Jot writes the **proven direct `chat_template.jinja` patch** (`{%- set enable_thinking = false %}` at the top of the model's template) — verified to yield **0 reasoning tokens via the `/v1/chat/completions` API**. The `model.yaml` wrapper is the *documented alternative* but is finicky for side-loaded models (LM Studio bug #1759), so it is NOT the primary. (`enable_thinking:false` as a request param is silently ignored on LM Studio's MLX path — verified — so it's not an option.)
6. **Tuned params:** cleanup already runs at **temp 0.1** in `LLMClient` (`buildRequest` temp arg). No per-provider sampling overrides needed beyond the no-think patch (#5).
7. **Install method (per review F6, revised after empirical check):** **hardened headless via a PINNED installer script.** The `llmster` "full" bundle is **577 MB** (`.bundle/` with deno+node+daemon+plugins+libs) with non-trivial placement/daemon setup — reimplementing extraction is fragile and would diverge from LM Studio's maintained logic. So instead: Jot **downloads `https://lmstudio.ai/install.sh`, verifies it against a Jot-pinned sha512, and only runs it if the hash matches** (`LMS_NO_MODIFY_PATH=1 LMS_PRINT_QUIET=1`). This closes the F6 supply-chain hole (we run ONLY the exact audited script we pinned, never "whatever ships at runtime") while reusing LM Studio's correct setup; the script itself version-pins the tarball and verifies its sha512 internally. All install/download network access is **gated behind a single explicit user gesture** (mirrors the Flavor1 invariant); never automatic. **Pinned values (2026-06-23):**
   - `INSTALL_SH_SHA512 = e4f4f566a71e3b0cfa3a56647109fa047b8a9bba4bf4b6932b94d3761edb52cbc355f3bc052402cf6aac70a12a333bbb2a6528c7237fba826ad698834292c49e`
   - script version pins llmster `0.0.15-2`; tarball `0.0.15-2-darwin-arm64.full.tar.gz` (577 MB) sha512 `9de5e62d…ebcaedbf` (script verifies this itself).
   - Bump cadence: when LM Studio updates, re-fetch install.sh, re-pin its sha512. Surface the pinned version in the card.

## Verification results (what's proven vs. residual)

- **No-think works through the API** ✅ — `enable_thinking` is a Jinja template variable LM Studio applies to all endpoints incl. `/v1/chat/completions`; our direct template patch gave 0 reasoning tokens. (Decision #5.)
- **Headless `llmster` install** ✅ tested 2026-06-23: user-space, **no sudo, fully non-interactive, no login/license gate**; shares `~/.lmstudio` (no re-download); no PATH edits with `LMS_NO_MODIFY_PATH=1`. Existing GUI server on :1234 stayed up + non-thinking — zero harm.
- **Residual (~90%, → implementation step 1):** could not prove on this machine that llmster self-initializes + serves on a *truly fresh* Mac (GUI app had already created `~/.lmstudio`). Verify "zero GUI onboarding on a clean machine" on a clean VM before relying on the no-hop flow. Strong prior: it's the purpose-built headless/CI daemon, nothing gated on a UI.

## Feasibility (verified)

- **Jot is NOT sandboxed** (`Resources/Jot.entitlements`: `app-sandbox=false`, `network.client=true`). So Jot can download the pinned tarball, extract to user space, run `lms`, and write `~/.lmstudio/**` (the no-think patch). ✅
- **RAM/disk gating:** `ProcessInfo.processInfo.physicalMemory`; free disk via `URL(fileURLWithPath:"/").resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])`.
- **Provider already wired:** `.lmStudio` exists end-to-end (enum, OpenAI request path `LLMClient.swift:238/252`, `LMStudioProbe`, model picker probe, Ask Jot via `OpenAIChatStream`). This feature is mostly *setup orchestration* on top of it.

## Security & privacy invariants (review F5/F6)

- **One-gesture rule:** every network/install action (tarball download, `lms get` ~6 GB from HuggingFace, server start) happens only behind an explicit user button press — never `onAppear`/timer/launch. Mirrors `Flavor1Session`'s "only a user gesture spawns the CLI" invariant (`Flavor1Session.swift:19-24`).
- **No remote-script execution:** download + sha512-verify the pinned tarball ourselves; do not pipe `install.sh` to a shell. Pin the `llmster` version + checksum in Jot; plan a bump cadence.
- **Localhost-only background:** readiness *polling* hits only `http://localhost:1234` — fine for Little Snitch. No external host is contacted automatically.
- **Privacy enumeration:** update `docs/features.md` "Automatic network calls (full enumeration)" (≈ features.md:346) to state LM Studio install/model network access is user-gesture-gated, never automatic; localhost only thereafter.

## UX flow (headless llmster — review F1/F3/F9/F10)

```
Settings → AI (and Setup Wizard "AI" step):

if physicalMemory <= 16GB:
    LM Studio shown as a plain selectable option, NO recommend/local badge, no install CTA.
else:
    badge = (flavor == sony) ? "Local option" : "Recommended (local)"
    state machine (no GUI app, no DMG, no onboarding hop):

    NOT_INSTALLED (no lms CLI / llmster):
        CTA "Set up local AI (LM Studio)" [one gesture] →
          download pinned llmster tarball → verify sha512 → extract to user space

    INSTALLING: progress; on success → READY_NO_MODEL

    READY_NO_MODEL (lms present, model absent):
        if freeDiskGB < 7: block with "need ~7 GB free"
        if 16GB < RAM <= 18GB: show tight-RAM advisory ("works, but may be slow under load")
        CTA "Download Qwen 3.5 9B (~6 GB)" [one gesture] →
          lms get qwen/qwen3.5-9b --mlx -y (progress)
          → applyNoThinkPatch()
          → lms server start --port 1234 (if not already serving)
          → resolve served id from /v1/models; config.setModel(id, for:.lmStudio)   # F3
          → verifyThinkingOff()                                                       # F10

    CONFIGURED:
        "LM Studio ready — Qwen 3.5 9B (local), thinking off."
        (Selecting .lmStudio as the active provider stays user-initiated — not auto.)
```

Readiness signal: `lms` present AND `GET http://localhost:1234/v1/models` succeeds. Never auto-spawn anything; surface buttons.

## Implementation plan (pseudocode — not final code)

```
// New: Sources/LLM/LMStudio/LMStudioSetup.swift (orchestrator, @MainActor ObservableObject)
enum SetupState { unsupportedRAM, notInstalled, installing(p), readyNoModel, downloadingModel(p), configured, error(String) }

func detectState():
    if physicalMemory <= 16GB: return .unsupportedRAM
    if !lmsCliPresent(): return .notInstalled
    if !modelDownloaded("qwen/qwen3.5-9b") || !serverServesModel(): return .readyNoModel
    return .configured

func install():                       // one user gesture; non-sandboxed
    sh = download("https://lmstudio.ai/install.sh")             // 18 KB
    guard sha512(sh) == PINNED_INSTALL_SH_SHA512 else { error } // F6: run ONLY the audited script
    run("/bin/sh", [sh], env: ["LMS_NO_MODIFY_PATH":"1","LMS_PRINT_QUIET":"1"], progress:)
    // the script downloads the version-pinned 577MB tarball + verifies its own sha512 + sets up ~/.lmstudio

func downloadModel():                 // one user gesture, after READY
    guard freeDiskGB() >= 7 else { block }
    run("<lms> get qwen/qwen3.5-9b --mlx -y", progress:)
    applyNoThinkPatch()                                         // F5/#5: chat_template.jinja
    ensureServerRunning(port:1234)
    let served = firstModelId(from: GET /v1/models)            // resolved id, not alias
    LLMConfiguration.shared.setModel(served, for: .lmStudio)   // F3: persist BEFORE select
    verifyThinkingOff(model: served)                           // F10

func applyNoThinkPatch():             // primary mechanism (#5)
    path = ~/.lmstudio/models/<...>/chat_template.jinja
    if !hasNoThinkPrefix(hash(path)): prepend("{%- set enable_thinking = false %}", path)
    // RE-APPLY HOOK (F7): run this check when the user selects .lmStudio OR on first
    // readiness-poll success — NOT blindly every launch. Drift-detect via section hash;
    // skip if LM Studio holds the file mid-update.

func verifyThinkingOff(model):        // F10: don't assume — confirm on the live server
    r = POST /v1/chat/completions {model, "say hi", max_tokens:32}
    if r.usage.reasoning_tokens != 0: re-apply patch + reload; if still !=0 → surface warning

// Settings: Sources/Settings/RewritePane.swift + new LMStudioRecommendCard
//   - badge per flavor (F4); hidden entirely when .unsupportedRAM
//   - state-driven CTA (Set up / Download model / Ready); progress + error surfaces
// Setup Wizard: Sources/SetupWizard/AIProviderStep.swift — same card when RAM qualifies
```

## Open questions

1. **Clean-machine llmster first-run** (the ~90% residual): on a Mac that never had the GUI app, does `lms`/`llmster` self-initialize `~/.lmstudio` and serve with zero GUI onboarding? → implementation step 1 (clean VM).
2. **Pinned `llmster` version + sha512** sourcing: where Jot stores the pin and the bump cadence (the artifact endpoint serves a `.sha512`, but we should pin a Jot-known-good value, not trust the co-served checksum blindly).
3. **`applyNoThinkPatch` durability** across LM Studio model updates — the re-apply hook is specified (F7: on select / first ready, hash-detect) but confirm the template path layout for MLX models is stable.
4. **Disk thresholds** — block < 7 GB free; the model is ~6 GB. (Warn band optional.)
5. **Copy/CTA wording** for both badges; final card placement (Settings AI + Setup Wizard).

## Checklist touchpoints (from CLAUDE.md — review F11)

- `docs/features.md`: new capability **and** the "Automatic network calls (full enumeration)" section (≈:346) — state install/model access is user-gesture-gated.
- `README.md` / `website/index.html`: headline bullet if it's a marketing-worthy capability.
- Settings → AI card; Setup Wizard AI step.
- Help tab prose + deep-link anchor (+ `InfoCircleAnchorTests`).
- No new hotkey / pill state / menu item (download progress lives in the card).
- Both flavors — verify the card + per-flavor badge render under `JOT_FLAVOR_1`; confirm `.lmStudio` is in Sony `userSelectable` (it is: `LLMProvider.swift:25`).
