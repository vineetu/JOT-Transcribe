# Recordings detail redesign + Home infinite scroll

## Feature overview

Two user-visible changes to the Library surfaces:

1. **Full redesign of the detail views** for both dictation **transcripts**
   (`RecordingDetailView`) and **rewrite sessions** (`RewriteSessionDetailView`).
   Today they render content as *code* — 13pt **monospaced** text inside a
   `GroupBox → ScrollView` capped at 180–320pt, nested inside the page's own
   `ScrollView` (scroll-within-scroll). It reads like a terminal, wraps at a
   too-narrow width (an `NSTextView` `sizeThatFits` measurement bug), and fights
   the user. The redesign turns the detail into a **reading surface**.

2. **Infinite scroll on the Home/Recents + Library list.** Today
   `RecordingsListView` is hard-capped at 50 rows (`@Query.fetchLimit`); anything
   older never appears (except during search). Replace with: start at 30 rows,
   auto-load 30 more when the user scrolls near the bottom.

## Background / current state (cited)

- `RecordingDetailView.swift:38-51` — page `ScrollView` → `VStack(spacing:20)` →
  `.frame(maxWidth:760)`. Blocks: `header`, `playbackBlock`, `transcriptBlock`,
  `CorrectionReviewSection`.
- `RecordingDetailView.swift:197-235` — transcript in a `GroupBox { ScrollView {…} }`
  with `.frame(minHeight:180, maxHeight:320)`.
- `SelectableTranscriptText.swift:44,105` — `NSFont.monospacedSystemFont(ofSize:13)`;
  `sizeThatFits` falls back to `nsView.bounds.width` when the proposed width is nil
  (`:86`) → narrow wrap.
- `WaveformView.swift` — placeholder stripe + apologetic caption "Waveform
  rendering arrives in a later release".
- `RewriteSessionDetailView.swift:80-132` — three `GroupBox` panes (Selected text /
  Instruction / Rewritten output), all monospaced.
- `CorrectionReviewSection.swift` — vocab-gate corrections (CHANGED/KEPT badges,
  chips, undo) embedded under the transcript.
- `RecordingsListView.swift:23-44,28` — `@Query` with static `fetchLimit = 50`
  for each kind; merge + cap to 50 (`:122-130`). Search path uses unlimited
  `context.fetch` (`:133-145`).
- Call sites: `HomePane.swift:36` (Recents, with topContent), `LibraryPane.swift:8`
  (plain). Pagination lives inside `RecordingsListView` so both benefit.

## Design ethos (preserve)

Native macOS, restrained: system fonts for UI chrome, `.primary/.secondary/
.tertiary`, `Color.accentColor`, opacity tints (`0.06`, `0.12`), continuous
corner radii, `.thinMaterial`, spring/ease motion that respects
`accessibilityReduceMotion`, 760pt page measure. The **only** ethos shift: stop
using monospace for *content*; treat transcript/output as prose.

## Decisions (locked with user)

| Decision | Choice |
|---|---|
| Body content font | **New York serif** (`design: .serif`), ~15.5pt, line spacing 6 |
| Reading measure | ~680pt text column inside the 760pt page |
| Scrolling | **Single** page scroll; remove inner capped GroupBox/ScrollView |
| Waveform | **Remove** the stub + caption; ship a slim player bar now |
| Rewrite layout | **Stacked panes**: Instruction → Original → Rewritten (no diff) |
| In-transcript vocab | **Inline selection popover** ("＋ Add 'X' to Vocabulary"), right-click kept as fallback |
| Home list | **Infinite scroll**: 30 initial, +30 near bottom |

## Implementation plan (pseudo only)

### A. Reading surface — serif, single-scroll, width-correct

`SelectableTranscriptText` keeps the `NSTextView` (needed for selection →
vocab), but:

- Font → New York serif:
  ```
  base = NSFont.systemFont(ofSize: 15.5)
  desc = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
  font = NSFont(descriptor: desc, size: 15.5) ?? base
  ```
- `sizeThatFits`: when proposed width is nil/non-finite, fall back to a sane
  measure width (e.g. 680) instead of the tiny initial `bounds.width`. Keep the
  used-rect height calc.
- Remove the surrounding `GroupBox`/inner `ScrollView`/`maxHeight:320`. The
  transcript flows in the page `ScrollView`; the text view reports full height.
- Labeled (speaker) + raw paths also switch to serif body; raw/original stays
  the same prose font (the "Show original" toggle still flips text).

### B. Inline selection popover

In `SelectableTranscriptText.Coordinator`, adopt `textViewDidChangeSelection`:

```
func textViewDidChangeSelection(_:):
   sel = trimmedSelection()
   if sel.isEmpty { publish(selectionRect: nil); return }
   r = layoutManager.boundingRect(forGlyphRange: selectedGlyphRange,
                                  in: textContainer)         // textview coords
   publish(selectionRect: r, selectedText: sel)
```

