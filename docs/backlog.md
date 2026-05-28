# Jot — Backlog

Planned features, open bugs, and monitoring items. Separate from `docs/features.md` (which is the shipped-feature inventory) so the backlog can grow without diluting product docs.

This file is structured so it's both human-readable and machine-queryable. Each entry has the same fields. A downstream agent that consumes user feedback can filter by `Status` / `Type` / `Trigger` and match incoming reports against `Trigger` clauses to decide what to act on.

**Conventions:**
- `Status`: `Planned` (work to do), `In progress` (someone's on it now), `Monitoring` (conditional — only act if `Trigger` fires), `Shipped` (in the unreleased dev tree or a released build — historical record), `Deferred` (won't do soon, possibly never).
- `Type`: `Feature`, `Bug`, `UX`, `Monitoring`, `Cleanup`, `Performance`.
- `Trigger`: when this enters our attention. For `Planned`/`In progress` items, usually `Always` (scheduled). For `Monitoring`, the condition that promotes it to `Planned`.
- `Plan`: path to a plan doc under `docs/plans/` when one exists. Plans are local-only (gitignored).
- `Affects`: surfaces / files that change.
- `Description`: one paragraph of intent. Plan doc holds the details.

When an item ships, move it to the **Shipped** section at the bottom (chronological) and keep it for history.

---

## Open · Planned

### features.shortcuts-pane-redesign
- **Status:** Planned
- **Type:** UX
- **Target:** v1.13
- **Trigger:** Always — scheduled for v1.13
- **Plan:** `docs/plans/shortcuts-pane-redesign.md`
- **Affects:** `Sources/Settings/ShortcutsPane.swift`, new `Sources/Settings/Shortcuts/` subfolder
- **Description:** The current Settings → Shortcuts pane shows three rows per action (trigger-type picker + recorder + footer) for five user-bindable actions — ~16+ control rows of vertical scroll. Almost no comparable app uses this multi-row pattern. Collapse to single binding per action with inferred trigger type, section grouping (Recording / Rewrite / Capture), visible "when this fires" badges, and a search field that scales as shortcuts grow. HTML mockup comparing four options at `/tmp/jot-shortcuts-mockups/index.html` during the design phase.

### features.ai-provider-model-discovery
- **Status:** Planned
- **Type:** UX
- **Target:** v1.13
- **Trigger:** Always — scheduled for v1.13
- **Plan:** `docs/plans/ai-provider-model-discovery.md` *(to be written)*
- **Affects:** `Sources/SetupWizard/Steps/AIProviderStep.swift`, `Sources/Settings/RewritePane.swift`, new `Sources/LLM/Probes/` subfolder
- **Description:** Auto-detect available models for every AI provider (OpenAI, Anthropic, Gemini, Ollama) by probing each provider's `/models` endpoint. Populate a combobox-style picker (NSComboBox via NSViewRepresentable) that allows free-form typing for custom models. Hide base URL behind a `▸ Use a custom endpoint` disclosure unless the user has set a non-default value or just ran Test Connection. Ollama additionally detects install state (running / installed-not-running / not-installed). Subsumes the earlier Ollama-only plan; all four providers share one probe abstraction.

### features.shortcuts-pane-polish
- **Status:** Planned (follow-up polish to the v1.13 Shortcuts redesign)
- **Type:** UX
- **Target:** v1.14
- **Trigger:** Always — captures the two deliberate deferrals from the v1.13 implementation pass.
- **Affects:** `Sources/Settings/Shortcuts/` (the components landed in v1.13)
- **Description:** The v1.13 Shortcuts pane redesign deferred two polish items to keep risk low:
  1. **Popover-style recorder with countdown auto-save.** The plan called for a Raycast-style popover that records a combo with a ~1.5s idle commit (visible keycap pills, live conflict warning). v1.13 instead used `KeyboardShortcuts.Recorder` inline as the chip itself — click-to-record works, but the visual + countdown polish is missing. Adding the popover requires deciding whether to wrap an `NSEvent`-driven recorder or extend `KeyboardShortcuts.Recorder` to render inside a popover container.
  2. **Input-inferred trigger-type detection.** The plan called for the recorder popover to detect single-key vs chord based on what the user pressed (tap a letter alone → single-key mode; hold modifier + key → chord mode). v1.13 instead kept a discreet per-row overflow menu (sliders icon, hover-revealed) for switching trigger type — functional but explicit. The input-inferred version requires an `NSEvent`-driven custom recorder that bridges both modes.

  Both are presentation-layer enhancements; neither blocks the v1.13 ship. Roughly ~150–200 additional LOC if pursued.

