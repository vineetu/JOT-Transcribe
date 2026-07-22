@preconcurrency import AVFoundation
import AppKit
import Combine
import JotVocabCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// One recording's full face: editable title, waveform strip, scrubber +
/// play/pause, full transcript. Playback is driven by a small main-actor
/// controller so the slider stays in lockstep with `AVAudioPlayer.currentTime`.
struct RecordingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @EnvironmentObject private var diarizerHolder: DiarizerHolder
    /// Recording-detail AI summary service, injected at the window root (same
    /// `.environmentObject` site as `LLMConfiguration`). Owns the LLM deps + the
    /// capable-provider gate, so this view never reaches `AppServices.live` for
    /// the summary path — the fresh-install race that made the button lie is gone
    /// by construction.
    @EnvironmentObject private var summarizer: RecordingSummarizer
    @Bindable var recording: Recording

    @StateObject private var player = AudioPlaybackController()
    @State private var pendingDelete = false
    @State private var isRetranscribing = false
    @State private var retranscribeError: String?
    @State private var showRawTranscript = false
    /// Speaker diarization (design D4): "Detect speakers" in-flight state,
    /// error, and the last non-error status ("Single speaker — nothing to
    /// label.") to show inline near the playback bar.
    @State private var isDetectingSpeakers = false
    @State private var detectSpeakersError: String?
    @State private var detectSpeakersStatus: String?
    /// Per-recording speaker rename (design D5): the label currently being
    /// renamed (`nil` when the rename alert is dismissed) and the draft text.
    @State private var renameTargetLabel: String?
    @State private var renameDraft: String = ""
    /// Edit mode for the canonical transcript. The view is REUSED across
    /// sidebar navigation, so this is reset in `.task(id:)` when the bound
    /// recording changes. Editing binds the `TextEditor` directly to
    /// `$recording.transcript` (no draft buffer) — the model stays the source
    /// of truth, so navigating away or quitting can't drop an in-flight draft.
    @State private var isEditing = false
    /// Briefly flips to `true` right after a successful Copy click so
    /// the toolbar Copy button can swap its glyph to a checkmark — gives
    /// the user the same "did anything happen?" feedback the inline
    /// `CopyTranscriptButton` provides in row contexts.
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    /// WebVTT export (`docs/webvtt-export/design.md`): error surfaced via
    /// the same alert idiom as retranscribe/detect-speakers.
    @State private var exportError: String?
    /// Slice C: the correction-review model. Created lazily on first
    /// `.task(id:)` once the environment `modelContext` is available (a `@State`
    /// initializer can't read `@Environment`), then reloaded whenever the bound
    /// recording changes. `nil` until seeded.
    @State private var reviewModel: CorrectionReviewModel?
    /// Real laid-out content width, measured via `GeometryReader`. Handed to
    /// the transcript view as its EXPLICIT layout width — width is an input,
    /// not something the AppKit text view guesses (see `TranscriptReader`).
    @State private var contentWidth: CGFloat = 0

    /// In-transcript search (find-in-transcript, both panes). `isSearching`
    /// toggles the inline search bar (⌘F); `searchQuery` is the live query;
    /// `searchMatches` are all matches across the CURRENT pane's blocks (plain =
    /// one block, labeled = one per display segment), ordered by (block, position);
    /// `currentMatchIndex` is the active match (⌘G / ⇧⌘G step with wraparound).
    /// State resets on recording change / pane toggle (recompute, keep query).
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var searchMatches: [TranscriptSearch.Match] = []
    @State private var currentMatchIndex = 0
    /// Set true to move first-responder into the `NSSearchField` when the find
    /// bar appears; the field flips it back to false once focused.
    @State private var searchFieldFocusTrigger = false
    /// Captured `ScrollViewReader` proxy so cross-block next/prev can scroll a
    /// (possibly off-screen, lazily-built) speaker block into view before its
    /// NSTextView applies the fine `scrollRangeToVisible`.
    @State private var scrollProxy: ScrollViewProxy?

    /// AI summary (recording-detail "Summarize"). The in-flight state + LLM call
    /// live in the injected `summarizer` (`summarizer.isRunning`); these view
    /// fields hold only the per-recording UI bits: `summaryError` /
    /// `summaryDisabledNotice` surface inline in the section; `activeSummaryKind`
    /// labels the section while running / for Regenerate; `lastCustomInstruction`
    /// lets Regenerate re-run a custom prompt. Text/kind/timestamp persist on
    /// `recording`.
    @State private var summaryError: String?
    @State private var summaryDisabledNotice: String?
    @State private var activeSummaryKind: SummaryKind?
    @State private var lastCustomInstruction: String?
    @State private var showCustomPrompt = false
    @State private var customPromptText = ""
    @State private var didCopySummary = false

    /// Width the transcript reading column occupies: measured content width,
    /// capped at the comfortable reading measure. Falls back to the measure
    /// before the first layout pass reports a width.
    private var transcriptReadingWidth: CGFloat {
        contentWidth > 1 ? min(contentWidth, DetailMetrics.readingMeasure) : DetailMetrics.readingMeasure
    }

    var body: some View {
        // ScrollViewReader so find-in-transcript next/prev can scroll a target
        // speaker block (possibly off-screen in the LazyVStack) into view before
        // its NSTextView applies the fine `scrollRangeToVisible`.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DetailMetrics.blockSpacing) {
                    header
                    TagChipsEditor(recording: recording) { try? context.save() }
                    playbackBlock
                    // Summary sits ABOVE the transcript (the Zoom/Teams recap
                    // placement): it's the read-first derived artifact, the
                    // transcript is the evidence below it — and it appears
                    // right under the header the user triggered it from, so
                    // generation is visible instead of happening off-screen
                    // at the bottom of a long transcript.
                    if shouldShowSummarySection {
                        summarySection
                            .id("summarySection")
                    }
                    transcriptBlock
                    if let reviewModel, !reviewModel.records.isEmpty {
                        CorrectionReviewSection(model: reviewModel)
                    }
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: ContentWidthKey.self, value: g.size.width)
                    }
                )
                .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: DetailMetrics.pageMeasure, alignment: .leading)
            }
            .onAppear { scrollProxy = proxy }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showCustomPrompt) { customPromptSheet }
        .task(id: recording.id) {
            // The detail view is REUSED across sidebar navigation; reset edit
            // mode so a different recording never opens already-in-edit (and
            // never inherits the prior row's edit session). Edits to the prior
            // recording were already written live via the @Bindable binding +
            // autosave, so nothing is lost here.
            isEditing = false
            detectSpeakersStatus = nil
            detectSpeakersError = nil
            // Reset transient summary UI for the new recording (the summary itself
            // is persisted on the model; only the in-flight/notice state is view-local).
            summarizer.cancel()
            summaryError = nil
            summaryDisabledNotice = nil
            activeSummaryKind = nil
            lastCustomInstruction = nil
            // Recompute matches against the new recording's text (keeps the query
            // string, resets the active-match index — design: search state resets
            // on recording change).
            recomputeMatches(resetIndex: true)
            // Seed the review model with the live recording + env context, then
            // reconcile its anchors against the current transcript. Re-runs when
            // the bound recording changes (sidebar navigation), so the section
            // always reflects THIS row's provenance.
            let model = CorrectionReviewModel(recording: recording, modelContext: context)
            reviewModel = model
            await model.reload()
        }
        .onAppear { player.load(url: RecordingStore.audioURL(for: recording)) }
        .onDisappear {
            player.stop()
            // Durability flush: if the view goes away mid-edit (window close,
            // app quit), persist explicitly — autosave alone isn't a guarantee.
            if isEditing {
                try? context.save()
                isEditing = false
            }
        }
        .onChange(of: recording.transcript) { _, _ in
            // Mark as edited on the FIRST hand-edit (gated on `editedAt == nil`
            // so it's a one-time stamp, not a per-keystroke model write). Survives
            // every exit path (Done, nav-away, quit). Re-transcribe runs in read
            // mode (isEditing == false) and clears `editedAt`, so it never trips
            // this — and a later hand-edit re-stamps cleanly.
            if isEditing, recording.editedAt == nil { recording.editedAt = .now }
            recomputeMatches(resetIndex: true)
        }
        .onChange(of: searchQuery) { _, _ in
            recomputeMatches(resetIndex: true)
            scrollToCurrentMatch()
        }
        .onChange(of: showRawTranscript) { _, _ in
            // Pane toggle (plain ↔ labeled / show original): the block set changes,
            // so recompute against the newly displayed text; keep the query.
            recomputeMatches(resetIndex: true)
        }
        .alert(
            "Delete this recording?",
            isPresented: $pendingDelete
        ) {
            Button("Delete", role: .destructive) {
                RecordingStore.delete(recording, from: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio file and transcript will be removed. This cannot be undone.")
        }
        .alert(
            "Re-transcribe failed",
            isPresented: Binding(
                get: { retranscribeError != nil },
                set: { if !$0 { retranscribeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { retranscribeError = nil }
        } message: {
            Text(retranscribeError ?? "")
        }
        .alert(
            "Couldn't detect speakers",
            isPresented: Binding(
                get: { detectSpeakersError != nil },
                set: { if !$0 { detectSpeakersError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { detectSpeakersError = nil }
        } message: {
            Text(detectSpeakersError ?? "")
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .alert(
            "Rename speaker",
            isPresented: Binding(
                get: { renameTargetLabel != nil },
                set: { if !$0 { renameTargetLabel = nil } }
            )
        ) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let old = renameTargetLabel {
                    renameSpeaker(from: old, to: renameDraft)
                }
                renameTargetLabel = nil
            }
            Button("Cancel", role: .cancel) { renameTargetLabel = nil }
        } message: {
            Text("This renames the speaker in this recording only.")
        }
    }

    // MARK: - Header

    /// Friendly model name for the meta row — only shown when the stored raw
    /// identifier maps to a known model (never surface the raw string).
    private var friendlyModelName: String? {
        ParakeetModelID(rawValue: recording.modelIdentifier)?.displayName
    }

    private var header: some View {
        DetailHeader(title: $recording.title) {
            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(recording.formattedDuration)
                    .monospacedDigit()
                if let model = friendlyModelName {
                    Text("·")
                    Text(model)
                }
                // "Never lose audio" safety net
                // (docs/resilient-transcription/design.md): audio saved,
                // transcript still pending — same chip as the list row.
                if recording.pendingSince != nil {
                    Text("·")
                    PendingTranscriptionChip()
                }
            }
        }
    }

    // MARK: - Playback (slim bar; real waveform is a later release)

    private var playbackBlock: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!player.isReady)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.001)
            )
            .controlSize(.small)
            .disabled(!player.isReady)

            Text("\(format(player.currentTime)) / \(format(player.duration))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Transcript

    private var hasTransformedTranscript: Bool {
        recording.transcript != recording.rawTranscript && !recording.rawTranscript.isEmpty
    }

    private var displayedTranscript: String {
        if showRawTranscript { return recording.rawTranscript }
        return recording.transcript
    }

    /// Decoded speaker-labeled segments, or nil when the recording was
    /// solo-detected or pre-feature. **Not** cached: this is a plain
    /// computed property that re-runs `JSONDecoder().decode(...)` on
    /// every access. Callers inside `transcriptBlock` MUST hoist this
    /// into a local once per body evaluation — otherwise SwiftUI's
    /// per-tick body re-renders (e.g. the 10 Hz playback timer) will
    /// decode the payload 4× per render.
    ///
    /// Returns `nil` when the Speaker Labels feature gate is off, even
    /// if a recording from a previous build has a stored timeline —
    /// keeps the plain-transcript path uniform across all recordings
    /// while the feature is held off.
    private var speakerSegments: [SpeakerTimelineSegment]? {
        guard Features.speakerLabels else { return nil }
        guard let data = recording.speakerTimeline,
              let payload = try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: data),
              !payload.segments.isEmpty
        else { return nil }
        return payload.segments
    }

    /// Precomputed `label → Color` map for one render's worth of segments.
    /// Built once per body evaluation (was rebuilt O(N²) per row inside the
    /// previous `color(for:in:)` helper).
    private static func colorMap(for segments: [SpeakerTimelineSegment]) -> [String: Color] {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
        var ordered: [String] = []
        for seg in segments {
            if !ordered.contains(seg.speakerLabel) { ordered.append(seg.speakerLabel) }
        }
        var map: [String: Color] = [:]
        for (idx, label) in ordered.enumerated() {
            map[label] = palette[idx % palette.count]
        }
        return map
    }

    private var transcriptBlock: some View {
        // Decode the timeline once per body evaluation. During playback
        // the 100 ms tick re-renders this view; without the hoist the
        // downstream reads (label text, toggle visibility, ForEach body)
        // each re-decode the JSON payload.
        let segments = speakerSegments
        let colorMap = segments.map { Self.colorMap(for: $0) }
        let useLabeledView = segments != nil && !showRawTranscript

        // Editing applies only to the canonical plain transcript — never the
        // raw view or the (feature-gated) speaker-labeled view.
        let canEdit = !useLabeledView && !showRawTranscript
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(useLabeledView ? "Transcript · labeled" : "Transcript")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if recording.editedAt != nil && !isEditing {
                    Text("· edited")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                // Secondary actions folded into ONE native "More" menu
                // (ellipsis.circle — the Photos/Notes pattern) instead of separate
                // cryptic magnifier + sparkles buttons: Find in Transcript (⌘F) +
                // a context-smart, gate-aware Summarize section. Hidden while
                // editing / on the raw view (search + summarize are out of scope
                // there).
                if (hasTransformedTranscript || segments != nil) && !isEditing {
                    Toggle(segments != nil ? "Show plain" : "Show original", isOn: $showRawTranscript)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                }
                if !isEditing && !showRawTranscript && (!displayedTranscript.isEmpty || segments != nil) {
                    // Bordered like the Edit button beside it so the pair reads
                    // as one control group — a borderless glyph here looked like
                    // a stray mark, not a button.
                    Menu {
                        Button { toggleSearch() } label: {
                            Label("Find in Transcript", systemImage: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        Divider()
                        summaryMenuSection(segments: segments)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(minWidth: 16)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Find and Summarize")
                }
                if canEdit || isEditing {
                    Button(isEditing ? "Done" : "Edit") { toggleEdit() }
                        .controlSize(.small)
                }
            }
            if isSearching && !isEditing && !showRawTranscript {
                findBar
            }
            if isDetectingSpeakers {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Detecting speakers…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if let detectSpeakersStatus {
                Text(detectSpeakersStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            transcriptBody(segments: segments, colorMap: colorMap, useLabeledView: useLabeledView)
                .frame(maxWidth: DetailMetrics.readingMeasure, alignment: .leading)
        }
    }

    @ViewBuilder
    private func transcriptBody(
        segments: [SpeakerTimelineSegment]?,
        colorMap: [String: Color]?,
        useLabeledView: Bool
    ) -> some View {
        if isEditing {
            // Distinct editable surface (design B2): the read-only
            // `TranscriptReader`/`VocabSelectableTextView` is hard-wired
            // non-editable with one-way data flow, so we never retrofit editing
            // onto it. Bind straight to the model so there's no draft to lose.
            TranscriptEditor(text: $recording.transcript)
        } else if useLabeledView, let segments {
            // Render-time run coalescing (belt-and-suspenders over the
            // builder-level pass): old already-persisted payloads still carry
            // dozens of fine-grained per-pause segments — group consecutive
            // same-label segments into one block here so they display
            // correctly without a re-detect. The stored payload (and the VTT
            // export reading it) is untouched.
            let displaySegments = SpeakerTimelineBuilder.coalesceDisplayRuns(segments)
            // LazyVStack (inside the page ScrollView): each block hosts a full
            // TranscriptReader (NSTextView + TextKit + async height measure), so a
            // 50-turn meeting must not build all 50 eagerly. The per-element
            // `blockIndex`/closure capture stays correct under laziness (identity
            // is per ForEach element). Rename menu + vocab popover are unaffected.
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(displaySegments.enumerated()), id: \.offset) { blockIndex, seg in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(seg.speakerLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(colorMap?[seg.speakerLabel] ?? .primary)
                            .contextMenu {
                                Button("Rename speaker…") {
                                    renameDraft = seg.speakerLabel
                                    renameTargetLabel = seg.speakerLabel
                                }
                            }
                            .accessibilityLabel("Speaker: \(seg.speakerLabel). Right-click or long-press to rename.")
                        // Same selectable serif surface + "Add to Vocabulary…"
                        // popover the plain transcript uses (shared `TranscriptReader`
                        // — no duplicated selection/popover machinery). A successful
                        // add rewrites the selected instance in THIS block's stored
                        // segment(s) and the canonical transcript so both views stay
                        // in sync. Still non-editable (no `TranscriptEditor` here).
                        TranscriptReader(
                            text: seg.text,
                            width: transcriptReadingWidth,
                            onReplaceSelection: { range, term in
                                applyVocabReplacementInSpeakerBlock(
                                    blockIndex: blockIndex, range: range, term: term)
                            },
                            highlightRanges: highlightRanges(inBlock: blockIndex),
                            currentHighlight: currentHighlight(inBlock: blockIndex)
                        )
                    }
                    .id(blockIndex)
                }
            }
        } else if displayedTranscript.isEmpty {
            ReadingProse(text: "", placeholder: "(empty transcript)")
        } else if showRawTranscript {
            // Raw/original transcript: still a serif reading surface, just
            // without the inline vocab affordance (we only propose additions
            // off the canonical transcript).
            ReadingProse(text: displayedTranscript)
        } else {
            // Selectable serif transcript. Width is given explicitly (measured
            // by the page); the view reports its own height. Right-click on a
            // selection → "Add to Vocabulary…" mapping popover. On a successful
            // add we also rewrite the selected instance to the canonical term
            // and persist it.
            TranscriptReader(
                text: displayedTranscript,
                width: transcriptReadingWidth,
                onReplaceSelection: { range, term in
                    applyVocabReplacement(range: range, term: term)
                },
                highlightRanges: highlightRanges(inBlock: 0),
                currentHighlight: currentHighlight(inBlock: 0)
            )
        }
    }

    /// Replace the single selected instance in the canonical transcript with
    /// the canonical vocabulary term and persist it. The affordance is only
    /// shown on the canonical transcript path (never the raw view), so this
    /// edits `recording.transcript`. Mutating the bound model + saving the
    /// context flows back through `displayedTranscript` → `TranscriptReader`'s
    /// `text` input, so the reader re-renders to show the change.
    private func applyVocabReplacement(range: NSRange, term: String) {
        let ns = recording.transcript as NSString
        // Guard against a stale range (e.g. the transcript changed underneath
        // us between selection and add): only edit when the range is in bounds.
        guard range.location >= 0,
              range.length > 0,
              range.location + range.length <= ns.length
        else { return }
        let selectedText = ns.substring(with: range)
        // Keep the speaker-labeled view in sync: propagate the SAME single
        // replacement into the stored timeline segment that owns this occurrence,
        // BEFORE mutating the transcript (so the pre-edit transcript is the
        // reference layout the range hint indexes into). If it can't be localized
        // to one stored segment (diverged text / boundary-spanning), the timeline
        // is left untouched and only the plain view updates — acceptable.
        propagateReplacementToTimeline(selectedText: selectedText, term: term, range: range)
        recording.transcript = ns.replacingCharacters(in: range, with: term)
        try? context.save()
    }

    /// Apply a plain-transcript vocab replacement to the stored speaker timeline
    /// too, so both rendering paths show the corrected word. Mutates
    /// `recording.speakerTimeline` in place (the shared `context.save()` in the
    /// caller persists it in the same transaction). No-op when there is no
    /// timeline or the edit can't be localized to a single stored segment.
    private func propagateReplacementToTimeline(selectedText: String, term: String, range: NSRange) {
        guard let data = recording.speakerTimeline,
              let payload = try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: data),
              let updated = SpeakerTimelineTextEdit.applyingReplacement(
                to: payload.segments, selectedText: selectedText, replacement: term,
                range: range, referenceText: recording.transcript),
              let encoded = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: updated))
        else { return }
        recording.speakerTimeline = encoded
    }

    /// "Add to Vocabulary…" invoked from a speaker-labeled block. Applies the
    /// single replacement to the STORED segment(s) that back this display block
    /// (the block is a coalesced run of one-or-more consecutive same-label stored
    /// segments) AND to the canonical plain `recording.transcript`, so both views
    /// stay in sync — then persists both in one save. No-op when it can't be
    /// localized to a single stored segment.
    private func applyVocabReplacementInSpeakerBlock(blockIndex: Int, range: NSRange, term: String) {
        guard let data = recording.speakerTimeline,
              let payload = try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: data)
        else { return }
        let segments = payload.segments
        let displayBlocks = SpeakerTimelineBuilder.coalesceDisplayRuns(segments)
        let groups = SpeakerTimelineTextEdit.displayRunStoredIndices(segments)
        guard blockIndex >= 0, blockIndex < displayBlocks.count, blockIndex < groups.count else { return }

        // The exact string TranscriptReader rendered for this block — the range
        // indexes into it — and the selected substring at that range.
        let blockNS = displayBlocks[blockIndex].text as NSString
        guard range.location >= 0,
              range.length > 0,
              range.location + range.length <= blockNS.length
        else { return }
        let selectedText = blockNS.substring(with: range)

        // Locate the ONE constituent stored segment + local range the selection
        // owns (block text == the constituents' join, so the range is precise).
        let indices = groups[blockIndex]
        let blockStored = indices.map { segments[$0] }
        guard let blockHit = SpeakerTimelineTextEdit.locate(
                range: range, in: blockStored, referenceText: displayBlocks[blockIndex].text)
        else { return }
        let storedIndex = indices[blockHit.segmentIndex]
        let localRange = blockHit.localRange

        // Edit that stored segment's text at the local range and persist the payload.
        let storedNS = segments[storedIndex].text as NSString
        guard localRange.location + localRange.length <= storedNS.length else { return }
        var updated = segments
        updated[storedIndex] = SpeakerTimelineSegment(
            speakerLabel: segments[storedIndex].speakerLabel,
            startSec: segments[storedIndex].startSec,
            endSec: segments[storedIndex].endSec,
            text: storedNS.replacingCharacters(in: localRange, with: term))
        if let encoded = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: updated)) {
            recording.speakerTimeline = encoded
        }

        // Keep the canonical plain transcript in sync on the SAME instance: map
        // (storedIndex, localRange) into transcript coordinates via alignment and
        // splice exactly there — so two speakers sharing a word don't diverge on
        // different occurrences. Only when the transcript has diverged from the
        // stored layout (alignment fails) fall back to the first whole-word match.
        let transcriptNS = recording.transcript as NSString
        if let tRange = SpeakerTimelineTextEdit.transcriptRange(
                forSegmentIndex: storedIndex, localRange: localRange,
                segments: segments, transcript: recording.transcript),
           tRange.location + tRange.length <= transcriptNS.length {
            recording.transcript = transcriptNS.replacingCharacters(in: tRange, with: term)
        } else if let newTranscript = SpeakerTimelineTextEdit.replacingFirstWholeWord(
            selectedText, with: term, in: recording.transcript) {
            recording.transcript = newTranscript
        }
        try? context.save()
    }

    // MARK: - Find in transcript

    /// Safari/Xcode-style find bar: a real `NSSearchField` (authentic rounded
    /// shape, embedded magnifier, built-in clear-x) + "N of M" count + grouped
    /// prev/next in a `ControlGroup` + a bordered Done. Slides in under the header
    /// on a `.bar` material row with a hairline divider. ⌘F toggles, Esc/Done
    /// dismiss + clear, ⌘G / ⇧⌘G step, Enter = next; focus lands in the field on
    /// open. Chrome only — the match/highlight/lazy-scroll logic is unchanged.
    private var findBar: some View {
        HStack(spacing: 10) {
            FindSearchField(
                text: $searchQuery,
                focusTrigger: $searchFieldFocusTrigger,
                onSubmit: { stepMatch(forward: true) },
                onCancel: { dismissSearch() }
            )
            .frame(maxWidth: 280)

            if !searchMatches.isEmpty {
                Text("\(currentMatchIndex + 1) of \(searchMatches.count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if !searchQuery.isEmpty {
                Text("No results")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ControlGroup {
                Button { stepMatch(forward: false) } label: {
                    Image(systemName: "chevron.up")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(searchMatches.isEmpty)
                .help("Previous match (⇧⌘G)")

                Button { stepMatch(forward: true) } label: {
                    Image(systemName: "chevron.down")
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(searchMatches.isEmpty)
                .help("Next match (⌘G)")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()

            Button("Done") { dismissSearch() }
                .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand { dismissSearch() }
    }

    /// The current pane's searchable block texts: plain pane = one block (the
    /// displayed transcript); labeled pane = one block per coalesced display
    /// segment (same order the view renders + the highlight `blockIndex` uses).
    private func currentSearchBlocks() -> [String] {
        let segments = speakerSegments
        let useLabeledView = segments != nil && !showRawTranscript
        if useLabeledView, let segments {
            return SpeakerTimelineBuilder.coalesceDisplayRuns(segments).map(\.text)
        }
        return [displayedTranscript]
    }

    /// The active match's range if it falls in block `blockIndex`, else nil —
    /// handed to that block's `TranscriptReader` as its `currentHighlight`.
    private func currentHighlight(inBlock blockIndex: Int) -> NSRange? {
        guard isSearching, currentMatchIndex < searchMatches.count else { return nil }
        let match = searchMatches[currentMatchIndex]
        return match.blockIndex == blockIndex ? match.range : nil
    }

    /// All match ranges within block `blockIndex` — that block's dim highlights.
    private func highlightRanges(inBlock blockIndex: Int) -> [NSRange] {
        guard isSearching else { return [] }
        return searchMatches.filter { $0.blockIndex == blockIndex }.map(\.range)
    }

    private func recomputeMatches(resetIndex: Bool) {
        guard isSearching else {
            searchMatches = []
            return
        }
        searchMatches = TranscriptSearch.matches(query: searchQuery, in: currentSearchBlocks())
        if resetIndex || currentMatchIndex >= searchMatches.count {
            currentMatchIndex = 0
        }
    }

    private func toggleSearch() {
        if isSearching {
            dismissSearch()
        } else {
            isSearching = true
            recomputeMatches(resetIndex: true)
            // Land focus in the NSSearchField as soon as it appears.
            searchFieldFocusTrigger = true
        }
    }

    private func dismissSearch() {
        isSearching = false
        searchFieldFocusTrigger = false
        searchMatches = []
        currentMatchIndex = 0
        // Query string is retained so re-opening ⌘F restores the last search.
    }

    private func stepMatch(forward: Bool) {
        guard !searchMatches.isEmpty else { return }
        currentMatchIndex = TranscriptSearch.step(
            current: currentMatchIndex, count: searchMatches.count, forward: forward)
        scrollToCurrentMatch()
    }

    /// Scroll the active match into view. In the speaker pane the target block may
    /// be off-screen and NOT YET BUILT (LazyVStack), so we scroll to its block id
    /// FIRST — that materializes the block; its `TranscriptReader` then applies
    /// `currentHighlight` and does the fine `scrollRangeToVisible` when it appears.
    /// In the plain pane the single NSTextView's `scrollRangeToVisible` handles it.
    private func scrollToCurrentMatch() {
        guard isSearching, currentMatchIndex < searchMatches.count else { return }
        let blockIndex = searchMatches[currentMatchIndex].blockIndex
        let segments = speakerSegments
        let useLabeledView = segments != nil && !showRawTranscript
        if useLabeledView {
            scrollProxy?.scrollTo(blockIndex, anchor: .center)
        }
    }

    // MARK: - Summarize

    /// Whether the Summarize action can run — delegated to the injected
    /// `summarizer`, which reads the SAME `LLMConfiguration` Settings writes to,
    /// so the gate can never fall out of sync (and never reaches AppServices.live).
    private var summaryEnabled: Bool { summarizer.isEnabled }

    /// The reason the button is disabled (Apple Intelligence / unconfigured), or nil.
    private var summaryDisabledReason: String? { summarizer.disabledReason }

    private var shouldShowSummarySection: Bool {
        recording.summaryText != nil || summarizer.isRunning || summaryError != nil || summaryDisabledNotice != nil
    }

    private var summarySectionTitle: String {
        let kind = activeSummaryKind ?? recording.summaryKind.flatMap(SummaryKind.init(rawValue:))
        if let kind { return "Summary · \(kind.title)" }
        return "Summary"
    }

    /// The "Summarize" section of the More menu — a native `Section`, context-
    /// smart (meeting actions for ≥2 speakers, else single-note actions), each row
    /// with a `sparkles` icon, then "Custom Prompt…". When the provider gate is
    /// disabled the action rows are disabled and a footer-style disabled row shows
    /// the short reason.
    @ViewBuilder
    private func summaryMenuSection(segments: [SpeakerTimelineSegment]?) -> some View {
        let count = SummaryInput.speakerCount(segments: segments)
        Section("Summarize") {
            if summaryEnabled {
                ForEach(SummaryMenu.actions(speakerCount: count), id: \.self) { kind in
                    Button { runSummary(kind: kind, custom: nil) } label: {
                        Label(kind.title, systemImage: "sparkles")
                    }
                }
                Button {
                    customPromptText = ""
                    showCustomPrompt = true
                } label: {
                    Label("Custom Prompt…", systemImage: "sparkles")
                }
            } else {
                ForEach(SummaryMenu.actions(speakerCount: count), id: \.self) { kind in
                    Button {} label: { Label(kind.title, systemImage: "sparkles") }
                        .disabled(true)
                }
                Button {} label: {
                    Text("Needs a cloud or local AI provider — Settings → AI")
                }
                .disabled(true)
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(summarySectionTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if let at = recording.summaryGeneratedAt, !summarizer.isRunning, recording.summaryText != nil {
                    Text("· \(at.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !summarizer.isRunning, recording.summaryText != nil {
                    Button { copySummary() } label: {
                        Image(systemName: didCopySummary ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Copy summary")
                    Button { regenerateSummary() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .help("Regenerate")
                }
            }

            if summarizer.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Cancel") { cancelSummary() }
                        .controlSize(.small)
                }
            } else if let summaryDisabledNotice {
                Text(summaryDisabledNotice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let summaryError {
                Text(summaryError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let text = recording.summaryText {
                Text(text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: DetailMetrics.readingMeasure, alignment: .leading)
            }
        }
        .frame(maxWidth: DetailMetrics.readingMeasure, alignment: .leading)
    }

    private var customPromptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom summary prompt")
                .font(.system(size: 13, weight: .semibold))
            Text("Describe what to do with this transcript.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("e.g. List the questions I still need to answer", text: $customPromptText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runCustomPrompt() }
            HStack {
                Spacer()
                Button("Cancel") { showCustomPrompt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Run") { runCustomPrompt() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func runCustomPrompt() {
        let instruction = customPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        showCustomPrompt = false
        runSummary(kind: .custom, custom: instruction)
    }

    /// The transcript text fed to the summary model: labeled `"Name: text"` lines
    /// for a diarized recording (so points can be attributed), else the canonical
    /// transcript.
    private func summaryInputText() -> String {
        if let segments = speakerSegments {
            return SummaryInput.labeledTranscript(segments: segments)
        }
        return recording.transcript
    }

    /// Run a summary action. NEVER auto-runs (only explicit menu selection). All
    /// LLM-call construction + the capable-provider gate live in the injected
    /// `summarizer`; this view only supplies the input, records which kind is
    /// active, and — on success — persists the returned text onto the model.
    private func runSummary(kind: SummaryKind, custom: String?) {
        summaryError = nil
        summaryDisabledNotice = nil
        lastCustomInstruction = custom
        activeSummaryKind = kind
        // Teach the section's location: scroll to the in-progress spinner the
        // moment generation starts (next runloop tick, once the section is in
        // the tree). One-shot on user action — never on completion, so a user
        // who scrolls away mid-generation isn't yanked back.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                scrollProxy?.scrollTo("summarySection", anchor: .top)
            }
        }
        summarizer.start(
            kind: kind,
            customInstruction: custom,
            transcriptInput: summaryInputText()
        ) { result in
            switch result {
            case .success(let output):
                recording.summaryText = output.text
                recording.summaryKind = output.kind.rawValue
                recording.summaryGeneratedAt = .now
                try? context.save()
            case .failure(.providerNotCapable(let reason)):
                summaryDisabledNotice = reason
            case .failure(.emptyResult):
                summaryError = "The model returned an empty summary."
            case .failure(.requestFailed(let message)):
                summaryError = message
            }
        }
    }

    private func regenerateSummary() {
        let kind = activeSummaryKind
            ?? recording.summaryKind.flatMap(SummaryKind.init(rawValue:))
            ?? .summary
        runSummary(kind: kind, custom: kind == .custom ? lastCustomInstruction : nil)
    }

    private func cancelSummary() {
        summarizer.cancel()
    }

    private func copySummary() {
        guard let text = recording.summaryText else { return }
        // Mirror `copyTranscript` exactly (the file's copy precedent): prefer the
        // Pasteboarding seam, fall back to `NSPasteboard.general` on the cold-launch
        // race window, and log a failed write.
        let wrote: Bool
        if let pb = AppServices.live?.pasteboard {
            wrote = pb.write(text)
        } else {
            let nspb = NSPasteboard.general
            nspb.clearContents()
            wrote = nspb.setString(text, forType: .string)
        }
        guard wrote else {
            Task { await ErrorLog.shared.warn(
                component: "RecordingDetailView",
                message: "copySummary failed — pasteboard write returned false") }
            return
        }
        didCopySummary = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            didCopySummary = false
        }
    }

    // MARK: - Edit mode

    private func toggleEdit() {
        if isEditing {
            commitEdit()
        } else {
            // Editing operates on the canonical transcript; force the raw view
            // off so we always edit `recording.transcript`.
            showRawTranscript = false
            isEditing = true
        }
    }

    private func commitEdit() {
        isEditing = false
        // Explicit save (not just autosave) so the edit is durable immediately.
        try? context.save()
        // Re-anchor the live correction-review section against the edited text.
        // `CorrectionProvenance.reconciledPayload` is state-based and already
        // accounts for a hand-edit; reload() recomputes the anchors (design B1).
        Task { await reviewModel?.reload() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                copyTranscript()
            } label: {
                Label(
                    didCopy ? "Copied" : "Copy",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
            }
            .help(didCopy ? "Copied" : "Copy transcript")

            Button {
                retranscribe()
            } label: {
                Label("Re-transcribe", systemImage: "arrow.clockwise")
            }
            // Disabled mid-edit: re-transcribe overwrites `transcript`, which
            // would silently clobber the user's in-flight hand edit (and trip
            // the edit-stamp). Editing happens in read→edit mode; re-transcribe
            // is a read-mode action.
            .disabled(isRetranscribing || isEditing)

            if Features.speakerLabels {
                Button {
                    detectSpeakers()
                } label: {
                    if isDetectingSpeakers {
                        Label("Detecting speakers…", systemImage: "person.wave.2")
                    } else {
                        Label("Detect speakers", systemImage: "person.wave.2")
                    }
                }
                .disabled(isDetectingSpeakers || isRetranscribing || isEditing)
                .help("Label who said what in this recording. Runs entirely on this Mac. Best for meeting & call recordings where each person is on clean, separate audio — not audio captured through speakers or a single room mic.")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.audioURL(for: recording)])
            } label: {
                Label("Reveal", systemImage: "folder")
            }

            Button {
                exportWebVTT()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(displayedTranscript.isEmpty)
            .help("Export the transcript as a WebVTT (.vtt) file, with speaker labels if detected.")

            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func retranscribe() {
        guard !isRetranscribing else { return }
        // Mic → re-transcribe guard (mirrors `FileTranscriptionIngest.enqueue`
        // guard 2): on the multilingual Nemotron ship this shares the live
        // streaming engine with dictation, so starting mid-dictation would
        // collide (`TranscriberError.busy` at best, interleaved decoder state
        // at worst). Surfaces the existing re-transcribe alert instead of
        // silently dropping the tap. `shared == nil` (ingest not built yet)
        // falls through — the engine-level busy guard still protects.
        guard FileTranscriptionIngest.shared?.recorderIsCurrentlyIdle ?? true else {
            retranscribeError = "Finish dictating first, then try again."
            return
        }
        let transcriber = transcriberHolder.transcriber
        isRetranscribing = true
        let url = RecordingStore.audioURL(for: recording)
        Task {
            defer { Task { @MainActor in isRetranscribing = false } }
            do {
                // Detail re-transcribe owns the provenance slot: it commits the
                // fresh gate proposals under the SAME recording id below.
                let result = try await transcriber.transcribeFile(url, recordsProvenance: true)
                await MainActor.run {
                    recording.rawTranscript = result.rawText
                    recording.transcript = result.text
                    // Fresh machine output — no longer a hand-edited transcript.
                    recording.editedAt = nil
                    // Re-transcribing invalidates any existing speaker
                    // timeline (design D4/D5): diarization is manual +
                    // on-demand, so we don't re-run it here — just drop the
                    // stale timeline so it can't desync from the new text.
                    // The user re-taps "Detect speakers" if they want labels
                    // on the fresh transcript.
                    recording.speakerTimeline = nil
                    // "Never lose audio" safety net: a filled-in transcript
                    // means this row is no longer pending, whether it got
                    // here via the normal empty-transcript re-transcribe
                    // action or a first-time fill of a pending row adopted
                    // by the failure/orphan paths.
                    recording.pendingSince = nil
                    try? context.save()
                    // F3 (review C2): re-transcribe is the ONLY path that fills
                    // a recovered pending row's transcript, so it must (re)index
                    // for AI/semantic search — the insert-time paths index
                    // (RecordingPersister/FileTranscriptionIngest) but the
                    // empty pending row was skipped, so without this a recovered
                    // recording is invisible to search forever.
                    RecordingIndexer.shared?.index(recordingID: recording.id, text: result.text)
                    // Slice C linkage: a re-transcribe re-runs the gate (which
                    // refilled `pending` via `clearPending` + `record` inside
                    // `transcribe`), so commit the fresh proposals under the SAME
                    // recording id once the new text is saved. `commit` preserves
                    // any existing verdicts/contributions (defensive re-commit),
                    // and the anchor reconcile rebaselines to the new text at the
                    // next review read. Accept stale-row fail-safe (the strict
                    // span resolver drops marks it can't place).
                    let recordingID = recording.id
                    Task {
                        await CorrectionProvenance.shared.commit(transcriptID: recordingID)
                        await reviewModel?.reload()
                    }
                }
            } catch {
                await MainActor.run {
                    retranscribeError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Speaker diarization ("Detect speakers", design D4)

    private func detectSpeakers() {
        guard !isDetectingSpeakers else { return }
        // Mic → detect-speakers guard (mirrors `retranscribe()` above): the
        // segment-sliced pass transcribes each run's audio on the live
        // engine, so starting mid-dictation would collide
        // (`TranscriberError.busy` at best, interleaved decoder state at
        // worst). Surfaces the existing detect-speakers alert instead of
        // silently dropping the tap. `shared == nil` (ingest not built yet)
        // falls through — the engine-level busy guard still protects.
        guard FileTranscriptionIngest.shared?.recorderIsCurrentlyIdle ?? true else {
            detectSpeakersError = "Finish dictating first, then try again."
            return
        }
        isDetectingSpeakers = true
        detectSpeakersError = nil
        detectSpeakersStatus = nil
        let url = RecordingStore.audioURL(for: recording)
        let transcript = recording.transcript
        let holder = diarizerHolder
        // Segment-sliced multi-speaker text (docs/speaker-diarization
        // follow-up): re-detect transcribes each coalesced run's own audio
        // slice on the active engine, so the labeled text is attribution-
        // exact. The recording's PLAIN transcript is deliberately NOT
        // rewritten on this manual path (unlike the import-time pass) — the
        // user may have edited it, and "Detect speakers" shouldn't clobber
        // edits; only the timeline payload is replaced.
        let sliceTranscribe = SegmentSlicing.sliceTranscriber(using: transcriberHolder.transcriber)
        Task {
            defer { Task { @MainActor in isDetectingSpeakers = false } }
            do {
                let outcome = try await DiarizationRunner.run(
                    holder: holder,
                    audioURL: url,
                    transcript: transcript,
                    sliceTranscribe: sliceTranscribe
                )
                await MainActor.run {
                    guard let payload = outcome.payload else {
                        // Solo recording (design D7 dominance gate) — nothing
                        // to label. Clear any stale timeline from a prior run.
                        recording.speakerTimeline = nil
                        detectSpeakersStatus = "Single speaker — nothing to label."
                        try? context.save()
                        return
                    }
                    if let data = try? JSONEncoder().encode(payload) {
                        recording.speakerTimeline = data
                        try? context.save()
                        // Honest scope note (design ask: diarization is only
                        // reliable on clean, separate-audio-per-voice input —
                        // e.g. a meeting/call recording — not audio captured
                        // acoustically through one shared mic/speakers).
                        let speakerCount = Set(payload.segments.map(\.speakerLabel)).count
                        detectSpeakersStatus = "Labeled \(speakerCount) speakers. Best for meeting & call recordings where each person is on clean, separate audio."
                    }
                }
            } catch is CancellationError {
                // View disappeared mid-run — no user-visible error.
            } catch TranscriberError.busy {
                // The sliced pass lost the engine to another transcription
                // (`TranscriberError` has no LocalizedError conformance, so
                // `localizedDescription` would be an unhelpful generic).
                await MainActor.run {
                    detectSpeakersError = "Jot is busy transcribing — try detecting speakers again in a moment."
                }
            } catch {
                await MainActor.run {
                    detectSpeakersError = error.localizedDescription
                }
            }
        }
    }

    /// Per-recording rename (design D5): rewrite every segment currently
    /// carrying `oldLabel` to `newLabel` in THIS recording's timeline only.
    private func renameSpeaker(from oldLabel: String, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldLabel,
              let data = recording.speakerTimeline,
              let payload = try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: data)
        else { return }
        let renamed = payload.segments.map { seg -> SpeakerTimelineSegment in
            guard seg.speakerLabel == oldLabel else { return seg }
            return SpeakerTimelineSegment(
                speakerLabel: trimmed,
                startSec: seg.startSec,
                endSec: seg.endSec,
                text: seg.text
            )
        }
        guard let newData = try? JSONEncoder().encode(SpeakerTimelinePayload(segments: renamed)) else { return }
        recording.speakerTimeline = newData
        try? context.save()
    }

    private func copyTranscript() {
        // Prefer the Pasteboarding seam; fall back to
        // `NSPasteboard.general` when `AppServices.live` is nil so
        // the clipboard still gets the text on the cold-launch race
        // window.
        let wrote: Bool
        if let pb = AppServices.live?.pasteboard {
            wrote = pb.write(displayedTranscript)
        } else {
            let nspb = NSPasteboard.general
            nspb.clearContents()
            wrote = nspb.setString(displayedTranscript, forType: .string)
        }
        guard wrote else {
            Task { await ErrorLog.shared.warn(
                component: "RecordingDetailView",
                message: "copyTranscript failed — pasteboard write returned false"
            ) }
            return
        }
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    // MARK: - WebVTT export (`docs/webvtt-export/design.md`)

    /// Filesystem-sanitized default save-panel filename: strips `/` and
    /// control characters from `recording.title`, falling back to
    /// "transcript" when nothing usable survives.
    private func sanitizedExportFilename() -> String {
        let stripped = recording.title.unicodeScalars
            .filter { $0 != "/" && !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)
        let trimmed = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "transcript" : trimmed
    }

    private func exportWebVTT() {
        // Reuse the same decode `speakerSegments` uses for rendering — don't
        // re-derive the diarized/non-diarized choice differently here.
        let segments = speakerSegments
        let vtt: String
        if let segments, !segments.isEmpty {
            vtt = WebVTTExporter.vtt(segments: segments)
        } else {
            vtt = WebVTTExporter.vtt(fullTranscript: recording.transcript, durationSec: recording.durationSeconds)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vtt") ?? .plainText]
        panel.nameFieldStringValue = "\(sanitizedExportFilename()).vtt"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vtt.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Editable transcript surface, shown only in edit mode. A DISTINCT view from
/// the read-only `TranscriptReader` (design B2): we don't retrofit editing onto
/// the reader's one-way NSTextView. Serif font + line spacing approximate the
/// reader for visual continuity; minor styling drift in edit mode is accepted
/// (design open-Q4). The boxed background also signals "you're editing now."
private struct TranscriptEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: DetailMetrics.serifSize, design: .serif))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 240)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )
            .accessibilityLabel("Edit transcript")
    }
}

/// Thin wrapper around `AVAudioPlayer` that republishes `currentTime` so a
/// SwiftUI `Slider` can ride along. Uses a `CADisplayLink`-style `Timer`
/// because `AVAudioPlayer` doesn't publish time on its own.
@MainActor
final class AudioPlaybackController: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isReady: Bool = false

    private var player: AVAudioPlayer?
    private var tick: Timer?

    func load(url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            isReady = false
            duration = 0
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
            isReady = true
        } catch {
            isReady = false
            duration = 0
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            invalidateTick()
        } else {
            player.play()
            isPlaying = true
            startTick()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        invalidateTick()
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
    }

    private func startTick() {
        invalidateTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    private func invalidateTick() {
        tick?.invalidate()
        tick = nil
    }

    private func update() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying, isPlaying {
            // Natural end-of-track: snap back to zero and stop the tick so the
            // slider returns to the start like the native Music app does.
            isPlaying = false
            currentTime = 0
            invalidateTick()
        }
    }
}
