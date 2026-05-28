# Recording safety — engineering notes

Companion to `design.md`. Holds the file-by-file implementation plan, schema discussion, recorder state machine changes, pill subtitle rendering plumbing, the "doesn't break" audit per surface, and risks. The PM doc is the source of truth for product intent; this doc is the source of truth for *how* it gets wired up.

This work is **deferred** — owner is testing Advanced Mode first. Capture open questions as deferred decisions; don't block on resolving them now.

---

## 1. Current state — cited

### 1.1 Pill anatomy

`Sources/Overlay/PillView.swift:162-225` defines `RecordingContent` — the body of the pill while in `.recording`. Today's HStack layout (`PillView.swift:184-222`):

```
PulsingDot → AmplitudeTrail(56×22) → [streaming text OR wider AmplitudeTrail] → Text(elapsed) → AppLabel("Jot")
```

Pill height is fixed at `pillHeight: 36` (`PillView.swift:26`), corner radius is `height / 2` (a Capsule). Width is one of three constants depending on streaming partial state (`compactPillWidth = 360`, `streamingPillWidth = 480`, `expandedPillWidth = 600`), set by `OverlayWindowController` based on the same conditions the `RecordingContent` uses.

`PillView.swift:228-311` defines `ExpandedRecordingContent` — the tap-to-expand multi-line streaming-transcript view, gated to streaming sessions only (`PillViewModel.swift:64-68`). The subtitle work below applies to the **collapsed** pill body. The expanded view already has its own chrome and doesn't need a subtitle (the user has explicitly expanded it to see streaming text; the stop affordance is the same key).

### 1.2 Pill state model

`Sources/Overlay/PillViewModel.swift:14-41` defines `PillState`:

```swift
enum PillState: Equatable {
    case hidden
    case recording(elapsed: TimeInterval, streamingPartial: String?)
    case transcribing
    case condensing       // Ask Jot voice-input condensation
    case rewriting
    case transforming
    case success(preview: String)
    case notice(message: String)
    case error(message: String)
    case holdProgress(progress: Double)
}
```

The `.recording` case is the only state we add subtitle copy to that includes a *non-Esc* stop affordance. `.transforming` / `.rewriting` / `.condensing` (Ask Jot voice condensation) all show "Esc to cancel" as their subtitle. `.success` / `.notice` / `.error` / `.holdProgress` / `.hidden` get no subtitle.

**Important gap:** `PillState.recording` does not currently encode *which* trigger was active for the session. Decision #2 in the PM doc says the subtitle should reflect the actual trigger (Toggle vs PTT). Adding that requires plumbing — see §3.

The `.condensing` state is Ask Jot's voice-input pipeline, not Rewrite-with-Voice's voice-instruction capture. Rewrite-with-Voice's voice-instruction capture phase uses `RewriteState.recording` (the same `.recording` PillState shape gets mapped from `RewriteController.RewriteState.recording` in `PillViewModel.rewriteStateChanged` — `PillViewModel.swift:299-325`). **This means the pill `.recording` state is ambiguous between "dictation recording" and "voice-instruction recording for Rewrite-with-Voice."** The subtitle copy table in the PM doc distinguishes the two — engineering must too. See §3.2.

### 1.3 RecorderController state machine

`Sources/Recording/RecorderController.swift:24-30` defines `RecorderController.State`:

```swift
enum State: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case transforming
    case error(String)
}
```

The Esc cancel path lands at `RecorderController.cancel()` (`RecorderController.swift:125-155`). Current branches:

```swift
switch state {
case .transforming:
    // cancels the LLM call, falls back to pasting raw
    transformTask?.cancel()
    // ... pasts the pending raw text
    state = .idle
case .recording, .transcribing:
    state = .idle
    if let token {
        await pipeline.cancel(token: token)  // ← this teardown is the problem
    }
case .idle, .error:
    break
}
```

`VoiceInputPipeline.cancel(token:)` (`Sources/Recording/VoiceInputPipeline.swift:282-304`) tears down audio capture with `await capture.cancel()` and ends streaming "with no graceful flush." Crucially it does **not** return the captured `AudioRecording` — the WAV file is left on disk per `AudioCapture.cancel`'s contract (need to verify; see §3.3), but the in-memory samples + duration + URL are discarded.

By contrast `VoiceInputPipeline.stopAndTranscribe(token:)` (`VoiceInputPipeline.swift:216-280`) calls `await capture.stop()` (graceful stop, returns an `AudioRecording`), then runs the transcriber. For draft-save we want the stop-without-transcribe path: graceful stop, persist the recording, skip the transcriber.

### 1.4 Recording / draft schema

`Sources/Library/Recording.swift` is the SwiftData model. Fields: `id`, `createdAt`, `title`, `durationSeconds`, `transcript`, `rawTranscript`, `audioFileName`, `modelIdentifier`, `speakerTimeline`.

No `isDraft` field today. Decision #5 in the PM doc is whether to add one — recommendation is yes. If yes, default `false`, persisted as `Bool` (SwiftData handles the migration of an additive optional/default property automatically).