### features.help-prompts-hero-illustration
- **Status:** Partially shipped (content done, illustration pending)
- **Type:** UX
- **Target:** v1.13 (small, can ride alongside Shortcuts)
- **Trigger:** Always
- **Affects:** `Sources/Help/Basics/BasicsContent.swift`, `Sources/Help/Basics/HeroIllustration.swift`
- **Description:** The Help → Basics Prompts hero **content** has already shipped — the new `prompts` hero with 7 sub-rows (browse library, use a prompt, default Rewrite, Rewrite with Voice, author your own, pin to picker, intent classifier) replaced the old `articulate` hero. The hero **illustration** is the remaining gap — it currently reuses `illustrationKind: .rewrite` as a placeholder, which shows the old Rewrite-with-Voice flow (mic + "make it formal" + before/after) instead of an illustration that conveys "Prompts is a picker panel; Rewrite is one of many prompts." Outstanding work: add a new `HeroIllustrationKind.prompts` case + `PromptsArt` view that animates a mock prompt-picker panel with Rewrite pinned at the top alongside ~4 other bundled prompts (sourced from `Sources/Prompts/PromptLibrary/`). ~100–150 LOC SwiftUI, no migration risk. Review the rendered animation before committing — this is a polish piece and the first-attempt visual may need tuning.

### features.release-time-model-verification
- **Status:** Planned
- **Type:** Cleanup / Release-process
- **Target:** v1.13+ (alongside or just after AI provider model discovery)
- **Trigger:** Always — needed to keep optimistic-hardcoded fallback model IDs from rotting between releases
- **Affects:** `scripts/release.sh`, new `scripts/verify-ai-defaults.swift` or similar
- **Description:** Each cloud provider's `LLMProvider.defaultModel` is an optimistic hardcoded fallback used (a) as the seed value before the first `/models` probe and (b) as the last-resort default when the probe fails. These IDs go stale silently — if OpenAI deprecates `gpt-5-mini` six months after our release, users on the hardcoded fallback get a broken default until they hit Refresh. Add a release-time verification step that calls each provider's `/models` endpoint with a maintainer-held API key and asserts that every `LLMProvider.defaultModel` is present in the response. Fails the build with a clear "your hardcoded fallback `<id>` is no longer in <provider>'s catalog — update `LLMProvider.swift`" message. Documented manual run option (`swift run jot-verify-ai-defaults`) for the human releaser. Don't block v1.13 on this — ship the AI provider work first, then add verification.

### features.wizard-prompts-panel-step
- **Status:** Planned
- **Type:** UX
- **Target:** v1.13+ (after Shortcuts redesign)
- **Trigger:** Always
- **Affects:** `Sources/SetupWizard/Steps/`, `Sources/SetupWizard/WizardStep.swift`
- **Description:** The Setup Wizard currently has Cleanup and Rewrite-intro steps (plus two live Rewrite demos). Doesn't yet introduce the Prompt Library — new users finish the wizard without learning that 30+ bundled prompts ship with Jot. Add a small "Prompts" step (or extend the existing Rewrite-intro step) that previews the picker panel and the "Browse the library" affordance. Could be a static screenshot-style illustration or a live `PromptPickerPreview` SwiftUI component. Defer until after Shortcuts redesign lands — wizard step changes touch the exhaustive switches in `SetupWizardCoordinator` and `SetupWizardView` and should batch with any other wizard work.

