# Startup Transcription-Model Integrity Self-Heal — Design

> Status: **DRAFT — brainstormed + design-reviewed (rounds 1–2), revised.** Authored
> autonomously (user away until tomorrow) from prior discussion + a code-grounding
> pass + an independent adversarial review whose findings are folded in (see §11).
> Decisions marked **[DECIDED-FOR-YOU]** are my best call and need a sanity check;
> **[OPEN]** items genuinely need the user's input. **Nothing implemented yet.**

## 1. Feature overview

Make Jot **proactively verify the active transcription model is loadable at
launch** and **self-heal** when it isn't — instead of the user discovering a
broken model reactively, at the cursor, when they press the dictation hotkey.

Dictation is hotkey-driven and Jot is a menu-bar app whose main window is
usually *hidden* (closing it just `orderOut`s it). So a user can run for days
without opening the window. Any model problem must be detected and surfaced on a
path that does **not** depend on the window being open.

## 2. Background / current behavior (investigation findings)

Grounded in code (`jot-kap` worktree). Citations are point-in-time.

- **`ModelCache.isCached(_:)` is a *presence/completeness* check, not a dir-exists
  check** (`ModelCache.swift:103–150`). Parakeet delegates to FluidAudio
  `AsrModels.modelsExist()`; Nemotron checks a required-files manifest. A model
  with a **missing file** correctly returns `false`.
  - **Gap:** it validates *presence*, not *integrity*. A **truncated/corrupt but
    present** file passes `isCached` and only fails later at **load**
    (`AsrModels.load()` / `NemotronStreamingTranscriber.ensureLoaded()` →
    `TranscriberError.fluidAudio`).
- **Model load is lazy**, but there is already a **launch-time eager attempt**:
  `AppDelegate.prewarmTranscriber` spawns a **detached, fire-and-forget** Task
  calling `pipeline.ensureTranscriberLoaded()` (`AppDelegate.swift:~177`). Its
  success/failure is **discarded today**.
- **Failure already surfaces — but reactively.** At transcribe time,
  `PipelineError.modelMissing` → `RecorderController` sets `.error(…)`
  (`RecorderController.swift:369`). The **Overlay pill is always installed**
  (`OverlayWindowController` at launch) and `PillViewModel` subscribes to
  `recorder.$state` on the main actor, so **the error pill renders even with the
  main window closed**. (So we are not silently failing — but the user only
  learns at the moment they try to dictate, and there is no recovery.)
- **No `UNUserNotification` path** exists anywhere.
- **`ModelDownloader.downloadIfMissing`** guards on `isCached` (skips if present)
  and **validates + purges partials post-download** (`ModelDownloader.swift:65,
  116–119, 203–206`, throws `.corrupted`). **Consequence:** to heal a
  *corrupt-but-present* bundle, we must `cache.removeCache(for:)` **before**
  calling it, or it will no-op.
- **Existing pending-download infra** (`TranscriberHolder
  .startPendingMigrationDownloadIfNeeded` / `.startPendingNemotronUpgradeIfNeeded`)
  is idempotent, spawns its own `Task`, drives `@Published migrationDownloadProgress
  / migrationDownloadError`, and is rendered by `JotAppWindow.migrationDownloadBanner`.
  **But it is only invoked from `JotAppWindow.onAppear`** → never runs for
  hotkey-only users. Safe to also call at launch.
- **No model fallback** exists (the `RecorderController` fallback is audio-device
  UID only). Adding "use another installed model" would be net-new logic.
- **Invariant to respect:** `HardwareTier`/jot-mobile note — *resolve which model
  is used at **recording start**, never mid-recording, to avoid a visible swap.*
- **Routing exists:** `setSidebarSelection(.settings(.transcription))`
  (environment closure; also a `NotificationCenter` deep-link) — clean way to
  "bring them to the page."
- **Pill/recorder states** (`RecorderController.State`, `PillViewModel.PillState`)
  have no "repairing/needs-download" case; adding one touches ~3 exhaustive
  switches.

### Documentation gaps noticed (skill asks me to flag these)
- `prewarmTranscriber` being fire-and-forget is **load-bearing to this design**
  but uncommented as a deliberate choice vs. an oversight. Worth a comment.