`Sources/Library/RecordingRowView.swift:100` already renders `recording.transcript.isEmpty ? "(empty transcript)" : recording.transcript` as the preview line. So empty-transcript display already exists — drafts just hit this codepath naturally. The title needs special-casing: today `Recording.defaultTitle(from:)` (`Recording.swift:56-62`) returns *"Untitled recording"* for empty input. For drafts we want *"Draft"* (PM Decision #6).

### 1.5 RecordingPersister wiring

`Sources/Library/RecordingPersister.swift` subscribes to `RecorderController.$lastResult` and writes a `Recording` row when one arrives. Drafts need a different entry point — there is no `lastResult` on the Esc path because no transcription ran.

Two options for persistence:

- **Option A:** Synthesize a `TranscriptionResult` with empty text inside `RecorderController.cancel()`'s new draft branch, then set `lastResult` to fire the existing persister subscriber. Pros: reuses persister. Cons: muddles `lastResult` semantics (it's currently "we have a successful transcript"); the `SoundTriggers` subscriber on `$lastResult` would fire the success chime — wrong.
- **Option B:** Persist drafts directly from a new code path. Add a `RecordingPersister.persistDraft(audio: AudioRecording)` (or similar) that builds a `Recording` with `transcript == ""` and saves it. Trigger from `RecorderController.cancel()` via a publisher / closure. Pros: clean separation, no risk of triggering success chime / paste / donation counter. Cons: a second persistence entry point.

**Selected: Option B.** Synthesizing a `lastResult` would either fire every `$lastResult` subscriber (success chime, paste, donation counter, dictation stats — all wrong for a draft) or require every subscriber to check `if result.text.isEmpty { return }`. The latter is fragile (new subscribers might forget). A dedicated persist path is the cleaner contract.

### 1.6 Hotkey label resolution

`Sources/Recording/Hotkeys/SingleKeyMigration.swift:151-153` exposes `effectiveBindingLabel(for: .toggleRecording)` and similar — returns a human-readable label string like *"⌃⌥Space"* or *"Caps Lock"* or `nil` if unbound. This is the same helper `Sources/AskJot/UserConfigSnapshot.swift:45-49` uses today.

`effectiveBindingLabel` reads `UserDefaults` synchronously. The pill subtitle will need to re-render when bindings change. `HotkeyRouter.applySingleKeys` (`HotkeyRouter.swift:88-94`) already subscribes to `UserDefaults.didChangeNotification` for this. We can either piggyback on that, expose a `@Published` label on a small new helper, or have the pill view model subscribe directly.

Cleanest path: a small `@MainActor` observable, e.g. `ShortcutLabelsStore` (or similar), that exposes `@Published toggleRecordingLabel: String?` and `@Published pushToTalkLabel: String?`, observes `UserDefaults.didChangeNotification` once, and recomputes via `SingleKeyMigration.effectiveBindingLabel(...)`. Pill view model subscribes to it and emits updated state. This also makes the labels available to any future menu-bar or status-display code without duplicating the wiring.

### 1.7 Chimes that fire on Esc

`Sources/Sounds/SoundTriggers.swift:67-88` handles `RecorderController.State` transitions:

```swift
switch (previousState, next) {
case (.recording, .idle):
    player.play(.recordingCancel)   // ← fires today on every Esc-during-recording
case (.recording, .transcribing):
    player.play(.recordingStop)
case (_, .error):
    player.play(.error)
...
}
```

Per PM Decision #3 (recommendation: suppress chime on dictation Esc), we either:

- Distinguish the Esc path from the toggle-to-stop path at the `RecorderController.State` level (add a state, or pipe extra info), and gate `SoundTriggers` to only play `.recordingCancel` when the transition wasn't an Esc. Adds complexity.
- Suppress `.recordingCancel` entirely on dictation. The chime would still fire for `RewriteController.RewriteState.recording → .idle` (the user-aborted-before-transcription case in Rewrite — `SoundTriggers.swift:104-107`).

**Selected: the latter** — drop the `case (.recording, .idle)` branch from `handleTransition`. The chime stays for Rewrite cancel via `handleRewriteTransition`. Owner has stated "quiet exit"; we honor it for dictation. Future re-introduction of a draft-specific chime is a one-line addition.

Verify: removing the dictation `.recording → .idle` chime is correct because **every** path that takes dictation from `.recording → .idle` is one of: user-pressed-Esc-to-cancel (now panic-save), `RecorderController.cancel()` called from another code path (e.g. wizard test step). The latter is rare and a chime there is debatable; removing it is acceptable.

### 1.8 Surfaces that filter on `transcript.isEmpty`

Empirical grep:

- `Sources/MenuBar/JotMenuBarController.swift:119` — `copyLastItem.isEnabled = (transcript?.isEmpty == false)`. **Already filters.** Drafts will arrive at `RecorderController.lastTranscript`? NO — drafts skip `lastTranscript` entirely (the persist path doesn't go through `lastResult`). So `lastTranscript` stays pinned at whatever the last real transcript was. `copyLastItem` and `pasteLast` both already do the right thing for drafts because the draft path simply never updates `lastTranscript`. Verify: confirm that the persist-draft path does NOT write to `recorder.lastTranscript` (it shouldn't — that's the success surface). Bypass entirely.
- `Sources/MenuBar/JotMenuBarController.swift:541-542` — `copyLastTranscription` selector — same `lastTranscript.isEmpty` gate. Already safe.
- `Sources/MenuBar/JotMenuBarController.swift:381-415` — `populateRecentSubmenu()` — fetches the 10 most recent `Recording` rows. **Does not filter empty transcripts today.** Need a filter: skip `r.transcript.isEmpty`. See §5.2.
- `Sources/Delivery/DeliveryService.swift:116-144` — `pasteLast()` — reads `recorder.lastTranscript` and `rewriteController.lastRewrite`. Both stay nil/stale-but-real-text on a draft path (the draft never updates them). Already safe by construction.
- `Sources/Library/RecordingsListView.swift` — the Recents list. Shows drafts (the whole point). No filter needed.

### 1.9 Re-transcribe surface

`Sources/Library/RecordingsListView.swift:283` has a "Re-transcribe" item in the ellipsis menu (`Menu` for the row); the action is `retranscribe(r)` defined at line 353. The full retranscribe function (`RecordingsListView.swift:353-370`) calls `transcriberHolder.transcriber.transcribeFile(url)` against the on-disk WAV and updates `r.rawTranscript` + `r.transcript` + saves.

`Sources/Library/RecordingDetailView.swift:236` has a Re-transcribe button as well (per grep at line 236).

For drafts we reuse this path unchanged. The only consideration: after a successful retranscribe, do we *also* clear `isDraft`? If we add the field, yes — once it has a transcript, it's a real recording. Implementation: in `retranscribe`'s success block, set `r.isDraft = false`.

The context-menu form (`RecordingRowView.swift:62`) also exposes Re-transcribe. Drafts will inherit this.

### 1.10 Help / grounding doc references to cancel

`Sources/Help/Basics/BasicsContent.swift:208-215` is the `cancel-recording` sub-row:

```
"Press Esc to discard without transcribing. Active only while recording so it
 doesn't steal Esc from other apps when you're not dictating."
```

Needs update per PM doc: *"Press Esc to stop the recording and save it to Recents as a draft you can transcribe later. Active only while recording so it doesn't steal Esc from other apps when you're not dictating."*

`Sources/Help/Troubleshooting/TroubleshootingContent.swift:114` mentions "Cancel (Esc) is scoped to in-flight operations and only active while recording, transcribing, or rewriting." This prose is still correct; no edit needed.

`Resources/help-content-base.md:10`:

```
cancel-recording: Esc discards. Active only while recording, never steals Esc when idle.
```

Update to: `cancel-recording: Esc stops recording and saves to Recents as a draft. Active only while recording, never steals Esc when idle.`

`Resources/help-content-base.md:38`:

```
shortcuts: bindings in Settings → Shortcuts. Cancel (Esc) hardcoded.
```

This is generic enough to leave alone. The cancel-recording line above carries the semantic update.

`Sources/AskJot/HelpChatStore.swift` doesn't reference cancel semantics inline (the cancel description is grounded via the bundled `help-content.md`). The grounding-doc rewrite covers Ask Jot automatically. Re-run the budget check (`tools/check-help-doc-budget.swift`) — the new line is slightly longer than the original (~5 more tokens) but well within the 1500-token budget (currently 1015).

---

## 2. Storage / schema changes

| Change | Type | Default | Migration |
|---|---|---|---|
| `Recording.isDraft` | Bool | `false` | SwiftData additive — old rows default to `false`. |
| `Recording.title == "Draft"` for new drafts | Convention | — | Set at persist time. |

No `UserDefaults` keys are added. No `@AppStorage` keys are added. The pill subtitle reads from existing `KeyboardShortcuts` defaults via `SingleKeyMigration.effectiveBindingLabel`.

**Decision deferred:** if Decision #5 settles on "no `isDraft` field, rely on `transcript == ""`" the migration is nil. Implementation-time call.

---

## 3. Implementation plan (phased)

### Phase 1 — Pill subtitle

#### 1a. Surface the active trigger to the pill state

Add an associated value to `PillState.recording` that conveys the subtitle copy directly, OR add it to the `recordingStartedAt` companion data. Two layout options:

**Option PSU-A — Subtitle string in `PillState.recording`.** Encode the resolved subtitle as part of the state:

```swift
case recording(elapsed: TimeInterval, streamingPartial: String?, subtitle: String?)
```

Pros: view stays purely declarative — it renders what state tells it. Cons: state holds presentation strings; `Equatable` keys widen.

**Option PSU-B — Compute subtitle in the view layer from a more semantic state.**

```swift
enum RecordingTrigger { case toggle, pushToTalk, voiceInstruction, unknown }
case recording(elapsed: TimeInterval, streamingPartial: String?, trigger: RecordingTrigger)
```

Then `PillView.RecordingContent` reads a `@EnvironmentObject ShortcutLabelsStore` and renders the right copy per `trigger`. Pros: clean separation, label store reusable. Cons: view layer touches another env object; trigger has to be plumbed through `RecorderController.State` AND `RewriteController.RewriteState`.

**Selected: PSU-B.** Composition reads cleanly and the labels store has other future uses.

#### 1b. Plumb `RecordingTrigger` from the hotkey routing

`HotkeyRouter` knows which name fired:
- `.toggleRecording` and the `.toggleRecording` SingleKey path (lines 235, 376 — chord + single-key) → `.toggle`.
- `.pushToTalk` and PTT SingleKey path (lines 109, 420 — chord + single-key) → `.pushToTalk`.
- The Rewrite-with-Voice voice-instruction capture path → `.voiceInstruction`. This goes through `RewriteController`, which then drives `RewriteState.recording` and the pill maps to `PillState.recording`.
- The wizard test step uses `setToggleRecordingOverride` — for the Test step we don't need a special trigger label; if the override is active, the wizard provides its own copy. (Or fall back to `.toggle` since the user is pressing Toggle.)

`RecorderController` doesn't currently know the trigger — it's called by `HotkeyRouter`. Add a parameter to the recorder's start path. Two options:

- **Option T1 — Push the trigger into `RecorderController.toggle(trigger:)`.** Each call site provides the trigger. The recorder stamps it onto a new `@Published var currentTrigger: RecordingTrigger?` (cleared on `.idle`). `PillViewModel` subscribes to that publisher and includes the trigger in `PillState.recording`.

- **Option T2 — Have `HotkeyRouter` publish the active trigger separately**, and `PillViewModel` zip it with the recorder state. More moving parts.

**Selected: T1.** Minimal surface area. Pseudocode for the change in `RecorderController`:

```swift
@Published private(set) var currentTrigger: RecordingTrigger?

func toggle(trigger: RecordingTrigger = .unknown) async {
    switch state {
    case .idle, .error:
        currentTrigger = trigger
        activeFlowTask = Task { ... await runFlow() }
    case .recording:
        // stop path — trigger stays unchanged; will clear on .idle
        resumeStopContinuation()
    case .transcribing, .transforming:
        break
    }
}

// In runFlow's exit paths and cancel():
//   currentTrigger = nil  // (paired with state = .idle / .error)
```

Update every `HotkeyRouter` call site to pass the right value. PTT key-up calls `toggle()` again — pass `.pushToTalk` consistently.

The Rewrite voice-instruction path is parallel — `RewriteController` needs the same field. Plumb identically:

```swift
@Published private(set) var currentTrigger: RecordingTrigger?
```

Then `PillViewModel` reads both. For the `.recording` mapping, prefer the active source:
- If `recorder.state` is `.recording`, use `recorder.currentTrigger`.
- If `rewriteController.state` is `.recording`, use `.voiceInstruction` regardless of `currentTrigger` (because voice-instruction is the only Rewrite-with-Voice path that hits `.recording`; the fixed-prompt Rewrite skips it entirely per `RewriteController` flow notes).

#### 1c. Labels store

New `Sources/Overlay/ShortcutLabelsStore.swift`:

```swift
@MainActor
final class ShortcutLabelsStore: ObservableObject {
    @Published private(set) var toggleRecordingLabel: String?
    @Published private(set) var pushToTalkLabel: String?
    private var cancellable: AnyCancellable?

    init() {
        refresh()
        cancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        toggleRecordingLabel = SingleKeyMigration.effectiveBindingLabel(for: .toggleRecording)
        pushToTalkLabel      = SingleKeyMigration.effectiveBindingLabel(for: .pushToTalk)
    }
}
```

Inject into the overlay window's environment so `PillView`'s `RecordingContent` reads it via `@EnvironmentObject`. The publisher firing on UserDefaults change updates the pill at the next render — no relaunch needed (mitigates the §1.6 / PM risk).

#### 1d. Render the subtitle in `RecordingContent`

Reshape the existing HStack into a VStack with the existing HStack on top and a new subtitle line below. The pill needs to be slightly taller — measure once, but the change is structural. Two options:

- **Option H1 — Stack inside the existing 36pt pill.** Compress the timer + chrome and add a small (10pt) subtitle line beneath. Pill height grows from 36 to ~48-52pt.
- **Option H2 — Slot the subtitle alongside the timer.** Less invasive height-wise; the subtitle reads in a column next to the timer. Crammed.

**Selected: H1.** A two-line layout reads naturally. Pill height becomes a constant ~48pt. Update `OverlayPlacement` to anchor the new height (it's a single constant, but verify no math is hard-coded on `pillHeight = 36` elsewhere).

Pseudocode for `RecordingContent` body:

```swift
VStack(spacing: 2) {
    HStack(spacing: 10) {
        PulsingDot(...)
        AmplitudeTrail(...).frame(width: 56, height: 22)
        // streaming partial or wider waveform, as today
        Text(formatElapsed(elapsed))
        AppLabel()
    }
    if let subtitleText = resolveSubtitle(trigger: trigger, labels: labels) {
        Text(subtitleText)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
```

`resolveSubtitle(trigger:labels:)`:

```swift
switch trigger {
case .toggle:
    if let lbl = labels.toggleRecordingLabel { return "\(lbl) to stop" }
    return "Set a hotkey in Settings → Shortcuts"
case .pushToTalk:
    if let lbl = labels.pushToTalkLabel { return "Release \(lbl) to stop" }
    return nil  // unlikely state — PTT fired but binding label is nil
case .voiceInstruction:
    return "Esc to cancel"
case .unknown:
    if let lbl = labels.toggleRecordingLabel { return "\(lbl) to stop" }
    return "Set a hotkey in Settings → Shortcuts"
}
```

For `.transforming`, `.rewriting`, `.condensing` PillStates, render the same subtitle line with "Esc to cancel" copy. Add the line to those `Content` views' bodies symmetrically. Skip for `.transcribing`, `.success`, `.notice`, `.error`, `.holdProgress`, `.hidden`.

### Phase 2 — Esc panic-save

#### 2a. Schema

Add `isDraft: Bool` to `Sources/Library/Recording.swift`:

```swift
@Attribute(.unique) var id: UUID
var createdAt: Date
var title: String
var durationSeconds: Double
var transcript: String
var rawTranscript: String
var audioFileName: String
var modelIdentifier: String
var isDraft: Bool = false   // new
var speakerTimeline: Data?
```

SwiftData's default-value migration handles the existing rows. Add an init parameter with a default of `false`.

#### 2b. New stop-and-save pipeline path

`VoiceInputPipeline` needs a third terminal action alongside `stopAndTranscribe` and `cancel`. Add `stopAndKeep(token:)`:

```swift
func stopAndKeep(_ token: Token) async throws -> AudioRecording {
    guard case .recording(let current, _) = phase, current == token else {
        throw PipelineError.tokenStale
    }
    let recording = try await capture.stop()  // graceful — returns AudioRecording
    await endStreamingSession(graceful: false)  // skip streaming flush; no transcript to deliver
    // Keep the WAV on disk (recorder owner). Caller persists.
    invalidateGenerationIfCurrent(token)
    return recording
}
```

Pros over reusing `stopAndTranscribe`: no transcriber run; no `transcribeBusy` race; no `modelMissing` failure path. The capture-stop graceful path returns the same `AudioRecording` shape, including the WAV URL.

Audio-too-short handling: if `capture.stop()` returns sub-1-second audio, `stopAndKeep` should *not* throw `audioTooShort` (that's a transcriber concern). Instead, return the recording and let the caller decide. The caller (RecorderController draft branch) can choose to drop the WAV and skip the draft if `recording.duration < 1.0`. Per PM doc, "sub-1-second clips don't produce drafts" — implement the duration check at the caller.

#### 2c. RecorderController draft branch

In `RecorderController.cancel()`, replace the `.recording, .transcribing` branch:

```swift
case .recording:
    state = .idle
    currentTrigger = nil
    if let token {
        do {
            let recording = try await pipeline.stopAndKeep(token: token)
            // Sub-second floor: silently drop. Recording layer's existing
            // audioTooShort path doesn't apply here (we bypassed the
            // transcriber); enforce the floor at the persist boundary.
            if recording.duration >= 1.0 {
                draftSubject.send(recording)
            } else {
                // Clean up the orphan WAV.
                try? FileManager.default.removeItem(at: recording.fileURL)
            }
        } catch {
            // Fall back to old discard behavior.
            await pipeline.cancel(token: token)
        }
    }
case .transcribing:
    state = .idle
    currentTrigger = nil
    if let token { await pipeline.cancel(token: token) }
```

`draftSubject` is a new `PassthroughSubject<AudioRecording, Never>` on `RecorderController`. The new `RecordingPersister.persistDraft` path subscribes to it.

Note: `recorder.lastTranscript`, `recorder.lastTranscriptAt`, `recorder.lastResult`, `recorder.lastAudioRecording` — none get written on the draft path. This is the right contract; it's what keeps `pasteLast()`, menu-bar copy-last, and the Recent Transcriptions submenu naturally draft-free.

#### 2d. RecordingPersister.persistDraft

```swift
func start() {
    cancellable = recorder.$lastResult
        .compactMap { $0 }
        .sink { [weak self] result in self?.persist(result: result) }

    // New: subscribe to draft publisher.
    draftCancellable = recorder.draftSubject
        .receive(on: DispatchQueue.main)
        .sink { [weak self] audio in self?.persistDraft(audio: audio) }
}

private func persistDraft(audio: AudioRecording) {
    let recording = Recording(
        createdAt: audio.createdAt,
        title: "Draft",
        durationSeconds: audio.duration,
        transcript: "",
        rawTranscript: "",
        audioFileName: audio.fileURL.lastPathComponent,
        modelIdentifier: holder.primaryModelID.rawValue,
        isDraft: true
    )
    context.insert(recording)
    try? context.save()
    // Speaker Labels: skip — no transcript to diarize against.
}
```

Speaker Labels is correctly skipped: the existing path runs Sortformer only inside the success persist, and we're not calling that.

#### 2e. Sound chime suppression

Update `Sources/Sounds/SoundTriggers.swift:handleTransition`:

```swift
switch (previousState, next) {
// REMOVED: case (.recording, .idle): player.play(.recordingCancel)
case (.recording, .transcribing): player.play(.recordingStop)
case (.idle, .recording), (.error, .recording): player.play(.recordingStart)
case (_, .error): player.play(.error)
default: break
}
```

The Rewrite-side handler (`handleRewriteTransition`) is unchanged — the rewrite cancel path still chimes.

Smoke test: trigger Esc during dictation `.recording` → confirm no `.recordingCancel` chime. Trigger Esc during Rewrite `.recording` (voice instruction capture) → confirm `.recordingCancel` still fires.

### Phase 3 — Recents row & menu bar filtering

#### 3a. Row template for drafts

`Sources/Library/RecordingRowView.swift` already handles empty-transcript preview. Title is read from `recording.title`. For drafts, `title` is literally "Draft" at insert time. No row template changes needed (Decision #4 — recommendation is "no badge").

If Decision #4 flips to "add a chip," add a small conditional badge after the title:

```swift
HStack {
    Text(recording.title)
    if recording.isDraft {
        Text("Draft")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
```

But the recommendation is to skip this and rely on the literal title text.

#### 3b. Re-transcribe clears isDraft

In `RecordingsListView.retranscribe(_:)` (`RecordingsListView.swift:353`), inside the `MainActor.run` block that updates `r.transcript`:

```swift
r.rawTranscript = result.rawText
r.transcript = result.text
if r.isDraft && !result.text.isEmpty {
    r.isDraft = false
    if r.title == "Draft" {
        r.title = Recording.defaultTitle(from: result.text)
    }
}
try? context.save()
```

Same logic at `RecordingDetailView.retranscribe` (`Sources/Library/RecordingDetailView.swift:256-311` — verify the exact site).

#### 3c. Menu bar — Recent Transcriptions submenu

`Sources/MenuBar/JotMenuBarController.swift:418` defines `fetchRecentRecordings(limit:)`. Add `transcript != ""` (or `isDraft == false` if the field exists) to the predicate:

```swift
let descriptor = FetchDescriptor<Recording>(
    predicate: #Predicate { $0.transcript != "" },  // OR: !$0.isDraft
    sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
)
descriptor.fetchLimit = limit
```

#### 3d. Menu bar — Copy Last Transcription

Already filters on `recorder.lastTranscript?.isEmpty == false` (`JotMenuBarController.swift:119, 192`). Drafts don't write `lastTranscript`, so this is naturally safe. **Verify** during implementation that the draft persist path does NOT touch `recorder.lastTranscript`. (It shouldn't — `persistDraft` operates on `audio` directly, not on `recorder.lastResult`.)

#### 3e. Paste Last Result

`Sources/Delivery/DeliveryService.swift:116-144` reads `recorder.lastTranscript` + `recorder.lastTranscriptAt`. Same story — drafts don't touch these. Naturally safe.

### Phase 4 — Help / grounding doc updates

#### 4a. Basics content

`Sources/Help/Basics/BasicsContent.swift:213` — update prose:

```swift
prose: "Press Esc to stop the recording and save it to Recents as a draft you can transcribe later. Active only while recording so it doesn't steal Esc from other apps when you're not dictating."
```

The `warning` line about "Esc is hardcoded, not configurable" stays.

#### 4b. Grounding doc

`Resources/help-content-base.md:10` — update:

```
cancel-recording: Esc stops recording and saves to Recents as a draft. Active only while recording, never steals Esc when idle.
```

Run `tools/check-help-doc-budget.swift` after the edit. Budget is 1500 tokens; current is 1015. Net change is < 10 tokens.

#### 4c. Troubleshooting

`Sources/Help/Troubleshooting/TroubleshootingContent.swift:114` — current prose "Cancel (Esc) is scoped to in-flight operations and only active while recording, transcribing, or rewriting" remains accurate. No edit.

### Phase 5 — Tests

#### 5a. DEBUG smoke matrix

- **Subtitle copy resolves correctly per trigger.** Pure-function test on `resolveSubtitle(trigger:labels:)` covering all 4 trigger values × bound/unbound × default/customized labels.
- **`HelpInfraTests.runAll()` still passes** — no Help anchors moved (just prose).
- **Pill height layout doesn't clip.** Run the app, open recording, eyeball the new 48pt pill. The overlay window controller's height was sized for 36; the change needs to propagate.
- **Draft persistence smoke.** Press start → press Esc (>1s recording) → confirm a draft row appears in Recents with title "Draft" and empty preview. Right-click → Re-transcribe → confirm row updates correctly.
- **No chime on dictation Esc.** Listen / inspect logs.
- **`recordingCancel` chime still fires on Rewrite voice cancel.** Same.

#### 5b. Schema migration smoke

- Existing recordings (no `isDraft`) load with `isDraft == false`. SwiftData should handle this; verify on a build that has both pre- and post-schema rows.

---

## 4. The "doesn't break" audit per surface

| Surface | Today's path | Risk on draft | Fix |
|---|---|---|---|
| Menu bar → Recent Transcriptions submenu | Fetches top 10 by `createdAt`. | Drafts would appear in the list. | Filter `transcript != ""` (or `!isDraft`). §3c. |
| Menu bar → Copy Last Transcription | Reads `recorder.lastTranscript`. | Drafts don't update `lastTranscript`. | Naturally safe. Verify draft path doesn't touch it. |
| Paste Last Result hotkey | Reads `recorder.lastTranscript` + `rewriteController.lastRewrite`. | Same as above. | Naturally safe. |
| Auto-paste on completion | Fires via `$lastResult` subscriber. | Drafts skip `$lastResult` entirely. | Naturally safe. |
| Donation reminder counter | `noteSuccessfulDelivery` increments. | Drafts skip the success path. | Naturally safe. |
| Dictation stats time tracker | `noteSuccessfulDelivery` calls `DictationStats.record`. | Same. | Naturally safe. |
| Sparkline thumbnails | Read audio samples on-the-fly. | Audio exists → renders normally. | Intentionally preserved. |
| Recents list + detail | Renders every `Recording`. | Drafts show with title "Draft" + "(empty transcript)". | This is the feature. |
| Re-transcribe action | Reads WAV, calls FluidAudio, updates `transcript`. | Updates work fine; also clear `isDraft` + retitle on success. | §3b. |
| Delete action (right-click → Delete + confirm) | Removes row + audio file. | Same flow for drafts. | No change. |
| Reveal in Finder | Opens WAV in Finder. | WAV exists. | No change. |
| Speaker Labels post-stop diarization | Runs in `RecordingPersister.persist`. | Drafts go through `persistDraft`, not `persist`. | Intentionally skipped. |
| Retention sweep | Deletes rows older than configured threshold. | Drafts age out like any other recording. | Intentionally identical behavior. |
| `lastResult` chime on transcript success | Fires `.transcriptionComplete` on `lastResult`. | Drafts skip `lastResult`. | Naturally safe. |
| `recordingCancel` chime | Fires on `.recording → .idle`. | We're suppressing this for dictation. | §2e. Reapplies to rewrite cancel only. |
| `recordingStop` chime | Fires on `.recording → .transcribing`. | Esc doesn't pass through `.transcribing`. | Doesn't fire on Esc — correct. |
| `recordingStart` chime | Fires on `.idle → .recording`. | Unchanged. | No change. |
| Wizard test step | Uses `setToggleRecordingOverride`. | Override path doesn't reach our cancel logic. | Confirm wizard Esc behavior is unchanged. (Likely fine — the override returns early before recorder.toggle runs.) |
| Sub-1-second recording | Caller drops the WAV via the duration check. | Implementation must verify cleanup. | §2c includes cleanup. |
| Help / Ask Jot grounding text | Inline references to "Esc discards". | Stale copy → confusing answers. | Updated in §4a, §4b. |

---

## 5. Risk register

### R1 — Pill height layout regression

The pill grows from 36pt to ~48pt. `OverlayWindowController` sizes the panel; `OverlayPlacement` positions it under the notch. If any code path hard-codes 36, the pill is clipped or floats wrong.

**Mitigation:** rename `PillView.pillHeight` to a tuple or computed value; grep for `36` callers in the overlay layer; ensure `OverlayPlacement` reads the constant rather than hard-coding.

### R2 — `currentTrigger` plumbing miss

If `RecorderController.toggle(trigger:)` is called from a path that doesn't supply a trigger (defaults to `.unknown`), the subtitle falls back to the Toggle Recording label — correct only when Toggle is what the user pressed. Wizard test step, in-app start buttons, future menu-bar "Start Recording" item: all need to pass the right trigger.

**Mitigation:** make `RecordingTrigger` parameter explicit (no default), force every call site to declare. Compiler catches misses on new call sites.

### R3 — Draft row pollutes the user's mental model of Recents

Power users who hit Esc 10x a day will see 10 drafts pile up. Eventually annoying.

**Mitigation:** out of scope for v1. If feedback shows it's a problem, a Recents filter ("Hide drafts") is a small follow-up. Captured in `docs/backlog.md` as a monitoring item post-ship.

### R4 — UserDefaults binding-change observer racing with pill render

The `ShortcutLabelsStore` observer fires on `UserDefaults.didChangeNotification`. If the user has Settings open in another window and rebinds, the notification fires; the labels store refreshes; the pill view model receives the update.

But `KeyboardShortcuts`'s defaults writes are async, and our test path needs to confirm the observer fires for the right keys.

**Mitigation:** smoke-test the path by binding/unbinding while recording is active. Verify the subtitle text updates within 1 render cycle. If it doesn't, fall back to a `Timer.scheduledTimer(every: 0.5)` refresh during recording — wasteful but functional.

### R5 — Adding `isDraft` to `Recording` triggers a SwiftData migration

SwiftData handles additive optional/default fields without manual migration. But the project has had migration pain before (per CLAUDE.md notes). The `isDraft: Bool = false` default *should* be transparent.

**Mitigation:** test on a build with pre-migration data. If migration fails, the fallback is "no field; rely on `transcript == ""`" — both code paths can be implemented and gated by a feature flag during validation.

### R6 — Re-transcribe success path doesn't reset the title

After re-transcribing a draft, if the user has already manually renamed it, we shouldn't blow over their custom title. The §3b pseudocode checks `if r.title == "Draft"` before overwriting, but a user who renamed to "important client call" and then re-transcribes loses no data — we leave the title alone.

**Mitigation:** documented in §3b. Smoke-test: rename a draft to "foo," re-transcribe, confirm title stays "foo."

### R7 — Speaker Labels feature interaction

`RecordingPersister.persist` (the success path) runs Sortformer post-stop diarization. `persistDraft` skips it. When the user re-transcribes the draft, the diarization doesn't run either (only `persist` triggers it; `retranscribe` only updates the text).

**Mitigation:** acceptable for v1. Diarization on drafts is a future enhancement. Documented as a deferred limitation.

### R8 — The "always show Toggle's label" fallback for `trigger == .unknown`

If a future code path starts a recording without passing a trigger, the subtitle shows the Toggle label. That's misleading for, say, a PTT session.

**Mitigation:** prevent at compile time by making the param non-default (R2).

### R9 — Pill subtitle copy that overflows the 360pt compact width

The subtitle is `lineLimit(1)` with `truncationMode(.tail)`. A user with a long chord description (e.g. `"⌃⌥⇧⌘ + Space"`) on a non-streaming session sees truncation. Fine — they know what they pressed; they can read enough to recognize it.

**Mitigation:** acceptable. The streaming pill is wider; the truncation rare. If reports come in, scale the subtitle font down or use `minimumScaleFactor`.

### R10 — Suppressing the `recordingCancel` chime on dictation kills auditory feedback for the user who did want to discard

Counter-narrative: a user *intentionally* hitting Esc (case 3 in the PM journeys) loses the auditory confirmation they relied on. The chime today is short and unobtrusive — its loss might feel like the app got less responsive.

**Mitigation:** Decision #3 surfaces this trade-off. Owner has explicitly chosen "quiet exit." Re-evaluate based on early feedback.

### R11 — Drafts created during model swap

User has Parakeet v3 as primary; records; Esc'd; switches primary to JA; re-transcribes the draft. Result text is JA-model output of English audio. Garbled.

**Mitigation:** this is the existing Re-transcribe behavior for any recording, not draft-specific. `modelIdentifier` on the row is stamped at *insert* time, not at re-transcribe time. The user picks the model, so this is "user error" by current Jot semantics. Out of scope.

### R12 — The literal title *"Draft"* clashes if a user names a real recording "Draft" by hand

User edits a recording's title to literally "Draft." Then re-transcribes a separate draft. The §3b pseudocode `if r.title == "Draft"` would overwrite, even though that row is the user-renamed one… but it shouldn't — that row's `isDraft` is `false`, and we only reach that branch on `isDraft && !text.isEmpty`. The check is on the row being re-transcribed, not on a different row. No collision.

**Mitigation:** none needed. Recheck on review.

### R13 — Race between Esc and the toggle hotkey

User presses their toggle stop hotkey AND Esc within a few ms. Whichever lands first wins; the other becomes a no-op because the state has already transitioned. Stop wins → normal transcription. Esc wins → draft. Either outcome is acceptable.

**Mitigation:** none needed.

### R14 — Esc in the post-transcription `.transforming` state

The pill is showing "Cleaning up" because the LLM cleanup is running. User hits Esc. Today: cancel the LLM call, paste raw transcript. New behavior: **unchanged** (PM table is explicit). The raw transcript pastes; this is not a draft path.

**Mitigation:** none needed; the cancel branch for `.transforming` is left alone in `RecorderController.cancel()`. Smoke-test confirms.

---

## 6. Open questions for the owner

Six product decisions surfaced in `design.md` §"Decisions needed from you." Two additional engineering-side questions:

1. **Pill height bump from 36 → ~48.** Acceptable visually? See `design.md` Risk "The pill subtitle adds visual noise" and §3.1d.

2. **`isDraft` field vs. `transcript == ""` convention.** PM Decision #5 lists this as a deferred decision with a recommendation to add the field. Confirms with engineering capacity.

Both have working defaults. Neither blocks the design.

---

## 7. Files read

- `/Users/vsriram/code/jot/CLAUDE.md`
- `/Users/vsriram/code/jot/docs/advanced-mode/design.md` (template)
- `/Users/vsriram/code/jot/docs/advanced-mode/engineering-notes.md` (template)
- `/Users/vsriram/code/jot/docs/backlog.md` (skim — confirmed it's the planned-features inventory)
- `/Users/vsriram/code/jot/Sources/Overlay/PillView.swift`
- `/Users/vsriram/code/jot/Sources/Overlay/PillViewModel.swift`
- `/Users/vsriram/code/jot/Sources/Recording/RecorderController.swift`
- `/Users/vsriram/code/jot/Sources/Recording/VoiceInputPipeline.swift` (partial — stop / cancel sections)
- `/Users/vsriram/code/jot/Sources/Recording/AudioRecording.swift`
- `/Users/vsriram/code/jot/Sources/Recording/Hotkeys/HotkeyRouter.swift`
- `/Users/vsriram/code/jot/Sources/Recording/Hotkeys/ShortcutNames.swift`
- `/Users/vsriram/code/jot/Sources/Recording/Hotkeys/SingleKeyMigration.swift`
- `/Users/vsriram/code/jot/Sources/Library/Recording.swift`
- `/Users/vsriram/code/jot/Sources/Library/RecordingsListView.swift`
- `/Users/vsriram/code/jot/Sources/Library/RecordingRowView.swift`
- `/Users/vsriram/code/jot/Sources/Library/RecordingPersister.swift`
- `/Users/vsriram/code/jot/Sources/Library/DictationStats.swift`
- `/Users/vsriram/code/jot/Sources/Delivery/DeliveryService.swift` (pasteLast region)
- `/Users/vsriram/code/jot/Sources/MenuBar/JotMenuBarController.swift` (Recent Transcriptions / Copy Last regions)
- `/Users/vsriram/code/jot/Sources/Sounds/SoundTriggers.swift`
- `/Users/vsriram/code/jot/Sources/Help/Basics/BasicsContent.swift` (cancel-recording sub-row)
- `/Users/vsriram/code/jot/Sources/Help/Troubleshooting/TroubleshootingContent.swift` (cancel mention)
- `/Users/vsriram/code/jot/Sources/AskJot/UserConfigSnapshot.swift` (binding-label usage pattern)
- `/Users/vsriram/code/jot/Resources/help-content-base.md`
- (verified no read of) `Sources/Rewrite/RewriteController.swift` full body — only the state enum was confirmed via grep, and PillViewModel's rewrite-state mapping was read.

## 8. Files NOT read but flagged for verification during implementation

- `Sources/Overlay/OverlayWindowController.swift` and `Sources/Overlay/OverlayPlacement.swift` — pill panel height math; needs to handle the new ~48pt height.
- `Sources/Library/RecordingDetailView.swift` — the existing Re-transcribe surface to confirm; cited only at the symbol level.
- `Sources/Rewrite/RewriteController.swift` — confirm `currentTrigger` plumbing fits the existing state machine.
- `Sources/Recording/AudioCapture.swift` — confirm `capture.cancel()` vs `capture.stop()` cleanup semantics (which one leaves the WAV behind).
- `Sources/Settings/Shortcuts/ShortcutRowView.swift` — confirm no UI expects a specific subtitle behavior that this design would conflict with.
- The setup wizard's Test step (`Sources/SetupWizard/Steps/...`) — confirm the `setToggleRecordingOverride` path doesn't reach `RecorderController.cancel()`.