### features.recording-safety
- **Status:** Planned
- **Type:** UX/Feature
- **Target:** After v1.13 Advanced mode testing — scope and design complete, awaiting owner go-ahead to implement
- **Trigger:** Always
- **Plan:** `docs/recording-safety/design.md` (PM spec), `docs/recording-safety/engineering-notes.md` (engineering companion)
- **Affects:** `Sources/Overlay/` (pill subtitle render), `Sources/Recording/RecorderController.swift` + cancel-dispatch path, `Sources/Library/Recording.swift` (draft state — open: schema field vs `transcript == ""` convention), `Sources/Library/RecordingsListView.swift` + Home row template, `Sources/MenuBar/` (skip drafts in Copy Last / Recent Transcriptions / Paste Last Result), `Resources/help-content-base.md` + grounding string in `Sources/AskJot/HelpChatStore.swift`
- **Description:** Two-feature bundle for recording panic. (1) **Pill subtitle showing the user's current stop hotkey** — small secondary-color line under the timer, reads dynamically from `KeyboardShortcuts.getShortcut(for: .toggleRecording)`, adapts to PTT users ("Release [PTT key]"), Transform/Rewrite states ("Esc to cancel"), and unbound state ("Set a hotkey in Settings → Shortcuts"). (2) **Esc panic-save** — Esc during recording stops audio capture, saves the WAV to Recents as a draft (empty transcript, no chime, no paste, no toast), pill transitions to idle silently. Drafts surface in Recents with the existing Retranscribe affordance; on-demand transcription only (no background). Drafts are skipped by menu-bar "Copy Last Transcription" / "Recent Transcriptions" / Paste Last Result; show normally in Recents row list and sparkline visuals. Sub-1s clips are naturally excluded by the recording layer's existing floor. Esc during Rewrite / Transform / voice-instruction capture is unchanged (cancels the LLM call, no audio to save). No migration; new behavior applies to all users immediately. Six "Decisions needed from you" deferred in the PM spec — all non-blocking with proposed defaults.

### features.hide-dock-icon
- **Status:** Planned
- **Type:** UX
- **Target:** Later release (not v1.13). Folded out of v1.13 to keep that release focused on Shortcuts + AI provider work.
- **Trigger:** User request — "only show in menu bar, not in Dock."
- **Plan:** `docs/plans/hide-dock-icon.md` *(to be written when scheduled)*
- **Affects:** `Sources/App/AppDelegate.swift`, `Sources/Settings/GeneralPane.swift`
- **Description:** Add a "Show Jot in the Dock" toggle to Settings → General (default ON). When off, sets `NSApp.setActivationPolicy(.accessory)` **once at app startup**, hiding the Dock icon, app menu, and Cmd+Tab entry — Jot becomes menu-bar-only. **Applies on next launch** (not live-toggle) per product call: cleaner implementation, no mid-session `.regular ↔ .accessory` juggle, no `window.canHide` gotcha, no menu-bar reopen dance. The toggle stores the user's preference; app reads it once at `applicationDidFinishLaunching`. ~30 LOC, low risk, no migration. Toggle UI shows "Restart required for change to take effect" caption next to the setting. Historical context: Jot used to ship as `.accessory + LSUIElement=YES`; that was reverted in 2024 because users couldn't find the app to Force Quit when it wedged. Force Quit (⌥⌘⎋) actually does list accessory apps, so the original concern is largely mitigated — and the menu-bar Quit affordance (already in `JotMenuBarController`) is the canonical escape hatch.

---

## Open · Monitoring