The representable publishes `@Published selectionRect: CGRect?` +
`selectedText`. The SwiftUI parent overlays a small capsule affordance,
positioned at the rect's top-leading (clamped on-screen), via
`.overlay(alignment:.topLeading){ … }.offset(...)`. Tap → existing
`addSelectionToVocabulary` + clear selection (hides the affordance).
NSTextView is flipped (origin top-left) so y maps directly to SwiftUI.
Right-click "Add to Vocabulary" stays as the reliable fallback.

Risk: coordinate conversion + overlay positioning is the trickiest piece. The
right-click path guarantees the feature works even if the popover needs polish.
Verify via the off-screen hosting-window shot harness + a live build.

### C. Slim player + shared scaffold

- Delete `WaveformView` usage; replace `playbackBlock` with a slim
  `HStack { play/pause · Slider · "m:ss / m:ss" }`. `AudioPlaybackController`
  unchanged. (`WaveformView.swift` can stay in the tree, unused, for the future
  real renderer — or be removed; remove the stub caption regardless.)
- Extract a shared `DetailScaffold` (title field + meta row + slotted content)
  used by both detail views for a consistent header/measure.

### D. Recording detail layout (top → bottom, single scroll)

```
DetailScaffold:
  TextField(title)                          // 20 semibold, plain
  meta row: date · duration · modelName     // 12 secondary, monospacedDigit for nums
  slim player (recordings only)
  transcript prose (serif, full measure, selectable, inline-popover)
    + raw/labeled toggle in meta area
  CorrectionReviewSection (restyled to match: lighter, inline, no heavy GroupBox)
  vocab-add confirmation capsule (.thinMaterial) — keep
```

`recording.modelIdentifier` surfaces in the meta row (currently unused in UI).

### E. Rewrite detail layout (stacked panes, serif)

```
DetailScaffold:
  TextField(title)
  meta row: date · flavorLabel · modelUsed
  section "Instruction"   → instructionText  (quiet, smaller serif)
  section "Original"      → selectionText     (serif body)
  section "Rewritten"     → output            (serif body, emphasized)
```

Each section is a labeled prose block (12 semibold secondary label + serif
body), no inner scroll, no height cap — flows in the page scroll.

### F. Home infinite scroll

Move pagination *inside* `RecordingsListView`:

```
struct RecordingsListView:
   @State visibleLimit = 30
   body: PagedLibraryList(visibleLimit: visibleLimit,
                          search: searchText,
                          onLoadMore: { visibleLimit += 30 }, …)

struct PagedLibraryList:                      // dynamic @Query via init
   @Query recordings ; @Query rewrites
   init(visibleLimit, …):
       rd = FetchDescriptor<Recording>(sort:.reverse); rd.fetchLimit = visibleLimit
       _recordings = Query(rd)                // same for rewrites
   // merge + cap to visibleLimit (unchanged logic, dynamic N)
   // last row .onAppear: if !searching && merged.count >= visibleLimit { onLoadMore() }
```

- Bumping `visibleLimit` re-inits `PagedLibraryList` with a larger `fetchLimit`
  → `@Query` refetches → **live updates preserved** (new recordings still appear).
- Over-fetch is ≤2×N (top-N per kind), acceptable.
- Search path keeps unlimited fetch (bypasses `visibleLimit`).
- Stop condition: when a load doesn't grow `merged.count` past the trigger, the
  last-row `.onAppear` simply stops bumping.

## Files touched

- `Sources/Library/SelectableTranscriptText.swift` — serif font, width fix,
  selection publishing for the inline popover.
- `Sources/Library/RecordingDetailView.swift` — single-scroll, slim player,
  serif transcript, inline popover overlay, scaffold.
- `Sources/Library/RewriteSessionDetailView.swift` — stacked serif panes, scaffold.
- `Sources/Library/RecordingsListView.swift` — extract `PagedLibraryList`,
  `visibleLimit` pagination.
- `Sources/Library/WaveformView.swift` — remove stub caption (or drop usage).
- `Sources/Vocabulary/CorrectionReviewSection.swift` — restyle to the lighter
  inline treatment (no heavy GroupBox), serif where it shows transcript context.
- New (optional): `Sources/Library/DetailScaffold.swift`, a small
  `SelectionAddAffordance` view.

## Verification

- Off-screen hosting-window shot harness (`VocabShots`-style) for: recording
  detail (serif transcript, slim player, selection affordance), rewrite detail
  (stacked panes), corrections.
- Live Sony build installed to /Applications; manual scroll-to-load + select-to-add.
- Build must stay green (xcodebuild app target).

## Out of scope

- Real waveform renderer (still a later release).
- Word-level rewrite diff (chose stacked panes).
- Changing the list row design (`RecordingRowView`) beyond pagination.
