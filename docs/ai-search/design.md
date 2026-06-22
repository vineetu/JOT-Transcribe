# AI Search for macOS Jot — Design Doc

Status: Draft for review (design-only; no code)
Author: planning pass
Date: 2026-06-19
Scope: Bring jot-mobile's transcript search ("better search") to macOS Jot.

This doc is grounded in the already-completed jot-mobile research (treated as ground
truth) and the macOS codebase. File:line citations use repo-relative paths;
mobile paths are prefixed `jot-mobile/`.

---

## 1. Overview & goals

### Goal (v1)
A **better in-list search** over recordings, in-place in the existing Home /
Recordings list. As-you-type, it should find recordings by meaning as well as by
exact substring — typing "rent increase" should surface a recording where the
speaker said "the landlord is raising my monthly payment" even though no word
matches. This is the locked Decision #1: the win is the existing list getting
smarter, not a new panel.

The existing list already has an inline search field and a substring filter:
`Sources/Library/RecordingsListView.swift:292` (`inlineSearch`) and
`Sources/Library/RecordingsListView.swift:74` (`filteredItems`, lowercased
`contains`). v1 augments that filter with a semantic union; the UI surface, the
debounce-free keystroke path, and the row rendering stay where they are.

### Goals
- Semantic (embedding) recall layered on top of the existing substring filter.
- Fully on-device, no telemetry, no new network calls (fits the Key Constraints
  in `CLAUDE.md`: "No telemetry", "Transcription stays on-device").
- Reuse jot-mobile's pure-Swift retrieval layer essentially verbatim
  (EmbeddingGemma service, chunker, cosine scan).
- Additive persistence — do not disturb the existing `Recording` store.

### Non-goals (v1) — these are Phase 2
- A dedicated natural-language "Find" panel.
- Answer synthesis / Q&A over recordings (the BM25 + RRF + LLM "Ask mode"
  in mobile: `jot-mobile/Jot/App/Ask/{AskController,BM25Index,RRFFusion}.swift`).