### monitoring.gemini-endpoint-stability
- **Status:** Monitoring
- **Type:** Monitoring
- **Trigger:** Google deprecates `v1beta` of `generativelanguage.googleapis.com`, OR a user reports that Gemini model fetching / chat completion fails after a Google API change.
- **Action when triggered:** Update `LLMProvider.gemini.defaultBaseURL` in `Sources/LLM/LLMProvider.swift` from `https://generativelanguage.googleapis.com/v1beta` to the new path Google publishes. Verify the `/models?key=` and `generateContent` endpoint shapes haven't changed; update the JSON parsers in `Sources/LLM/Probes/GeminiProbe.swift` (post-v1.13) and the chat client if they have.
- **Why no action now:** Google has shipped `v1` (stable) and `v1beta` in parallel for 18+ months. All Google SDK defaults still target `v1beta`. New Gemini features (function calling, system instructions, newer model IDs) land in `v1beta` first and may never graduate. No deprecation notice published. Moving to `v1` proactively would strand features.
- **Reference:** [ai.google.dev — API versions explained](https://ai.google.dev/gemini-api/docs/api-versions)

---

## Open · Bugs

### bugs.test-target-pre-existing-rot
- **Status:** Planned
- **Type:** Bug
- **Target:** v1.13 (clean up before shipping so we can actually run tests)
- **Trigger:** Surfaced by v1.13 implementation agents — the JotTests target fails to compile against `main` even before any v1.13 changes, blocking automated test verification for every parallel agent.
- **Affects:** `Tests/JotHarness/Stubs/StubAppleIntelligence.swift`, `Tests/JotTests/Phase4PatchRegressionTests.swift`
- **Description:** Two stale references in the test target prevent it from compiling, predating all v1.13 work:
  1. `StubAppleIntelligence.swift:21` — `type 'StubAppleIntelligence' does not conform to protocol 'AppleIntelligenceClienting'`. The protocol changed `rewrite(... instruction: String, ...)` to `instruction: String?` and added a `streamChat(...)` requirement; the stub wasn't updated.
  2. `Phase4PatchRegressionTests.swift:456` — `GeneralPane` constructor missing a `hotkeyRouter` parameter the production type now requires.

  Each is a 2–5 line fix. Pre-existing — not introduced by v1.13 — but worth fixing before the v1.13 release so the test suite is actually runnable for regression checks. Wizard prompts panel agent fixed the related `WizardStepID.shortcuts` stale reference in `WizardFlowTests.swift` as part of their work since they were already editing the file; these two remaining issues need their own focused pass.

### bugs.help-infra-prompts-hero-parent-mismatch
- **Status:** Planned
- **Type:** Bug
- **Target:** v1.13 (fix while we're touching Help anyway)
- **Trigger:** Surfaced by the `help-illustration-impl` agent during v1.13 work — Debug builds trip `HelpInfraTests.swift:132` assertion `"Sub-row 'prompt-library' has no parent hero"` at app launch.
- **Affects:** `Sources/Help/Feature.swift:296-306`
- **Description:** `rewriteSubRow(...)` sets `parentHeroId: "articulate"` but the hero is registered with `id: "prompts"` (line 191) since the v1.11 Articulate → Prompts rename. Left-over rename debt — the subrow's parent reference wasn't updated when the hero was renamed. Release builds run fine (asserts compiled out), so this is **not a ship-blocker** — but it blocks Debug-build visual verification of any Help-tab work. Fix: update `parentHeroId: "articulate"` → `parentHeroId: "prompts"` in `rewriteSubRow(...)`. Audit other `parentHeroId` references in the same file in case sibling subrows have the same drift. ~5 LOC fix.

---

## Deferred

### features.byok-token-usage
- **Status:** Deferred
- **Type:** Feature
- **Target:** When users ask for it
- **Description:** Show running token-usage / cost estimate per AI provider in Settings → AI ("This month: ~$X · Y tokens"). Cost-conscious BYOK users care; data is in API response usage headers (OpenAI: `usage` block, Anthropic: `usage`, Gemini: `usageMetadata`, Ollama: none). ~200–300 LOC of its own. Out of scope for v1.13's unified provider discovery work because it's a different data flow and a separate Settings surface. Revisit when users ask, or as a v1.14+ enhancement.

---

## Shipped — unreleased dev tree (v1.12)

These have landed in `main` but haven't been released yet. Listed here for history once v1.12 ships.

### shipped.parakeet-v3-eou-pairing
- **Status:** Shipped (v1.12)
- **Type:** UX
- **Plan:** `docs/plans/v3-eou-pairing.md`
- **Description:** Retired the v3+Nemotron pairing in favor of v3+EOU as the multilingual primary. v3 batch's English output was visibly worse than Nemotron's live preview, creating a "transcript got worse at stop" UX bug. EOU is intentionally lighter so the live preview reads as a rough draft. Migration shim auto-rewrites existing v3+Nemotron users.

### shipped.ja-alias-vocabulary
- **Status:** Shipped (v1.12)
- **Type:** Feature
- **Plan:** `docs/plans/custom-vocabulary-mvp.md` §8–§10
- **Description:** Unlocked custom vocabulary on the Japanese primary via text-layer alias substitution. Real acoustic CTC rescoring is blocked on two upstream FluidAudio gaps (no `CtcJaKeywordSpotter`, no token timings on `TdtJaManager.transcribe`). When those land upstream, swap in the real CTC path (~150 LOC of glue).

### shipped.nemotron-vocab-ui-guidance
- **Status:** Shipped (v1.12)
- **Type:** UX
- **Description:** One-click "Switch to Parakeet v3 + EOU" button in Settings → Vocabulary when Nemotron is the active primary, plus a "Doesn't support custom vocabulary" caveat on the Nemotron picker row. Reflects that Nemotron's streaming pipeline can't supply the token timings the rescorer needs.
