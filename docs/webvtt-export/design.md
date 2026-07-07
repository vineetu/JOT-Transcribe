# Export transcript as WebVTT (with speaker labels)

**Status:** design — awaiting independent review. Not implemented.
**Ask (user):** export a recording's transcript into a format that carries speaker labels. Chosen format: **WebVTT** (`.vtt`).

## 1. Why WebVTT fits
WebVTT is the web-standard caption format and has first-class **speaker voice tags** (`<v Speaker Name>`), plus per-cue timestamps. We already store everything it needs: `Recording.speakerTimeline` decodes to `[SpeakerTimelineSegment { speakerLabel, startSec, endSec, text }]` (`Sources/Diarization/SpeakerTimeline.swift:15`). So a diarized recording maps 1:1 to WebVTT cues — no new data.

## 2. Output shape
```
WEBVTT

1
00:00:00.000 --> 00:00:12.340
<v Speaker 1>Hi everyone, thanks for joining the call today.

2
00:00:12.340 --> 00:00:20.100
<v Vineet>From my side, the backend work is nearly complete.
```
- One cue per `SpeakerTimelineSegment`, ordered by `startSec`.
- Timestamp format `HH:MM:SS.mmm` (WebVTT requires the `.mmm` milliseconds; hours optional but always emit for safety).
- Voice tag `<v LABEL>` prefixes the cue text — LABEL is the (possibly renamed) `speakerLabel`.
- **Escaping (WebVTT payload rules):** in cue text and inside the voice tag, escape `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`. A stray `-->` inside text is illegal in a cue — replace the literal `-->` sequence in text with `-&gt;`. Labels with `>` (rare) get escaped so the tag stays well-formed.

## 3. Non-diarized recordings (no `speakerTimeline`)
Most recordings have no timeline (never diarized). Two honest choices:
- **(chosen) Single cue** spanning `00:00:00.000 --> <duration>` with the full transcript, no `<v>` tag. Still a valid `.vtt` a player accepts; just no per-turn timing/speakers (we have neither for a plain transcript — no word timestamps exist).
- Reject export unless diarized. Rejected — needless friction; a single-cue VTT is a fine "export my transcript" result.

Duration source: `recording.durationSeconds`. If it's 0/unknown, emit `00:00:00.000 --> 00:00:00.000` (degenerate but valid) rather than fail.

## 4. Where it lives (UI)
A new **Export** affordance in `RecordingDetailView`'s toolbar (`toolbarContent`, `RecordingDetailView.swift:437`). The toolbar already has Copy · Re-transcribe · Detect speakers · Reveal · Delete. Add an **Export button** (`square.and.arrow.up`) → `NSSavePanel`:
- `allowedContentTypes = [UTType(filenameExtension: "vtt")! ]` (or `.init(exportedAs:)`); default `nameFieldStringValue` = a sanitized `recording.title` + `.vtt`.
- On save, write the formatter's string to the chosen URL (UTF-8). Errors → the same inline-error idiom the view already uses.
- **Disabled when** `displayedTranscript.isEmpty` (nothing to export), mirroring how Copy/Re-transcribe gate on state.

Given the toolbar is getting busy (6 items), a defensible alternative is folding Copy + Export into a single **menu** ("Copy transcript" / "Export as WebVTT…"). Open question for review: separate toolbar button vs. a share/export menu. Leaning separate button for discoverability + one-click.

## 5. The formatter (pure, testable)
A pure function, engine-agnostic, no view/model coupling — lives next to the timeline types (`Sources/Diarization/`) or a small `Export/` helper:
```
enum WebVTTExporter {
    // Diarized: cue-per-segment with <v> tags.
    static func vtt(segments: [SpeakerTimelineSegment]) -> String
    // Fallback: single cue, whole transcript, no speaker tag.
    static func vtt(fullTranscript: String, durationSec: Double) -> String
    // timestamp(_ sec: Double) -> "HH:MM:SS.mmm"; escape(_:) per §2.
}
```
`RecordingDetailView` picks the diarized overload when `recording.speakerTimeline` decodes to a non-empty payload, else the fallback. Pure formatter → trivially unit-testable (a DEBUG `WebVTTExporterTests.runAll()` like the existing Help infra tests).

## 6. Blast radius — SMALL
- New `WebVTTExporter` (pure formatter) + optional DEBUG test.
- One toolbar button + an `NSSavePanel` save action in `RecordingDetailView` (reuses existing error-surfacing).
- Decode `speakerTimeline` (the view already decodes it to render labeled turns — reuse that decoded value, don't re-decode).
- No model changes, no migration, no pipeline touch.

## 7. Risks / open questions
- **R1 — timestamp correctness:** off-by-formatting (missing ms, wrong hour rollover) makes players reject the file. Unit-test `timestamp()` at 0, 59.999, 3600+, 5932s.
- **R2 — escaping:** unescaped `<`/`&`/`-->` in transcript text produces an invalid cue. Test with text containing `<`, `&`, and a literal `-->`.
- **R3 — label with spaces/unicode** in `<v Vineet Sriram>` — WebVTT allows spaces in voice-tag names; just escape `<>&`. Verify a renamed multi-word label round-trips.
- **Open:** toolbar button vs. Copy/Export menu (§4). Filename sanitation (strip `/`, control chars) for the save panel default.
