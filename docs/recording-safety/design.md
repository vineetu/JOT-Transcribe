# Recording safety

A product spec for two same-release fixes that both address "recording panic" — the situation where the user is mid-dictation and either (a) forgot which hotkey stops the recording or (b) panic-pressed Escape and lost their audio. Ships as one bundle.

---

## Problem statement

The recording pill (the Dynamic Island-style indicator that grows from under the notch while you're dictating) is intentionally minimal. It shows a red pulsing dot, a calm audio waveform, an `mm:ss` timer, and the word "Jot." Beautiful, but functionally underspecified at the exact moment the user needs guidance the most: while they're holding a recording open.

Two failure modes share the same root cause — the user knows they want to *stop* the recording but isn't sure how:

1. **Forgot the hotkey.** "I bound it to something a week ago. Was it Caps Lock? ⌥Space? ⌃⌥Space? Let me think while audio keeps recording…" The pill doesn't remind them. The natural-but-wrong move is to hit Escape — the universal "get me out of this" key.

2. **Panic-pressed Escape and lost the audio.** Escape is wired to *cancel* the recording. Today, that means: stop capture, throw the audio away, no transcription, no row in Recents. The recording is gone. For a 30-second dictation the user just spent thinking through, this is a small disaster — there's nothing to recover.

Both failures compound: a user who can't remember the stop hotkey reaches for Escape, hits Escape, and loses their work. The mistake feels like a Jot bug ("why didn't it save?") even though the literal interaction is "I pressed the cancel key."

The product question: how do we keep the pill minimal while making the stop affordance discoverable, and how do we make the Escape gesture safer without changing what the user expects it to mean (don't paste this)?

**The answer this spec implements:** two small, complementary changes that ship together.

---

## What ships in this release

Two user-visible changes, bundled as one release:

1. **Pill subtitle showing the stop hotkey.** A small secondary-color line of text appears under the timer in the recording pill, reading e.g. *"⌃⌥Space to stop"*. Populated dynamically from the user's actual binding. Adapts for Push-to-Talk, the cancel states (Transform / Rewrite / Rewrite with Voice's voice-instruction capture), and the unbound case.

2. **Escape panic-save.** Esc during recording still feels like "get me out of this" — no paste, no chime, no celebration. But the audio is now saved to disk as a *draft* recording: a row in Recents with the audio file but an empty transcript. The user can click "Re-transcribe" on it later if they change their mind. Quiet exit; the safety net only matters if the user decides they want it.

Both ship together. The subtitle reduces how often a user hits Esc by mistake; the panic-save makes the rare-but-painful mistake recoverable.

---

## User journeys

### 1. Forgot the hotkey → reads the pill → stops

Maya bound Toggle Recording to ⌃⌥Space a month ago when she set Jot up. She uses Jot maybe twice a week. She presses her trigger (she remembered the start gesture — it's the one she uses; the stop one is the same key, but in the middle of a thought she's not sure). She speaks her two sentences. Now she wants to stop.

She glances at the notch. The pill is open. Under the timer she sees, in a quiet secondary-color font: *"⌃⌥Space to stop"*. She presses it, the recording ends, the transcript pastes at her cursor. Total cognitive load: zero. She didn't have to open Settings, didn't have to guess, didn't have to hit Esc.

### 2. Panic-Esc → finds draft in Recents → re-transcribes

Devon is mid-dictation. Forty seconds in he wants to stop. The hotkey escapes him. He sees the pill but the secondary text doesn't register in the moment — he reflexively hits Esc.

The pill collapses silently. No chime. No success toast. The cursor sits where it was; nothing pastes. Devon assumes the recording is lost — he half-mutters a curse — and gets back to what he was doing.

Twenty minutes later he opens Jot to start a different recording. The Recents list at the top shows his recent dictations. At the top, dated *just now*, is a row: title says *"Draft"*, the preview line says *"(empty transcript)"*, the duration says *0:40*. The waveform sparkline thumbnail is visible — there really is audio there.

He right-clicks. A menu: Re-transcribe, Reveal in Finder, Delete. He clicks Re-transcribe. Twenty seconds later the row's title updates to the first words of his transcript, the preview line fills in, and the row looks like every other Recents row. He can copy it with the existing Copy button, or click into the detail view to see the full text. The recording he thought he lost is back.

### 3. User actually wanted to throw the recording away

Sam is dictating, realizes mid-sentence the recording isn't worth keeping (cat jumped on the keyboard, dog barked, whatever). Sam hits Esc. Pill collapses silently — exactly what they wanted. Sam goes back to work.

A draft row sits in Recents. Sam never looks at Recents that day. The next time Sam opens Recents (a day later) the draft is there, takes one row of space. Sam right-clicks → Delete. Done. Or Sam ignores it — Jot's retention policy will eventually sweep it.

The point: the safety net is *cheap* for the user who didn't want it. One extra row in a list they were probably going to ignore. Drafts behave exactly like real recordings for the delete flow, which Sam already knows.

### 4. Push-to-Talk user

Jules uses Push-to-Talk instead of Toggle Recording. They've bound PTT to the right Option key. They press and hold; the pill opens; the subtitle reads *"Release ⌥ to stop"* (or however the right-Option key renders). They release. Recording ends. The text adapts to the gesture model — *hold/release*, not *press once*.

### 5. Voice-instruction capture for Rewrite with Voice

Pat triggers Rewrite with Voice on a selected paragraph. The pill opens for the voice-instruction phase (Pat is about to say "make it more formal"). The subtitle reads *"Esc to cancel"*. This is the existing semantics for that pill state — Esc cancels the in-flight LLM operation, and there's no audio worth saving (the instruction is a few seconds of speech with no value on its own). The subtitle is honest about what Esc means in *this* state, even though it means something different in the dictation state.

---

## What's behind these changes

### Pill subtitle copy table

The pill subtitle string is fully determined by the current pill state and the user's hotkey bindings.

| Pill state | Subtitle |
|---|---|
| **Recording (Toggle Recording binding set)** | *"<binding> to stop"* — e.g. *"⌃⌥Space to stop"*, *"Caps Lock to stop"* |
| **Recording (Push-to-Talk binding active, PTT was the trigger)** | *"Release <PTT key> to stop"* |
| **Recording (no Toggle binding AND no PTT binding)** | *"Set a hotkey in Settings → Shortcuts"* — see Decision #1 |
| **Transcribing** | (no subtitle — recording is over, the user can't do anything; this state already has its own copy "Transcribing") |
| **Transforming / Cleaning up** | *"Esc to cancel"* |
| **Rewriting** | *"Esc to cancel"* |
| **Voice-instruction capture for Rewrite with Voice** | *"Esc to cancel"* |
| **Success / Notice / Error / Hidden / Hold progress** | (no subtitle — these states linger briefly and have no actionable hotkey) |

The subtitle re-renders dynamically: if the user is recording and rebinds their hotkey in Settings → Shortcuts in another window, the next render uses the new binding. No relaunch.

### Escape panic-save behavior table

Distinguishes Esc semantics by pill state. **Only the dictation row changes.** All other Esc behaviors stay exactly as they are today.

| Pill state when Esc is pressed | Today's behavior | New behavior |
|---|---|---|
| **Recording (dictation)** | Stop capture, discard audio, no row in Recents, play "cancel" chime, pill collapses | Stop capture, **save audio + empty-transcript draft row in Recents**, **no chime**, no paste, pill collapses silently |
| **Transcribing (dictation)** | Cancel transcription, discard transcript | **Unchanged** — there's no audio to re-save (it's still being processed) |
| **Transforming (LLM cleanup after dictation)** | Cancel LLM call, fall back to paste raw transcript | **Unchanged** — this still pastes the raw |
| **Voice-instruction capture for Rewrite with Voice** | Cancel rewrite | **Unchanged** — instruction audio isn't worth saving on its own |
| **Rewriting (any of the Rewrite flows)** | Cancel LLM call | **Unchanged** |

Drafts are recordings with all the normal data **except** the transcript field is empty.

### Draft surface contract

A row in Recents is a "draft" when its transcript is empty. Drafts look almost identical to a regular recording in the list — same icon, same date, same duration, same sparkline waveform thumbnail. Two affordances differ:

- The title is *"Draft"* (instead of the first 40 chars of the transcript).
- The preview line reads *"(empty transcript)"* (the existing placeholder Jot already uses when transcripts are empty — see "Today's safety net" below).

Everything else works:

- The audio plays.
- Right-click → Re-transcribe is the primary action.
- Right-click → Reveal in Finder works.
- Right-click → Delete works (same flow as deleting any recording).
- The ellipsis menu and Copy button (Copy is a no-op for an empty transcript — same as today's behavior for an empty transcript) are unchanged.

After Re-transcribe lands, the row becomes a regular recording: title updates to the first words of the transcript, preview fills in, behavior is identical to a dictation that completed normally.

### Surfaces that filter out drafts

These surfaces deliberately skip drafts so a user who hit Esc doesn't get a stale-looking "last transcript" or a phantom menu-bar entry:

| Surface | Behavior with drafts |
|---|---|
| Menu bar → "Recent Transcriptions" submenu | Skip drafts. Show the next-newest *transcribed* recording. |
| Menu bar → "Copy Last Transcription" | Skip drafts; copy the most recent non-empty transcript. (Drafts have empty transcripts; even without filtering today's `transcript?.isEmpty == false` gate would already skip them — verify in engineering notes.) |
| Paste Last Result hotkey (if bound) | Skip drafts; replay the most recent non-empty transcript. (Same as above — the existing empty-string gate already does this.) |
| Auto-paste on completion | N/A — Esc means no transcription completes, so there's nothing to paste. |
| Donations / "Months saved" math | Drafts have zero seconds counted (they bypass the success path that records the duration). Naturally excluded. |
| Recents list & detail view | **Show drafts.** That's the whole point. |
| Sparkline waveform thumbnail on the Recents row | **Show normally.** Audio exists. |

### Today's safety net for empty transcripts

The Recents row template *already* renders *"(empty transcript)"* as the preview when a recording's transcript is empty (this happens today on rare edge cases — e.g. a transcription that returned only whitespace). So the visual treatment of a draft row reuses an existing pattern; we're not inventing a new states-on-rows concept, just creating drafts deliberately rather than as an edge case.

### What does *not* play / fire on Esc panic-save

- **No success chime.** Esc is not a success.
- **No "cancel" chime either.** The existing `recordingCancel` chime fires today on `.recording → .idle` transitions. Per owner ("keep the Esc experience minimal — no toast, no celebration"), the chime is suppressed when Esc lands on the dictation `.recording` state. The chime still fires for Esc on the *other* cancellable states (Rewrite cancel, etc.) — unchanged.
- **No pasted text.** Esc never pastes.
- **No success pill / toast / notice.** Pill goes hidden, silently.
- **No donation counter increment.** Drafts are not "successful deliveries."
- **No dictation-stats time recorded.** Same reason — `DictationStats.record` is only called on the success path.

The user's experience of pressing Esc is exactly the same as today — silent dismissal. The recovery surface is sitting in Recents if they want it.

### Sub-1-second recordings

Recordings shorter than ~1 second fail the existing transcriber floor check (`PipelineError.audioTooShort`). The recording layer does not deliver a usable `AudioRecording` for sub-second clips. If the user manages to start + Esc within a second, no draft is created — there's no audio to save. This is the desired behavior; no special-case filter is needed.

---

## What's NOT in scope

Things people might assume are part of this release but aren't:

- **Background auto-transcribe of drafts.** Drafts are *on-demand only*: the user explicitly clicks Re-transcribe to get the text. Auto-running FluidAudio on every Esc'd recording would burn ANE time on recordings the user actively wanted to throw away. Future enhancement, not v1.
- **A "long-press Esc to nuke" gesture for hard-discard.** Esc semantics stay simple: stop + save quietly. To discard a draft, right-click → Delete (the existing flow for deleting any recording).
- **Redesigning the pill from scratch.** Subtitle slots into the existing pill chrome under the timer. No new pill states, no expanded layout, no new motion. The expanded streaming-transcript view is unchanged.
- **A draggable / repositionable pill.** Out of scope; the pill stays anchored under the notch.
- **A visible "Draft" badge / colored corner / icon decoration on the row.** The title literally being *"Draft"* and the preview line reading *"(empty transcript)"* is the only visual differentiation. No badge, no chip, no warning iconography. (Decision #4 — recommendation is "no badge.")
- **An undo affordance** ("Undo cancel" toast that converts a draft back to a regular recording). Out of scope. Right-click → Re-transcribe is the recovery.
- **Surfacing the draft in any onboarding / first-run flow.** The first time a user hits Esc and finds their work safe in Recents, the discovery is organic. Not worth a tutorial.
- **Showing the stop hotkey in the menu bar.** The menu bar's "Stop Recording" item is dynamic-text already; it shows the user the action exists, but the user looking at the menu bar isn't the panicked-mid-recording user. Pill subtitle is the right surface.
- **Telemetry on draft creation rate.** No telemetry. We won't know how often this fires; the design assumes the user-facing improvement is the metric of success.
- **Changing the existing v1.x behavior of Esc during *non-recording* cancellable states.** Owner confirmed Transform / Rewrite / Rewrite-with-Voice voice-instruction-capture Esc semantics stay unchanged.

---

## Migration

**None.** The new behavior applies to all users — existing and fresh installs — immediately on upgrade. There's no toggle, no opt-in, no warm-up period.

Existing data is unaffected. No SwiftData schema change is strictly required (drafts are recordings with an empty `transcript`). See `engineering-notes.md` for the discussion of whether to add an explicit `isDraft: Bool` field versus relying on the empty-transcript convention — that's an engineering call with no user-facing impact either way.

The first time an upgraded user hits Esc mid-recording, they'll experience the new behavior. The pill collapses silently exactly as it did before — same gesture, same lack of feedback. If they later browse Recents they'll find a draft row. If they never hit Esc, they never see a draft. The release is invisible to the user until they exercise the panicky-Esc path.

The pill subtitle is visible immediately on the first recording after upgrade. No tutorial. The copy is short enough that it reads quickly without disrupting the dictation flow.

---

## Support implications

New questions users may ask, and the canned answers:

| Question | Answer |
|---|---|
| "Where do I see the stop hotkey?" | "It's under the timer in the recording pill. The line that reads *'<your hotkey> to stop'*. It updates if you rebind in Settings → Shortcuts." |
| "I pressed Escape and I'm seeing a row called 'Draft' in Recents — what is that?" | "Esc during recording now saves the audio so you can change your mind. Right-click → Re-transcribe to transcribe it; right-click → Delete to throw it out." |
| "Why doesn't Esc just throw recordings away anymore?" | "Esc still feels the same in the moment — no paste, no chime, the pill goes away. The change is that the audio is kept as a draft in Recents in case you want it back. To delete a draft, right-click → Delete." |
| "Esc didn't paste anything — is that a bug?" | "No, that's intentional. Esc means 'don't paste this.' If you wanted the paste, your stop hotkey is shown under the timer in the pill." |
| "How long do drafts stick around?" | "Same retention policy as any recording — they're subject to whatever you have configured in Settings → General → Retention." |
| "Can drafts auto-transcribe in the background?" | "Not today. Right-click → Re-transcribe runs it on demand." |
| "The pill subtitle is wrong — it says ⌥Space but I rebound to Caps Lock." | "The subtitle updates from your binding. If it's wrong, check Settings → Shortcuts → Toggle Recording. If the binding looks right but the pill is stale, restart Jot." |
| "I don't have a hotkey bound and the pill says 'Set a hotkey…' — how am I recording right now?" | "You probably started from the menu bar's 'Start Recording' menu item. The pill is correctly telling you there's no global hotkey bound — you can use the menu bar to stop, or bind one in Settings → Shortcuts." |

Release notes should mention: the pill subtitle (one line, framed as "discoverability"); the Esc behavior change (one paragraph, framed as "Esc still feels the same — your audio is now safe in Recents as a draft you can re-transcribe later").

---

## Decisions needed from you

Six open decisions. Each has a recommendation; none are blocking the design — the implementation can land with any of these defaults and the others can be revisited.

### 1. Subtitle copy when no hotkey is bound

The user has no `.toggleRecording` binding and no `.pushToTalk` binding. They started the recording from the menu bar's "Start Recording" item, or from a hotkey we don't know about (extremely unlikely — Jot owns the canonical bindings). What does the subtitle say?

- **Recommended: show the copy.** *"Set a hotkey in Settings → Shortcuts"*. Honest about the state; gives the user a path forward; avoids the empty-subtitle look that might read as a layout bug. Optionally make the text a deep-link button that opens Settings → Shortcuts (engineering-notes flags this as a small bonus).
- **Alternative: hide the subtitle.** Pill renders without a second line for unbound users. Cleaner visually. Worse UX — the user has no way to learn they should bind something.

### 2. Subtitle copy when *both* the Toggle binding and a PTT binding are set

The user has Toggle Recording bound (e.g. ⌃⌥Space) and *also* has Push-to-Talk bound (e.g. right Option). They could have started this recording via either gesture. Which one does the subtitle reference?

- **Recommended: show the binding that *started* this session.** Track which trigger produced the `.recording` state (the dictation flow currently routes both through `RecorderController`, but the hotkey router knows which name fired). PTT → *"Release <key> to stop"*; Toggle → *"<binding> to stop"*.
- **Alternative: always show Toggle's binding.** Simpler. Wrong-feeling for PTT sessions because the user pressed-and-is-holding a key; asking them to *press* a different key is awkward.
- **Alternative: always show whichever appears first in Settings → Shortcuts.** Arbitrary. Worse than the recommended.

The recommended adds a small amount of plumbing — the recorder needs to know which trigger fired — but the engineering cost is small and the UX win is meaningful.

### 3. Should the `recordingCancel` chime ever fire on dictation Esc?

The existing chime is a soft "dismissed" sound that today plays on every dictation cancel. With panic-save, the cancel is *partially successful* — the audio is saved — so the chime arguably misleads (it makes Esc sound like "discarded"). Owner has said "no chime, quiet exit." Recommendation honors that.

- **Recommended: suppress the chime on dictation `.recording → .idle` via Esc.** Quiet exit, matches owner's stated intent.
- **Alternative: keep the chime.** Auditory feedback that *something* happened. But misleads about the save.
- **Alternative: introduce a new "saved-to-drafts" subtle chime.** Adds a new sound to the chime vocabulary. Owner has said no celebration; this contradicts.

### 4. Visual differentiation for draft rows in Recents

How visible is a draft row vs. a normal recording row?

- **Recommended: minimal — title *"Draft"* + preview *"(empty transcript)"*, otherwise identical chrome.** Reuses the existing empty-transcript pattern. No new component, no new chip, no new icon.
- **Alternative: add a small "Draft" chip badge next to the title.** More visible. Adds chrome. Arguably tells the user "this is special" — but the special-ness is invisible to most users (drafts will be rare).
- **Alternative: tint the row icon (the waveform symbol) to a secondary/yellow color.** Visual cue that the row needs attention. Risk of feeling like an error/warning, which it isn't.

The recommendation matches Jot's general restraint. Reconsider if real users report missing the drafts.

### 5. Should drafts have a dedicated SwiftData field (`isDraft: Bool`), or rely on `transcript == ""`?

Engineering-level question with no PM-facing impact in the v1 cut, but worth noting because it affects future work (e.g. distinguishing a "real" empty-transcript edge case from an Esc-saved draft).

- **Recommended: dedicated boolean field.** Slightly more code now; much cleaner semantics later. The "empty transcript means draft" overload conflates two distinct intents (the user pressed Esc vs. the transcriber returned empty). Migration is a one-line property addition with a `false` default for old rows.
- **Alternative: rely on `transcript == ""`.** No schema change. Conflates a rare edge case (transcriber returned empty) with the intended draft semantic. If we later add background auto-transcribe, we want to differentiate "this row is awaiting on-demand retranscription" from "this row tried to transcribe and got nothing."

Either is correct for v1's user-visible behavior. Recommendation is to invest the small effort now.

### 6. Default title — *"Draft"* literally, or include a timestamp?

- **Recommended: *"Draft"*.** Tight, clear. Date is already on the row.
- **Alternatives:** *"Draft from <relative time>"*, *"Untranscribed recording"*. Both are wordier without adding information the row template doesn't already show.

---

## Success criteria

What "done" looks like:

- A user mid-recording sees their actual stop hotkey under the timer, in the secondary-color subtitle text, populated from their current Settings → Shortcuts binding. Re-binding mid-session updates the text without a relaunch.
- A user who hits Esc mid-recording finds the audio saved as a row in Recents next time they look, with title *"Draft"* and a sparkline waveform thumbnail.
- The Esc gesture itself feels exactly like today: no chime, no toast, no pasted text, pill collapses silently.
- A PTT user sees *"Release <key> to stop"* (or whichever trigger fired this session).
- A user in a Transform / Rewrite / voice-instruction-capture pill state sees *"Esc to cancel"*; Esc semantics are unchanged for those states.
- The Menu Bar → "Recent Transcriptions" submenu and "Copy Last Transcription" item skip drafts.
- Re-transcribe on a draft row produces a normal Recents row (title fills in, preview text appears, all subsequent actions work the same).
- Right-click → Delete on a draft works exactly like deleting any other recording.
- Sub-1-second clips don't produce drafts (the recording layer's existing floor handles this; no special-case filter needed).

---

## Risks

- **The pill subtitle adds visual noise.** The pill is currently minimal — adding a second line is a (small) change to a design the team has tuned. Mitigation: the subtitle uses a quieter secondary-color font weight, sits one line below the timer, and only renders when there's actionable hotkey copy. Decision #1's "hide vs show" alternative is a hedge if it feels wrong in practice.
- **Drafts pile up in Recents for users who hit Esc frequently.** If a user is in the habit of starting recordings they don't intend to keep, their list fills with drafts. Mitigation: retention policy applies the same way; right-click → Delete is the same flow they already know. If this turns out to be common, a future Recents filter ("Show drafts: on/off") becomes a follow-up — out of scope for v1.
- **The PTT subtitle copy ("Release <key>") looks weird if the user is using PTT but the binding is exotic** (e.g. a chord rather than a single key — possible if they bound a chord). Mitigation: render whatever the binding label string is; this is the same string Settings → Shortcuts already shows.
- **A user who didn't realize the change reads the subtitle as an error.** *"⌃⌥Space to stop"* could conceivably read as a warning ("you must press this") rather than an informational note. Mitigation: secondary-color, light-weight text; surrounded by the existing pill chrome. Re-evaluate on first real feedback.
- **Re-transcribing a draft uses whatever the *current* primary model is, not the model that was active when the draft was recorded.** If a user recorded under v3 and later switched to JA, re-transcribing produces a JA-language result on English audio. Mitigation: this is the existing Re-transcribe behavior for *any* recording — the draft path reuses it. Documented in `engineering-notes.md` as a non-regression.
- **The Settings → Shortcuts → "binding changed" propagation is observed via UserDefaults change notifications.** The pill subtitle needs to re-render on that observer. If the observer is wired only to a UI tree that's not currently mounted (the pill lives in its own NSPanel), the binding might be stale. Mitigation: route through an existing `@Published` / `@AppStorage` source that both Settings and the pill view model already observe — engineering-notes covers the wiring path. Risk is low because `KeyboardShortcuts` already publishes change notifications.
- **The `recordingCancel` chime suppression on dictation Esc is a partial change** (the chime still fires on other cancel paths). The chime trigger plumbing distinguishes those paths today via the `RecorderController` vs `RewriteController` state subscribers, so the change is scoped to dictation. Risk of accidentally killing the rewrite-cancel chime — covered as an engineering smoke test.

---

Engineering details, file-by-file implementation plan, schema notes, state-machine changes, exhaustive surface audit, and code-level risks live in `engineering-notes.md`.