- Cross-device sync of the index (out of scope per `CLAUDE.md`).
- Bundling Qwen or any answer-generation model (Decision #2: answers route
  through the user's existing provider, and only in Phase 2).

### Locked decisions honored here
1. Primary surface = the search bar in Home / Recordings (in-place).
2. EmbeddingGemma for semantic search; the **existing Jot AI provider**
   (`Sources/LLM/`) for any later synthesized answers — no bundled Qwen.
3. Design doc first; user decides before building.

---

## 2. Data model

### Field correspondence: mobile `Transcript` ↔ macOS `Recording`

| Concept | mobile `Transcript` | macOS `Recording` (`Sources/Library/Recording.swift`) |
|---|---|---|
| stable id | `id: UUID` | `id: UUID` (`@Attribute(.unique)`, line 13) |
| display text | `text` / `cleanedText` / `displayText` | `transcript` (line 17) — the user-facing, post-transform text |
| raw text | (n/a) | `rawTranscript` (line 18) |
| created | `createdAt` | `createdAt` (line 14) |
| duration | `durationSeconds` | `durationSeconds` (line 16) |
| source/type | `source` | (no direct equivalent; macOS has only dictation `Recording` + `RewriteSession`) |

Indexing text on macOS = `recording.transcript` (the displayed text), matching how
the existing substring filter uses `r.transcript` (`RecordingsListView.swift:89`).

### New entity: `RecordingChunk` (SwiftData @Model)

A near-verbatim port of mobile's `TranscriptChunk`
(`jot-mobile/Jot/Shared/Schema/JotSchemaV7.swift:194-238`). Lives in the Library
layer (it is the SwiftData source-of-truth sibling of `Recording`), so
`Sources/Library/RecordingChunk.swift`.

Proposed fields (mirroring mobile exactly so the ported retrieval code compiles
with only a type-name change):

- `id: UUID`
- `recordingID: UUID` — logical (NOT `@Relationship`) join to `Recording.id`.
  Mobile deliberately uses a logical join so chunks are re-buildable independent
  of the parent's lifecycle (`JotSchemaV7.swift:186-188`). Keep that.
- `chunkIndex: Int`
- `text: String` — the chunk's source slice (for highlighting / preview).
- `vectorData: Data` — 256 float32 packed little-endian
  (`JotSchemaV7.swift:180-181`; packing in `ChunkStore.replaceChunks`,
  `jot-mobile/Jot/Shared/DerivedData/ChunkStore.swift:66`).
- `charStart: Int`, `charEnd: Int` — grapheme offsets into `recording.transcript`
  for deep-link / highlight (`jot-mobile/.../TranscriptChunker.swift:44-46`).
- `modelVersion: String` — discriminator, e.g. `"embeddinggemma-300m-256"`
  (`EmbeddingGemmaService.modelVersion`,
  `jot-mobile/Jot/App/Embeddings/EmbeddingGemmaService.swift:45`). Readers filter
  by current version; a model swap writes under a new version and old rows stay
  distinguishable.
- `embeddedAt: Date`
- Denormalized parent fields: `createdAt: Date`, `durationSeconds: Double?`.
  (Mobile also denormalizes `source`; macOS can drop `source` or keep it `nil` —
  there is one recording type. Recommend keeping the field for schema parity but
  always writing `nil`, so the ported `ChunkStore` signature is unchanged.)

No `@Attribute(.unique)` on the join key — mobile explicitly avoids it because
lightweight migration on a new-entity unique constraint is inconsistent
(`ChunkStore.swift:23-24`). Replace semantics are delete-then-insert per
`(recordingID, modelVersion)`.

### Migration implications — FLAG (risk)

macOS Jot's SwiftData store is **unversioned**: the container is built by passing
the model types directly to `ModelContainer(for:)` with no `VersionedSchema` and
no `SchemaMigrationPlan` (`Sources/App/JotComposition.swift:485-498`, model list
`Recording.self, RewriteSession.self, PromptUsage.self, UserPrompt.self,
EnrolledIdentity.self`).

Mobile, by contrast, ships `JotSchemaV7` as a `VersionedSchema` and notes V6→V7
is "purely additive — ONE new @Model entity" (`JotSchemaV7.swift:6`).

On macOS, adding `RecordingChunk.self` to the `ModelContainer(for:)` list is an
**additive, new-entity** change. SwiftData's default lightweight migration handles
a brand-new table without a migration plan — no existing `Recording` column
changes. So the expected path is: add the type to all three
`ModelContainer(for:)` call sites (`JotComposition.swift:486, 496, 503`), and the
new empty table appears on next launch.

- [VERIFY] On the live unversioned store, confirm that adding a new `@Model`
  triggers only additive lightweight migration and does NOT force a destructive
  rebuild of `default.store`. There is already a defensive fallback to an
  in-memory store if the container throws (`JotComposition.swift:499-509`) — that
  fallback would silently mask a migration failure as "empty library", which
  would be a bad UX. Test on a populated store before shipping.
- [DECIDE] Whether to take this moment to introduce a proper `VersionedSchema` +
  `SchemaMigrationPlan` for macOS (closing the gap with mobile and making future
  changes safe), or stay unversioned and just add the type. Recommend: adopt a
  minimal `VersionedSchema` now — the cost is one wrapper file and it removes the
  "destructive rebuild" tail risk for all future schema work, not just this one.

---

## 3. Indexing pipeline

Port mobile's `TranscriptIndexer`
(`jot-mobile/Jot/App/Embeddings/TranscriptIndexer.swift`) as a macOS
`RecordingIndexer` in the Library (or a new `Sources/Search/`) layer. The mobile
pipeline is the template; the four entry points map cleanly.

### 3a. On-save hook (fire-and-forget)
Mobile indexes on `TranscriptStore.append`. macOS's equivalent single save point
is `RecordingPersister.persist(...)`
(`Sources/Library/RecordingPersister.swift:52-76`) — after the `context.save()`
at line 71, fire `RecordingIndexer.index(recordingID: recording.id, text:
transcript)`. This mirrors the existing post-save detached work already in that
method (the `CorrectionProvenance.commit` Task at line 88 and the speaker-timeline
Task at line 116) — so the pattern of "kick a detached Task after save" is
already established here.

Critically, indexing must run **off the main actor**. Mobile uses
`Task.detached(priority: .utility)` so the encode does not hitch the UI
(`TranscriptIndexer.swift:25, 40-43`). `RecordingPersister` is `@MainActor`
(`RecordingPersister.swift:15`), so the same detached pattern is required.

Note: list-row re-transcribe (`RecordingsListView.swift:442 retranscribe`) and
detail-view re-transcribe (`RecordingDetailView.swift:323`) also mutate
`recording.transcript`. Those should re-index too (replace-chunks is idempotent).
- [DECIDE] Re-index on every transcript edit, or only on initial save + manual
  rebuild. Recommend re-index on edit — `replaceChunks` already handles it and a
  stale index is a correctness bug.

### 3b. Background backfill (existing recordings)
At first launch after the feature ships, every pre-existing `Recording` has no
chunks. Mobile handles this with `indexMissing` / `unindexedCountAsync` over
`transcriptIDsMissingChunks` (`TranscriptIndexer.swift:92-139`, `ChunkStore.swift:101`).
Port the same: a one-shot, cancellable, low-priority sweep that indexes only
recordings lacking chunks at the current `modelVersion`. Kick it off after app
launch (e.g. from the composition root or when Home first appears), gated on the
toggle.

### 3c. Manual rebuild
Port `rebuildAll` (`TranscriptIndexer.swift:57-80`) behind a Settings → AI button
("Rebuild search index"), with progress. Needed after a model-version bump or if
the user suspects a stale index. Pairs with `ChunkStore.deleteAll(modelVersion:)`
(`ChunkStore.swift:140`).

### 3d. Gating toggle
Mobile gates the whole pipeline on `AppGroup.isEmbeddingsEnabled` (default ON)
(`TranscriptIndexer.swift:37, 58, 115`; `SemanticSearchController` reads chunks
regardless). On macOS use an `@AppStorage`-backed bool (the existing pattern, e.g.
`Sources/Settings/ShortcutsPane.swift:37-40`), keyed `jot.semanticSearch.enabled`.
See §7 for the default-on vs opt-in decision.

### 3e. Failure handling
Mobile logs-and-swallows per-transcript failures; the backfill + manual rebuild
are the durable backstops (`TranscriptIndexer.swift:34-35, 176-180`). Keep that
posture — a failed embed must never break the save path or surface an error to the
user mid-dictation. Route any diagnostics through the existing `ErrorLog`
(already used in `RecordingPersister.swift:55, 74`), never telemetry.

---

## 4. EmbeddingGemma on macOS

Port `EmbeddingGemmaService`
(`jot-mobile/Jot/App/Embeddings/EmbeddingGemmaService.swift`) and
`TranscriptChunker` (`jot-mobile/Jot/App/Embeddings/TranscriptChunker.swift`)
essentially as-is. Both are pure Swift + Core ML; the only iOS coupling is the
`#if JOT_APP_HOST` guard and the `JotModelContainer.shared` reference (which maps
to the macOS container). Strip/replace those.

### Model package + bundling
Mobile loads via the `CoreMLLLM` package (`import CoreMLLLM`,
`EmbeddingGemmaService.swift:2, 91 EmbeddingGemma.load(bundleURL:)`). macOS would
need:
1. Add the `CoreMLLLM` Swift package as a dependency (analogous to how FluidAudio
   and KeyboardShortcuts are linked: `Jot.xcodeproj/project.pbxproj:112-113`).
2. Bundle the model files: `encoder.mlmodelc` + `model_config.json` +
   `hf_model/tokenizer.json` under `Resources/Models/EmbeddingGemma/`, resolved at
   `<bundle>/Models/EmbeddingGemma/` (`EmbeddingGemmaService.swift:14-18, 112-124`).

### Resources-not-synchronized cost — confirmed
`CLAUDE.md` says `Sources/` is a synchronized folder group, but **`Resources/` is
not**. Verified: `Sources` is a `PBXFileSystemSynchronizedRootGroup`
(`project.pbxproj:87-94`) so new source files are auto-picked-up; but `Resources`
is a plain `PBXGroup` with **explicit per-file `PBXBuildFile` + `PBXFileReference`
entries** (`project.pbxproj:146-176`, e.g. each `common-words-*.txt`). Therefore
bundling the EmbeddingGemma model requires **manual `project.pbxproj` edits**: add
the model directory as a folder reference and a corresponding "in Resources" build
file entry. Mobile sidesteps repeated churn by shipping the model as a *folder
reference* placed out-of-band and gitignored, like the Parakeet models
(`EmbeddingGemmaService.swift:14-17`). Recommend the same on macOS: a folder
reference (blue folder) so the whole `EmbeddingGemma/` tree ships as one node, and
gitignore the binaries (consistent with how speech models are handled — see the
`.mlmodelc` download path for Sortformer, `Sources/.../SortformerHolder.swift:70`).

### ANE / compute units
Mobile loads with `computeUnits` defaulting to `.cpuAndNeuralEngine`
(`EmbeddingGemmaService.swift:90-91`). macOS Jot is Apple-Silicon-only (`CLAUDE.md`
Platform), so the ANE path is always available — no Intel fallback needed. This
matches the existing Parakeet-on-ANE posture.

### Prewarm
Mobile fires a non-blocking prewarm from `JotApp.init`
(`EmbeddingGemmaService.swift:34-38, 70-72`). On macOS, fire
`EmbeddingGemmaService.shared.prewarm()` from the composition root
(`JotComposition`) or AppDelegate launch, so the first search isn't cold. First
load compiles + loads into ANE (seconds); subsequent encodes are ~30-50ms.

### Asymmetric roles (must preserve)
Documents indexed with `role: .document`; queries embedded with `role: .query`
(`EmbeddingGemmaService.swift:53, 76-79`; index side
`TranscriptIndexer.swift:156`; query side `SemanticSearchController.swift:89`).
This is load-bearing for recall — do not collapse the two.

### Chunk token target
Index with `targetTokens: 110`, NOT the chunker's 256 default, because the
bundled model's `max_seq_len = 128` silently truncates longer chunks
(`TranscriptIndexer.swift:143-149`). Port this exact value.

- [VERIFY] EmbeddingGemma model size on disk (the `.mlmodelc` + tokenizer) and
  the resulting DMG-size delta. EmbeddingGemma-300M Core ML is on the order of a
  few hundred MB; this is the single biggest tradeoff for bundle-vs-download (§7).
- [VERIFY] `CoreMLLLM` package exists / is reusable as-is for the macOS target
  (it is mobile's dependency; confirm platform support + license).

---

## 5. Search UX + query path (v1)

### Where it plugs in
The existing list computes `filteredItems` by lowercased substring `contains` over
`r.title` / `r.transcript` (`RecordingsListView.swift:74-116`). v1 keeps that
substring half exactly and **adds a semantic union**, following mobile's hybrid
contract: the controller publishes only the semantic match set; the view composes
`substring ∪ semantic` (`SemanticSearchController.swift:9-18`).

### Controller
Port `SemanticSearchController`
(`jot-mobile/Jot/App/Search/SemanticSearchController.swift`) as a macOS
`@Observable` controller held as `@State` in `RecordingsListView`. It exposes
`semanticMatches: Set<UUID>` (recording IDs) and a `search(query:)` that:
- cancels the in-flight task,
- debounces ~200ms (`SemanticSearchController.swift:84`),
- embeds the query with `role: .query`,
- scans every `RecordingChunk` at the current `modelVersion`, cosine == dot
  (vectors are unit-norm), keeps best score per recording, returns the set of
  recording IDs whose best chunk clears the threshold (`...Controller.swift:117-153`).

### Threshold
Default cosine cutoff **0.50** (precision-leaning), tunable
(`SemanticSearchController.swift:59, 36-43`). Port the value.

### View wiring
- `inlineSearch`'s `TextField` (`RecordingsListView.swift:297`) already binds
  `searchText`. On change, call `controller.search(query: searchText)`.
- In `filteredItems`, change the recording predicate from "substring match" to
  "substring match OR `controller.semanticMatches.contains(r.id)`"
  (`RecordingsListView.swift:87-93`). Because `semanticMatches` is `@Observable`,
  the body recomputes when results land.
- The non-empty-search branch already does an **unlimited** fetch so older items
  surface (`RecordingsListView.swift:80-83, 118-123`); semantic matches across the
  whole library compose naturally with that.
- `RewriteSession` rows: v1 can leave them substring-only (no embeddings), or
  also index them later. Recommend v1 = recordings only (matches the locked scope
  "search over recordings"); rewrites keep their existing substring filter
  (`RecordingsListView.swift:95-105`).

### Result rendering, highlight, deep-link
- Results render in the existing row UI (`RecordingRowView` via the `ForEach` at
  `RecordingsListView.swift:235`). No new result component for v1.
- Substring matches highlight as today (or add light highlighting). Semantic-only
  matches have no literal substring — show the matching chunk's `text` snippet as
  a preview rationale (optional polish for v1).
- Deep-link: tapping a row pushes `Recording` onto the nav path
  (`RecordingsListView.swift:255`) → `RecordingDetailView`
  (`RecordingsListView.swift:156-158`). For semantic hits, pass the best chunk's
  `charStart` so the detail view can scroll/highlight that span.
  `RecordingDetailView` already renders the transcript via
  `SelectableTranscriptText` over `displayedTranscript`
  (`Sources/Library/RecordingDetailView.swift:228, 188`) and `charStart/charEnd`
  are grapheme offsets that reproduce the slice
  (`TranscriptChunker.swift:44-46`). A `ScrollViewReader` + highlight is the
  natural add. [DECIDE] include charStart deep-link in v1 or defer to polish.

### Latency budget (from mobile, Apple Silicon should match or beat)
- Substring: synchronous, instant on keystroke.
- Semantic: ~200ms debounce + 30-50ms query embed + 10-20ms cosine scan ≈
  250-400ms to fill in (`SemanticSearchController.swift:14-17`). The two halves
  are independent — substring shows immediately, semantic arrives a beat later.

---

## 6. The optional answer phase (Phase 2 — not built now)

Decision #2: any synthesized answer routes through the **user's existing
provider**, never a bundled model. macOS already has the full provider-neutral
stack: `Sources/LLM/LLMClient.swift` (actor, line 3) + `LLMConfiguration`
(provider selection: `Sources/LLM/LLMProvider.swift:3-8` —
`appleIntelligence, openAI, anthropic, gemini, ollama`) + `AppleIntelligenceClient`
for on-device. Ask Jot (`Sources/AskJot/`) is the UX precedent for a grounded,
provider-routed chat surface with citations, markdown, and voice input
(`AskJotView.swift`, `ChatState.swift`, `MarkdownRenderer.swift`).

Phase-2 sketch (do not build in Phase 1):
1. Hybrid retrieve: reuse the EmbeddingGemma chunk embeddings AND a BM25 lexical
   index, fused with RRF — port `jot-mobile/Jot/App/Ask/{BM25Index,RRFFusion}.swift`.
2. Feed top-k chunks as grounding context to `LLMClient` via the user's selected
   provider (mirroring Ask Jot's grounding-doc pattern,
   `Sources/LLM/GroundingDocFacts.swift`).
3. Render a synthesized answer with citations that deep-link to the source
   recording + `charStart` (same deep-link machinery as §5).
4. Respect the Ask-Jot-style provider policy: default Apple Intelligence; only
   route to a non-Apple provider when the user explicitly allows it (`CLAUDE.md`
   "Ask Jot has its own provider policy"). The "recordings Q&A" surface should
   adopt the same consent posture so recording content doesn't leave the Mac
   without explicit opt-in.

This phase is where a dedicated NL "Find" panel would also live.

---

## 7. Options & tradeoffs

### A. Bundle EmbeddingGemma vs download on first use
- **Bundle** (mobile's choice): zero first-run network (fits "no surprise network
  calls"), works fully offline immediately; cost = DMG/app size grows by the model
  (hundreds of MB) and explicit pbxproj/Resources edits (§4).
- **Download**: smaller DMG; cost = a new automatic network call (currently the
  only ones are Parakeet download + Sparkle, `CLAUDE.md`), a download-progress UX,
  and integrity/self-heal handling (Jot already has model self-heal machinery for
  speech models, so precedent exists).
- **Recommend: bundle**, matching mobile and the "no surprise network" constraint
  — UNLESS the size delta pushes the DMG past an acceptable threshold ([VERIFY]
  size), in which case mirror the Parakeet download flow.

### B. Semantic-on-by-default vs opt-in
- Mobile defaults embeddings **ON** (`TranscriptIndexer.swift:37` comment "default
  ON").
- On-by-default = best "it just works" search; cost = background indexing CPU/ANE
  on existing libraries at first launch, and (if bundled) the size is already paid.
- Opt-in = user controls when indexing happens; cost = the headline feature is
  hidden behind a toggle most users never find.
- **Recommend: default ON** with a Settings → AI toggle to disable + a "Rebuild
  index" button. Indexing is on-device and silent, consistent with how Jot already
  does post-save background work (speaker timeline, provenance).

### C. Vectors on the `Recording` row vs a sibling chunk table
- A single vector on `Recording` = one row per recording, simplest schema; cost =
  whole-transcript embedding loses precision on long recordings, no chunk-level
  deep-link, no charStart highlight.
- Sibling `RecordingChunk` table (mobile's V7 choice) = chunk-level recall + char
  offsets + model-version discrimination + rebuildable independent of the parent.
- **Recommend: sibling `RecordingChunk` table**, per mobile
  (`JotSchemaV7.swift:194`). This is also what makes the ported retrieval code
  drop in unchanged.

### D. Lexical-only fallback
If EmbeddingGemma fails to load (missing/corrupt model), search must degrade to
the existing substring filter, not break. The hybrid contract already gives this
for free: `semanticMatches` stays empty, the substring union still works
(`SemanticSearchController.swift:9-14`). **Recommend: explicit graceful
degradation** — never block the search field on the embedder.

---

## 8. Privacy / performance / scale

### Privacy
- 100% on-device: bundled model + local cosine scan, no network. Aligns with
  `CLAUDE.md` "No telemetry" and "Transcription stays on-device". The only
  automatic network calls remain Parakeet download + Sparkle (if model is
  bundled, even the embedder adds none).
- No new analytics or pings. Diagnostics go through `ErrorLog` only.
- Phase 2 answer synthesis is the only path that *could* send recording text off
  device, and only via the user's explicitly-configured provider, with Ask-Jot's
  consent gate (§6).

### Vector storage size
256 float32 = 1024 bytes per chunk vector, plus the chunk `text` copy + denorm
fields. A typical short dictation = 1 chunk; longer recordings = a handful. Order
of magnitude: a library of a few thousand recordings → low tens of MB of chunk
rows. Mobile flags very large libraries (~10k+) may eventually want a streaming
cosine variant (`SemanticSearchController.swift:38-43`); not a v1 concern for a
desktop dictation app.

### Brute-force cosine latency
Linear scan over all chunks per query. Mobile measures 10-20ms at its scale on
mobile silicon (`SemanticSearchController.swift:16`); Apple Silicon desktop should
be equal or faster. No ANN index needed for v1. If a power user's library grows
huge, the streaming/ANN variant is a later optimization, not a v1 blocker.

### Indexing cost
Encode is the expensive step (ANE), run off-main, utility priority, fire-and-forget
— so it never hitches dictation or scrolling (§3). First-launch backfill is the
only burst; it's cancellable and low-priority.

---

## 9. Open questions / [DECIDE] / [VERIFY]

- [VERIFY] EmbeddingGemma model availability + **license** for bundling in a
  shipped macOS app (Gemma terms). This gates the whole approach.
- [VERIFY] EmbeddingGemma Core ML model **size on disk** and the DMG-size delta
  (drives bundle-vs-download, §7A).
- [VERIFY] `CoreMLLLM` package is usable as-is on the macOS target (platform +
  license), or whether the loader needs porting.
- [VERIFY] SwiftData migration safety: adding `RecordingChunk.self` to the
  **unversioned** `ModelContainer(for:)` (`JotComposition.swift:485-498`) performs
  only additive lightweight migration on a populated `Recording` store and does
  not trigger the in-memory fallback (`JotComposition.swift:499-509`) that would
  mask the failure as an empty library.
- [DECIDE] Adopt a proper `VersionedSchema` + `SchemaMigrationPlan` for macOS now
  (recommended) vs stay unversioned and just add the type (§2).
- [DECIDE] Semantic search **default ON** (recommended) vs opt-in (§7B).
- [DECIDE] Reuse mobile's **exact** `RecordingChunk` schema including the `source`
  field (recommended for code parity; write `nil`) vs trim it.
- [DECIDE] Re-index on every transcript edit (recommended) vs only on save +
  manual rebuild (§3a).
- [DECIDE] Include `charStart` deep-link + highlight in detail view in v1
  (recommended polish) vs defer.
- [DECIDE] Index `RewriteSession` rows in v1, or recordings-only (recommended,
  matches locked scope) (§5).
- [DECIDE] Bundle vs download the model (recommend bundle unless size is
  prohibitive) (§7A).

---

## 10. Phasing

### Phase 1 (this build) — better in-list search
1. `RecordingChunk` @Model + register in the three `ModelContainer(for:)` sites
   (and the migration-safety verification / optional `VersionedSchema`).
2. Bundle EmbeddingGemma (pbxproj/Resources folder reference + `CoreMLLLM`
   package) + prewarm from the composition root.
3. Port `TranscriptChunker` and `EmbeddingGemmaService` (drop `#if JOT_APP_HOST`,
   point at the macOS container).
4. Port `TranscriptIndexer` → `RecordingIndexer`: on-save hook in
   `RecordingPersister.persist`, background backfill, manual rebuild; toggle-gated.
5. Port `SemanticSearchController`; wire `searchText` → `search(query:)` and
   `filteredItems` → substring ∪ semantic in `RecordingsListView`.
6. Settings → AI: enable toggle + "Rebuild index" button.
7. (Polish) charStart deep-link + highlight in `RecordingDetailView`.

### Phase 2 (later) — NL Find panel + provider-answered Q&A
1. Port BM25 + RRF (`jot-mobile/Jot/App/Ask/{BM25Index,RRFFusion}.swift`),
   hybrid retrieve over the existing chunk embeddings.
2. Route grounded context through the existing `LLMClient` /
   `LLMConfiguration` provider (Apple Intelligence default; Ask-Jot consent gate
   for non-Apple).
3. Dedicated NL "Find" panel surface (Ask Jot is the UX precedent) with
   citation deep-links.

---

## Appendix — key files

macOS (this repo):
- `Sources/Library/Recording.swift:11-51` — the `Recording` @Model to mirror.
- `Sources/Library/RecordingPersister.swift:52-76` — the save hook + post-save
  detached-Task precedent.
- `Sources/Library/RecordingsListView.swift:74-116, 292-321` — `filteredItems`
  substring filter + `inlineSearch` field (the search surface).
- `Sources/Library/RecordingDetailView.swift:188-228` — transcript render +
  `SelectableTranscriptText` (deep-link/highlight target).
- `Sources/App/JotComposition.swift:485-509` — `ModelContainer(for:)` sites (add
  `RecordingChunk.self`).
- `Sources/LLM/LLMClient.swift` + `Sources/LLM/LLMProvider.swift:3-8` +
  `Sources/AskJot/` — Phase-2 provider routing + UX precedent.
- `Jot.xcodeproj/project.pbxproj:87-94` (Sources synchronized) vs `146-176`
  (Resources explicit) — the bundling cost.

jot-mobile (ground truth to port):
- `jot-mobile/Jot/Shared/Schema/JotSchemaV7.swift:194-238` — `TranscriptChunk`.
- `jot-mobile/Jot/Shared/DerivedData/ChunkStore.swift` — chunk read/write.
- `jot-mobile/Jot/App/Embeddings/EmbeddingGemmaService.swift` — embedder.
- `jot-mobile/Jot/App/Embeddings/TranscriptChunker.swift` — chunker.
- `jot-mobile/Jot/App/Embeddings/TranscriptIndexer.swift` — indexing pipeline.
- `jot-mobile/Jot/App/Search/SemanticSearchController.swift` — query path.
- `jot-mobile/Jot/App/Ask/{AskController,BM25Index,RRFFusion}.swift` — Phase 2.

---

## 11. Round-1 adversarial review — resolutions (SUPERSEDES conflicting earlier text)

Verdict: **not buildable as-is**; architecture/port sound, but two `[VERIFY]`s resolved
AGAINST the plan and must be settled first. Resolutions:

- **[BLOCKER B1 — macOS version floor] CoreMLLLM requires macOS 15; Jot targets macOS 14.**
  `CoreML-LLM/Package.swift` declares `.macOS(.v15)`; `Jot.xcodeproj` is `MACOSX_DEPLOYMENT_TARGET=14.0`.
  SPM won't resolve it into a 14.0 target. Also: jot-mobile is iOS-only (no macOS target in
  `project.yml`) — so this is the FIRST-ever macOS build of this stack, not a proven port.
  **→ DECISION NEEDED (user):** (a) raise Jot's floor to **macOS 15** (drops macOS 14 users —
  conflicts with the current CLAUDE.md "macOS 14+" commitment), OR (b) **vendor only the
  EmbeddingGemma loader** (`Gemma3EmbeddingGemma.swift` + tokenizer, a thin Core ML +
  swift-transformers wrapper — swift-transformers itself is `.macOS(.v13)`, fine) and DON'T
  take the CoreMLLLM package, so no macOS-15 floor. **Recommend (b)** — keeps macOS 14, smaller
  dependency surface. Gates the whole feature.
- **[BLOCKER B2 — don't bundle the model; DOWNLOAD it].** The doc's "bundle like Parakeet"
  premise is false: Parakeet/Sortformer are **downloaded at runtime** to
  `~/Library/Application Support/Jot/Models/` (`ModelCache.swift:34-44`,
  `SortformerHolder.swift:67-100`), never bundled — zero bundled-model precedent in the
  pbxproj. EmbeddingGemma is **328 MB** (encoder.mlmodelc 295 MB + tokenizer 33 MB);
  bundling ~triples the DMG + every Sparkle delta for an opt-in feature.
  **→ RESOLVED: download the embedder via Jot's existing `ModelDownloader`/`ModelCache`/
  self-heal + `.downloading`/`.downloadFailed` UI** (reuse, don't reinvent). This also voids
  the "Resources/ not synchronized → manual pbxproj edits" cost (model lives in App Support).
  Adds one automatic network call — already an allowed call class (model download); update the
  CLAUDE.md privacy list to mention it.
- **[MAJOR M2 — migration safety] HARDEN before `RecordingChunk` lands.** Store is unversioned
  (`JotComposition.swift:485-498`) with an in-memory fallback (`:499-509`) that would mask a
  real migration failure as a SILENT EMPTY LIBRARY. Adding a new `@Model` is normally
  lightweight-migration-safe (happy path OK), but: (1) make the production fallback **log to
  ErrorLog / surface a non-destructive error** instead of silently swallowing; (2) if adopting
  a `VersionedSchema` now (recommended for future safety), it must reproduce existing entities
  EXACTLY (names/attrs/`.unique`) or it self-triggers a destructive rebuild; (3) **[VERIFY] on a
  populated store is a GATING step, not a checkbox.**
- **[MAJOR M1 — field name] join field is `transcriptID`** in mobile (`JotSchemaV7.swift:197`),
  not `recordingID`. "Compiles with only a type rename" is wrong — rename field + all refs, or
  keep `transcriptID` on macOS for a truly verbatim port. Decide explicitly.
- **[MAJOR M3 — observed read]** `filteredItems` must read `controller.semanticMatches`
  UNCONDITIONALLY on the rendered path (not behind the `searchText.isEmpty` early-return), or
  SwiftUI won't register the dependency and async semantic results won't trigger recompute.
- **[MAJOR M4 — no existing debounce]** macOS search is instant-per-keystroke today; the
  semantic path needs a NET-NEW debounce + task-cancellation harness (port mobile's 200ms) —
  not an existing seam. Substring stays instant.
- **[MINOR] ANE contention:** pause/yield the first-launch backfill while
  `RecorderController.state != .idle` (Parakeet wants the ANE during dictation).
- **[MINOR] Pin the exact model artifact** (the 328 MB 256-dim/128-seq-len packaging) — the
  `modelVersion` string + `targetTokens:110` headroom depend on that config, not just
  "EmbeddingGemma-300M".
- **[MINOR] charStart deep-link** is net-new (no `ScrollViewReader`/charStart in
  `RecordingDetailView`) — keep deferred/polish.
- **[OPEN — [VERIFY]] Gemma license:** redistribution allowed with attribution + use-policy
  pass-through; needs a real license check whether downloaded or bundled. Gate.

**Verified sound (kept):** transcript text is FINAL at persist time (transform runs before
`lastResult`; the vocab async-transform race does NOT apply); `RecordingPersister.persist` is
the single save point with an established post-save detached-Task pattern; `Recording` has all
fields the chunker needs (id/transcript/createdAt/durationSeconds); substring search surface
composes cleanly with a semantic union; mobile retrieval internals (asymmetric roles, 110-tok
chunks, 256-dim, 0.50 threshold, RRF, backfill) all confirmed; scale/perf fine (brute-force
cosine, tens of MB) — no ANN for v1; Phase-2 provider LLM stack exists.

**Net:** resolve B1 (recommend: vendor the loader, keep macOS 14) + B2 (download, don't
bundle) + harden M2 migration, and the rest is a clean, mostly-verbatim port. Phase 1 =
download embedder + index on save + the search-bar semantic union. Phase 2 = provider-answered
NL find with citations.

### DECISION (user, 2026-06-20): raise deployment target to macOS 15
B1 resolved: **adopt CoreMLLLM as-is and raise `MACOSX_DEPLOYMENT_TARGET` 14.0 → 15.0**
(user chose the OS bump over vendoring the loader). Ripple effects to handle as part of the
build (not optional):
- `Jot.xcodeproj` `MACOSX_DEPLOYMENT_TARGET = 15.0`; `Resources/Info.plist`
  `LSMinimumSystemVersion = 15.0`.
- Update the **macOS 14+ → macOS 15+** commitment everywhere it's stated: `CLAUDE.md`,
  `docs/design-requirements.md`, `README.md`, the website capabilities/footer, and call it out
  in the next release notes (existing macOS-14 users will stop receiving updates via Sparkle —
  the appcast `minimumSystemVersion` should be set so they aren't offered an unrunnable build).
- B2 still applies: **download** the 328 MB EmbeddingGemma model (don't bundle), via the
  existing `ModelDownloader`/`ModelCache`; add it to the privacy "allowed network calls" list.
- M2 migration hardening still required before `RecordingChunk` lands.

### DECISIONS (user, 2026-06-20): indexing posture
- **Semantic search ships ON by default** (the toggle is opt-OUT). We index everyone; first
  run downloads the model (non-blocking) + begins indexing.
- **Gentle incremental backfill of the whole existing library** — small batches, low priority,
  ONLY while `RecorderController.state == .idle` (never competes with a live dictation / the
  ANE Parakeet needs), with inter-batch delay; progress persisted so it resumes across launches
  and only drains the un-indexed remainder. New recordings still index on save.
- **Indexing progress is ADVANCED-ONLY** — no banners/spinners for normal users (they just get
  better search silently); the "indexing N of M" UI is gated behind the `AdvancedFlag`.