- `isCached`'s presence-not-integrity semantics are subtle and caused my initial
  mis-scoping; worth a one-line doc on `isCached` clarifying "presence, not
  integrity — corrupt-but-present passes."

## 3. Assumptions made
- A1. Re-downloading a model the user previously had is acceptable behavior on
  detected breakage (it's the only way to self-heal). **[DECIDED-FOR-YOU]**
- A2. Catching *corrupt-but-present* matters, not just *missing* — otherwise we'd
  ship a check that misses the nastier real-world case (interrupted download,
  disk issue). **[DECIDED-FOR-YOU]**
- A3. The always-on overlay pill is an acceptable surface for hotkey-only users
  (no need to add macOS Notification-Center plumbing in v1). **[OPEN]**

## 4. Goals / Non-goals
**Goals**
- Detect an unloadable active model (missing **or** corrupt) **at launch**, before
  any hotkey recording is possible.
- Self-heal automatically (purge-if-corrupt → background re-download → reload)
  with visible progress on a window-independent surface.
- Never present a bare/confusing error at the cursor; if the user dictates during
  repair, show a clear "model downloading…" state (and optionally transcribe on a
  fallback model — see Options).
- Reuse existing infra (`ModelDownloader`, pending-download banner, pill) rather
  than inventing parallel machinery.

**Non-goals**
- Periodic/background re-validation while running (launch-time is enough for v1).
- Notification-Center alerts (deferred unless A3 is rejected).
- Healing user-config corruption (only the model cache is in scope).

## 5. Options explored + tradeoffs

### 5.1 How to DETECT
- **Opt-D1: A separate `isCached`-based integrity check at launch.**
  - Simple, synchronous, cheap. **But misses corruption** (the real gap) — only
    re-checks presence. Rejected as the primary mechanism.
- **Opt-D2 (SELECTED): Observe the result of the already-existing launch load
  (`prewarmTranscriber` → `ensureTranscriberLoaded`).** A real load attempt is the
  ground truth: it catches missing *and* corrupt. We stop discarding its result.
  - Pro: catches everything, reuses an existing launch step, minimal new surface.
  - Con: load is heavier than a presence check (but it already runs today).

### 5.2 What to DO on failure (recovery)
- **Opt-R1: Re-download only, block dictation until ready.** Simplest. Honest
  "downloading…" surface. User can't dictate during repair.
- **Opt-R2: Re-download + temporary fallback to another *installed* English model
  so dictation keeps working.** Best UX. Net-new fallback logic.
  - Tension: the "resolve at recording start, never mid-session" invariant. This
    is **compatible** if we only pick the fallback **at recording start** (never
    swap a recording in flight) and flip back once healed. Surfaced as a notice
    ("Temporarily using Parakeet v2 while Nemotron re-downloads").
  - Risk: accuracy/behavior difference may surprise; more code/edge cases.
- **Opt-R3: Re-download + route to Settings → Transcription.** Hands control to the
  user; good when auto-download isn't desired or fails.

### 5.3 How to SURFACE
- **Opt-S1: Reuse `migrationDownloadBanner`** (window users) — free, but window-only.
- **Opt-S2: Add a pill state** (`repairing/downloading model`, optional progress)
  — covers hotkey-only users; costs ~3 exhaustive-switch updates.
- **Opt-S3: Route affordance** via `setSidebarSelection(.settings(.transcription))`
  from the pill/banner.

## 6. Option selected + tradeoffs **[DECIDED-FOR-YOU — confirm]**

**Detect:** Opt-D2 **refined** (review B1): not "observe the existing fire-and-forget
load" — instead a dedicated **strict per-side integrity probe** at launch that does
NOT route through the streaming error-swallowing path, and classifies missing vs
present-but-unloadable vs transient (review m7) before any destructive action.
**When (user-decided):** run the probe at **app open (launch)** and after a **Sparkle
auto-update relaunch** — both are covered by the launch hook (an applied update
relaunches the app), so one launch-time probe suffices; no periodic check needed.
**Recover (user-decided):** on detection, kick off the self-heal re-download **and
route the user to Settings → Transcription** as the PRIMARY surface (R3) — they land
on the page showing the download/progress so they understand what's happening, rather
than a silent background fix.
**Backup surface (user-decided):** an **always-on persistent pill** for users who
miss/leave the routing (hotkey-only or window dismissed). Driven **directly from
`holder.$repairState`** (review G4), NOT a `RecorderController.State` case (8 switch
sites + two auto-clear layers; repairing isn't a recording state).
**In v1 (user-decided): Opt-R2 transient-fallback** — dictation must NEVER block, so
during a repair the user dictates on another *installed* English model (e.g. v2),
then flips back when healed. Best-effort: if NO alternate English model is installed
(e.g. fresh install with only the broken model), fall back to the route+pill block.
See Phase 5.

Trade-off accepted: v1 includes the transient-fallback so **dictation keeps working
during repair** (on an alternate installed English model), with the pill + Settings
route explaining what's happening. Only a user whose *only* model is the broken one
(no alternate installed) is blocked — and they get the clear "downloading model X%"
pill + Settings page rather than an error.

## 7. Implementation plan (pseudo-code only)

### Phase 1 — STRICT integrity probe at launch + precise classification
> Revised per review B1 + m7. "Observe the existing load" is NOT sufficient,
> because `DualPipelineTranscriber.ensureStreamingLoadedQuietly` swallows
> streaming-side load errors — a healthy batch bundle with a corrupt *preview*
> side would pass and skip the heal. So the probe must strict-load BOTH sides and
> report which side failed. And a load error is NOT automatically "corrupt": a
> `.fluidAudio` can wrap a transient ANE/CoreML failure (the very class
> `prewarmTranscriber` exists to dodge), so we confirm on-disk badness via a
> presence check before any destructive purge.
```
// probeIntegrity lives on DualPipelineTranscriber — the ONLY object that holds
// BOTH the batch final engine and the streaming preview engine (review G2;
// `Transcriber` alone can't see the streaming side). It loads each side strictly,
// NOT via `ensureStreamingLoadedQuietly` (whose error-swallowing is for runtime
// degradation tolerance, not integrity).
//   DualPipelineTranscriber.probeIntegrity() async -> (batch: Result, streaming: Result)
//   (bare-Transcriber and nemotron_en cases: trivial single-side passthrough)

// CRITICAL (review G1): the probe IS the launch load, on the SINGLE live
// `holder.transcriber` instance — it does NOT spin a second Transcriber. We RETIRE
// `prewarmTranscriber`'s fire-and-forget discard INTO this: same one load we already
// pay at launch, except (a) per-side strict (not quiet) and (b) result observed.
// No second loader ⇒ no double multi-GB ANE load and no race on FluidAudio's
// process-global `sharedMLArrayCache`; no new mutex needed.
Task.detached(priority: .utility):
    let r = await holder.probeActiveModelOnLaunch()   // wraps the dual probe
    if r.allHealthy: holder.markActiveModelHealthy()
    else: await holder.beginSelfHeal(failedSides: r.failedSides)
```

### Phase 2 — Self-heal on TranscriberHolder (surgical, false-positive-safe)
> Revised per review M4 + M5 + m7.
```
func beginSelfHeal(failedSides):
    guard !selfHealStarted; selfHealStarted = true
    // Respect the existing launch arbitration (review G5 + Phase 4): if a
    // four-option or nemotron-upgrade download is pending this launch, DEFER
    // self-heal to the next launch (don't run a 3rd concurrent download).
    guard noMigrationOrUpgradePending() else { return }

    for side in failedSides:                 // failedSides already means "load FAILED"
        // Disambiguate missing vs corrupt with a PRESENCE check only (review G3 —
        // no `filesPresentButUnloadable` primitive; failedSides already encodes
        // load-failure). `stillPresent` = batchBundleExists / streamingPartialBundleExists.
        if cache.stillPresent(activeModelID, side):     // present + load-failed ⇒ corrupt
            // m7: corrupt, not a transient CoreML hiccup, because the file is on disk
            // AND the strict load failed. Purge ONLY this side (M4 — never blunt
            // removeCache; it would delete the SHARED v3 batch bundle).
            cache.removeCache(for: activeModelID,
                              removeBatch: side == .batch, removeStreaming: side == .streaming)
            // M5: removeCache swallows errors. If the bad files survive, downloadIfMissing
            // would no-op (it guards on isCached) and the once-flag blocks retry →
            // stuck forever. Verify and bail to .failed instead.
            if cache.stillPresent(activeModelID, side):
                repairState = .failed(.cannotPurge); routeToSettingsAffordance(); return
        // else: side merely missing — no purge; downloadIfMissing will fetch it.
    repairState = .downloading(progress: 0)             // v1 dedicated field — see Phase 3 / G5
    Task:
        try await downloader.downloadIfMissing(activeModelID, progress: { repairState = .downloading($0) })
        on success: try? await transcriber.ensureLoaded(); repairState = nil; markHealthy
        on failure: repairState = .failed(.download); routeToSettingsAffordance()   // marker kept → retry next launch
```

### Phase 3 — Window-independent surfacing (v1: contained; unified state deferred)
> Revised per review G4 + G5. v1 does NOT do the big enum refactor (see §11/G5):
> self-heal is a **third producer** with its own `@Published repairState`, respecting
> the existing launch deferral guard. The unified `modelTask` enum (Round-1 M3) is
> the documented end-state but is a SEPARATE follow-up — it would rewrite shipped,
> asymmetric migration/upgrade arbitration (download-first-then-flip, marker-clear
> asymmetry) and is higher blast-radius than this feature warrants.
```
// v1 dedicated state on TranscriberHolder (sibling to the existing
// migrationDownloadProgress/Error producers, which stay as-is):
enum RepairState: Equatable { case downloading(progress: Double?); case failed(FailReason) }
@Published var repairState: RepairState?      // nil = nothing in flight

// Surfacing — drive BOTH surfaces straight from repairState (review G4):
//  (a) JotAppWindow banner: render when repairState != nil (reuse banner styling).
//  (b) Overlay pill: a persistent "Downloading model… X%" pill.
//      *** Do NOT route this through RecorderController.State *** — that enum has 8
//      switch sites (RecorderController:103,158; PillViewModel:294,301;
//      HotkeyRouter:403,422,554; ChatbotVoiceInput:128) AND two auto-clear layers
//      (RecorderController.scheduleAutoRecoveryIfNeeded 2.5s reset AND
//      PillViewModel.scheduleDismiss). Repairing is NOT a recording-lifecycle state.
//      Instead: PillViewModel subscribes to holder.$repairState and shows a pill that
//      is NEVER handed to scheduleDismiss / scheduleAutoRecoveryIfNeeded → naturally
//      persistent, and zero recording-lifecycle switch sites change.
//  (c) tapping pill/banner → setSidebarSelection(.settings(.transcription)).
```

### Phase 4 — Move pending-download triggers earlier
```
// Also call at launch (not only JotAppWindow.onAppear), so hotkey-only users
// get migration/nemotron downloads too:
holder.startPendingMigrationDownloadIfNeeded()
holder.startPendingNemotronUpgradeIfNeeded()
// (keep the onAppear calls; both are idempotent)
```

### Phase 5 (v1 — user-decided "never block") — Opt-R2 fallback
> Confirmed viable per review m6: the recording path reads `holder.transcriber`
> lazily and binds the streaming dual per-session at start, so choosing a fallback
> at recording-start honors the no-mid-session-swap invariant. CRITICAL: use a
> **transient** transcriber — do NOT call `setPrimary` (it persists
> `jot.defaultModelID` and would silently change the user's saved model).
```
// At RECORDING START only:
if !activeModel.isReady && repairState != nil:        // v1 field (G5)
    if let alt = installedEnglishModel(excluding: activeModelID):
        // transient ONLY — never setPrimary:
        sessionTranscriber = transcriberFactory(alt, activeLanguage)
        notice("Temporarily using <alt> while <active> re-downloads")
    else: show repairing pill (cannot record yet)
// On heal completion, the next recording naturally resolves back to activeModel.
```

## 8. Edge cases
- **Streaming/preview side corrupt, batch healthy** (review B1) — the strict
  per-side probe (Phase 1) catches it; surgical purge (Phase 2) re-downloads only
  the streaming side.
- **Blunt purge would evict the shared v3 batch bundle** (review M4) — Phase 2 uses
  `removeCache(for:removeBatch:removeStreaming:)` for only the failed side.
- **Purge fails (locked/permission)** (review M5) — verify `!cache.stillPresent`
  after purge; if files survive, go straight to `.failed` + route (don't enter a
  no-op `downloadIfMissing` that strands the user in "repairing").
- **Transient CoreML/ANE load failure, not real corruption** (review m7) — confirm
  files-present-but-unloadable before purging; a transient `.fluidAudio` should NOT
  trigger a multi-GB re-download. If ambiguous, prefer leaving it for the next
  launch over destructive purge.
- Repair download fails (offline) — persistent `.failed` surface + route; retry
  next launch (mirror the Nemotron pending-marker discipline).
- User hotkeys mid-repair — Phase 3 persistent pill (v1) or Phase 5 fallback (later).
- **Co-fire with migration/nemotron downloads** (review M3→G5) — v1: self-heal's own
  `repairState` producer DEFERS (Phase 2 guard) when a four-option/nemotron download
  is pending this launch, so only one download runs. (The unified `modelTask` enum is
  the follow-up end-state — §9.)
- Don't loop: a `selfHealStarted` once-flag per launch (like `nemotronUpgradeStarted`).

## 9. Maintainability / scalability notes
- Centralize "is the active model usable, and if not, heal it" on
  **`TranscriberHolder`** (already owns model lifecycle + the pending-download
  methods) rather than scattering checks across AppDelegate/Recorder. One owner,
  one set of `@Published` signals, reused by every surface.
- Prefer a **strict load probe** (D2-refined) over a presence-only check so we
  never drift from "what actually loads" as new model types are added — but make it
  per-side so it sees the streaming/preview engine too (the error-swallowing quiet
  path is for *runtime degradation tolerance*, not for *integrity checking*; keep
  them separate).
- **End-state (follow-up, NOT v1):** one `modelTask` enum on the holder that
  migration, nemotron-upgrade, AND self-heal all produce (retiring the ad-hoc
  `migrationDownload*` + `repairState` fields), with a single arbitration point —
  the true "one signal" design. Deferred to its own change (review G5) because
  folding the two SHIPPED producers in would rewrite their subtle asymmetric
  semantics (download-first-then-flip; marker-clear asymmetry) — higher blast radius
  than this feature warrants ("ship the fix, refactor later"). **v1** ships a
  contained `repairState` producer that respects the existing launch deferral guard;
  the unification then has three clean producers to merge.

## 10. Open questions — resolved
- **[RESOLVED — OPEN-3]** Route the user to **Settings → Transcription** on detection
  (primary), with the self-heal re-download running so they see progress there.
  Decided by user.
- **[RESOLVED — OPEN-2/A3]** Surface = **always-on persistent pill** as the backup if
  they miss the routing. **No macOS Notification-Center** needed for v1. Decided by user.
- **[RESOLVED — timing]** Probe at **app open** and after **auto-update relaunch**
  (one launch-time hook covers both). Decided by user.
- **[RESOLVED — OPEN-1]** Dictation must **never block**: Phase 5 transient-fallback
  is **in v1**. During repair, dictate on another installed English model; flip back
  when healed; block (route+pill) only if no alternate model is installed. Decided by user.

## 11. Review log

### Round 1 — independent adversarial review (folded in)
All findings verified against code and accepted (the review was grounded, not
nit-picky — it also confirmed several parts sound and dismissed checked non-issues).

| ID | Sev | Finding | Resolution |
|----|-----|---------|-----------|
| B1 | blocker | "Observe the launch load" misses streaming/preview corruption — `DualPipelineTranscriber.ensureStreamingLoadedQuietly` swallows streaming load errors (`DualPipelineTranscriber.swift:62–93`). Batch-healthy + preview-corrupt would skip heal (modern default v3+Nemotron/v2+EOU). | Phase 1 now does a **strict per-side probe** that does NOT use the quiet path; §6 Detect updated. |
| M2 | major | Error pill auto-clears after 2.5s (`RecorderController.swift:200–208`); a download outlives that. | Phase 3: `repairing` is a **persistent** state, exempt from `scheduleAutoRecoveryIfNeeded`. |
| M3 | major | Third producer on shared `migrationDownloadProgress/Error` compounds co-fire (the two existing producers already need a manual deferral, `TranscriberHolder.swift:254–263`). | Phase 3/§9: **single `modelTask` enum** with one arbitration point; migration + upgrade + heal all map from it. |
| M4 | major | Blunt `removeCache` deletes the **shared v3 batch bundle** (`ModelCache.swift:160–164`), hurting `.tdt_0_6b_v3` users. | Phase 2: surgical `removeCache(for:removeBatch:removeStreaming:)` on only the failed side (depends on B1's per-side result). |
| M5 | major | `removeCache` swallows errors; if purge fails, re-download no-ops and the once-flag strands the user in "repairing". | Phase 2: verify `!stillPresent` post-purge → else `.failed` + route. |
| m6 | minor | Phase 5 fallback must not call `setPrimary` (persists `jot.defaultModelID`); recording binds model per-session at start so fallback-at-start is invariant-safe. | Phase 5: use a **transient** `transcriberFactory(alt, lang)`; confirmed invariant-safe. |
| m7 | minor | `.fluidAudio` wraps **any** native load error incl. transient CoreML hangs (the `770529` class `prewarmTranscriber` dodges) — purging multi-GB on a false positive is expensive. | Phase 2/§8: confirm files-present-but-unloadable before purge; transient → don't purge. |
| m8 | minor | Moving pending-download triggers to launch is safe (idempotent once-flags) but makes M3 arbitration necessary. | Folded into Phase 4 + M3. |

**Most important change (per reviewer):** B1 — strict per-side load probe — and it's
coupled with M4 (need to know *which* side is corrupt to purge surgically); design
them together.

**Verdict:** sound enough to implement after these fixes (now folded in). Remaining
user calls are the **[OPEN]** items in §10 (chiefly: R2 fallback in v1 or fast-follow).

### Round 2 — focused re-review of the revisions (folded in)
Verified the Round-1 fixes for coherence. Confirmed sound: M4 maps to real
`removeCache(for:removeBatch:removeStreaming:)` (and Nemotron's `batchCachePaths`
is `[]`, so per-side purge is correct); per-side presence primitives exist
(`batchBundleExists`/`streamingPartialBundleExists`); M5 is a real bug correctly
mitigated; m6 transient-fallback is invariant-safe.

| ID | Sev | Finding | Resolution |
|----|-----|---------|-----------|
| G1 | blocker | The strict probe had no serialization story and would race/double the launch load if it spun a second `Transcriber` (FluidAudio `sharedMLArrayCache` is process-global). | Phase 1: the probe **IS** the single live launch load (prewarm retired into it), strict-per-side only in that it doesn't swallow streaming errors. No 2nd loader, no new mutex. |
| G2 | major | `probeIntegrity` must live on `DualPipelineTranscriber` (only holder of both sides); `Transcriber` can't see streaming. | Phase 1: scoped as net-new `DualPipelineTranscriber.probeIntegrity()`; named explicitly. |
| G3 | major | `filesPresentButUnloadable` isn't a real capability and is circular (load result already known). | Phase 2: dropped; use `failedSides` (= load failed) + trivial `stillPresent` presence check. |
| G4 | major | M2 fix insufficient — the real pill auto-clear is `PillViewModel.scheduleDismiss`, not just `scheduleAutoRecoveryIfNeeded`; `RecorderController.State` has 8 switch sites. | Phase 3: drive the persistent pill **directly from `holder.$repairState`**, never via `RecorderController.State`/`scheduleDismiss` → 0 lifecycle switch-site changes, naturally persistent. |
| G5 | major (decision) | Unified `modelTask` enum (Round-1 M3) would rewrite shipped, asymmetric migration/upgrade arbitration. | **M3 SUPERSEDED.** v1: self-heal is a 3rd producer (`repairState`) respecting the existing launch guard; unified enum filed as follow-up (§9). |

> **Note:** Round-1 **M3's** "unify now" resolution is **superseded by G5** — see §9.

**Verdict:** **Ready to implement** as revised. The only judgment call that was
genuinely open (G5: unify-now vs contained-v1) is decided in the doc (contained v1,
unify later) but is reversible if the user prefers the full refactor up front. The
§10 **[OPEN]** product calls remain for the user (chiefly R2 fallback in v1 vs
fast-follow, and whether a macOS notification is wanted beyond the pill).
