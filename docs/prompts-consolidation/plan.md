# Prompts Consolidation — Plan

Consolidate Cleanup + Rewrite prompt management into the unified Prompts panel
and make the default (TAP) Rewrite prompt user-selectable.

## Current architecture (confirmed by reading)

- TAP on the Rewrite hotkey (`⌥/`) → `HotkeyRouter` `onTap` → `RewriteController.rewrite()`
  (no override) → `service.rewrite(instruction: nil)` → `LLMClient.rewrite` uses
  `config.rewritePrompt` (`@AppStorage "jot.llm.rewritePrompt"`) as the entire system prompt.
- HOLD on the Rewrite hotkey → `PromptPickerController.open()` → pick a row →
  `RewriteController.rewrite(systemPromptOverride: prompt.body, pickedTitle:)`.
- Cleanup (Transform) runs automatically post-dictation when `jot.transformEnabled`
  is on, reading `config.transformPrompt` (`@AppStorage "jot.llm.transformPrompt"`).
  Edited today via a `CustomizePromptDisclosure` in `RewritePane` "Cleanup" section.
- `PromptStore` (@MainActor ObservableObject) is the single prompt source of truth:
  bundled (`prompt-library.json`) + user (SwiftData `UserPrompt`) + usage
  (`PromptUsage`: pinned/recent). It is in the SwiftUI environment.

## Feature A — Selectable DEFAULT Rewrite prompt

Storage: `@AppStorage("jot.prompts.defaultPromptID")` lives on `PromptStore`.
References a prompt id (bundled JSON id OR user UUID string). Empty = "unset".

PromptStore additions:
- `defaultPromptID` (published-ish via objectWillChange), `isDefault(_:)`,
  `setDefault(_:)`, `clearDefault()`, `defaultPrompt() -> Prompt?` (returns nil if
  unset OR the referenced id no longer resolves — safe fallback).

TAP wiring: add `defaultRewriteResolver: (@MainActor () -> (body:String,title:String)?)?`
to `RewriteController`. In `rewrite()` (no-arg tap path), if the resolver yields a
prompt, route through the existing `runFixed(systemPromptOverride:instructionLabel:)`
path; otherwise behave exactly as today (`rewritePrompt` no-instruction fallback).
Composition sets the resolver from `promptStore.defaultPrompt()` after promptStore
is built. Fallback => zero behavior change for users who never set a default.

UI:
- PromptsPane: "Set as default" affordance + visible "Default" badge on every
  prompt row (bundled, user, pinned). A "Clear default" path via toggling off.
- PromptPickerView/ViewModel: `⌘D` action + footer hint to promote the focused
  prompt to default; wired through `PromptPickerController` → `store.setDefault`.

## Feature B — Cleanup prompt moves into the Prompts panel

Keep automatic trigger: `transformEnabled` toggle stays in `RewritePane`; the
`transform()` pipeline keeps reading `config.transformPrompt`. NO change to the
transform invocation or storage key — so backward compat is automatic (users who
customized `jot.llm.transformPrompt` keep their text; it is the same key).

- Add a "Cleanup" section at the top of PromptsPane with an editable
  `CustomizePromptDisclosure` bound to `config.transformPrompt`
  (default `TransformPrompt.default`). This is the new home for editing the text.
- Remove the Cleanup `CustomizePromptDisclosure` from `RewritePane` (toggle stays).
  Repoint the `cleanup-prompt` deep-link anchor to Prompts (Settings popover deep
  link). Keep `rewritePrompt` editing where it is (the "Shared system prompt" used
  by the no-instruction fallback / when no default prompt is selected).

Migration: none needed for prompt text — both keys are preserved verbatim and read
from the same place. The only new key is `jot.prompts.defaultPromptID` (additive).

## Files

- `Sources/PromptLibrary/PromptStore.swift` — default-prompt storage + API.
- `Sources/Rewrite/RewriteController.swift` — resolver + tap routing.
- `Sources/App/JotComposition.swift` — wire resolver from promptStore.
- `Sources/Settings/PromptsPane.swift` — Cleanup section + Set-as-default/badge.
- `Sources/PromptLibrary/PromptPickerView.swift` / `PromptPickerViewModel.swift` /
  `PromptPickerController.swift` — ⌘D set-as-default.
- `Sources/Settings/RewritePane.swift` — remove Cleanup disclosure; keep toggle.
- `docs/features.md` — user-visible doc updates.

No new Resources/ files (avoids the non-synchronized pbxproj edits). No JSON change.
