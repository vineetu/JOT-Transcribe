@preconcurrency import AVFoundation
import AppKit
import Combine
import SwiftData
import SwiftUI

/// One recording's full face: editable title, waveform strip, scrubber +
/// play/pause, full transcript. Playback is driven by a small main-actor
/// controller so the slider stays in lockstep with `AVAudioPlayer.currentTime`.
struct RecordingDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transcriberHolder: TranscriberHolder
    @EnvironmentObject private var sortformerHolder: SortformerHolder
    @Bindable var recording: Recording

    @StateObject private var player = AudioPlaybackController()
    @State private var pendingDelete = false
    @State private var isRetranscribing = false
    @State private var retranscribeError: String?
    @State private var showRawTranscript = false
    /// Briefly flips to `true` right after a successful Copy click so
    /// the toolbar Copy button can swap its glyph to a checkmark — gives
    /// the user the same "did anything happen?" feedback the inline
    /// `CopyTranscriptButton` provides in row contexts.
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    /// Slice C: the correction-review model. Created lazily on first
    /// `.task(id:)` once the environment `modelContext` is available (a `@State`
    /// initializer can't read `@Environment`), then reloaded whenever the bound
    /// recording changes. `nil` until seeded.
    @State private var reviewModel: CorrectionReviewModel?
    /// Real laid-out content width, measured via `GeometryReader`. Handed to
    /// the transcript view as its EXPLICIT layout width — width is an input,
    /// not something the AppKit text view guesses (see `TranscriptReader`).
    @State private var contentWidth: CGFloat = 0

    /// Width the transcript reading column occupies: measured content width,
    /// capped at the comfortable reading measure. Falls back to the measure
    /// before the first layout pass reports a width.
    private var transcriptReadingWidth: CGFloat {
        contentWidth > 1 ? min(contentWidth, DetailMetrics.readingMeasure) : DetailMetrics.readingMeasure
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DetailMetrics.blockSpacing) {
                header
                playbackBlock
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
        .frame(maxWidth: .infinity, alignment: .top)
        .toolbar { toolbarContent }
        .task(id: recording.id) {
            // Seed the review model with the live recording + env context, then
            // reconcile its anchors against the current transcript. Re-runs when
            // the bound recording changes (sidebar navigation), so the section
            // always reflects THIS row's provenance.
            let model = CorrectionReviewModel(recording: recording, modelContext: context)
            reviewModel = model
            await model.reload()
        }
        .onAppear { player.load(url: RecordingStore.audioURL(for: recording)) }
        .onDisappear { player.stop() }
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

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(useLabeledView ? "Transcript · labeled" : "Transcript")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if hasTransformedTranscript || segments != nil {
                    Spacer()
                    Toggle(segments != nil ? "Show plain" : "Show original", isOn: $showRawTranscript)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                }
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
        if useLabeledView, let segments {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(seg.speakerLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(colorMap?[seg.speakerLabel] ?? .primary)
                        ReadingProse(text: seg.text)
                    }
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
            // selection → "Add to Vocabulary…" mapping popover.
            TranscriptReader(text: displayedTranscript, width: transcriptReadingWidth)
        }
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
            .disabled(isRetranscribing)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([RecordingStore.audioURL(for: recording)])
            } label: {
                Label("Reveal", systemImage: "folder")
            }

            Button(role: .destructive) {
                pendingDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func retranscribe() {
        guard !isRetranscribing else { return }
        let transcriber = transcriberHolder.transcriber
        isRetranscribing = true
        let url = RecordingStore.audioURL(for: recording)
        Task {
            defer { Task { @MainActor in isRetranscribing = false } }
            do {
                // Detail re-transcribe owns the provenance slot: it commits the
                // fresh gate proposals under the SAME recording id below.
                let result = try await transcriber.transcribeFile(url, recordsProvenance: true)
                // Decode audio off MainActor for the diarization pass.
                // A bare `Task { }` inside an `@MainActor View` inherits
                // MainActor isolation, so wrapping the synchronous read
                // in `Task.detached` is the explicit jump that keeps the
                // AVAudioFile + AVAudioConverter work off the main
                // thread — for a multi-minute recording the resample
                // can stall the UI for hundreds of ms to multi-seconds.
                let samples = await Task.detached(priority: .userInitiated) {
                    (try? Self.readMono16kFloat(url: url)) ?? []
                }.value
                await MainActor.run {
                    recording.rawTranscript = result.rawText
                    recording.transcript = result.text
                    // Best-effort re-diarization. Diarizer is non-Sendable,
                    // so the call has to live entirely on the main actor —
                    // we grabbed `samples` and `result.text` from off-actor
                    // work above. A failure here (solo detection, decode
                    // failure, model unloaded) is silent: the transcript
                    // still updates; the labeled timeline gets cleared so
                    // it doesn't desync with the new transcript.
                    //
                    // Gated on `Features.speakerLabels` so the re-transcribe
                    // path stays consistent with the rest of the UI while
                    // the feature is held off.
                    let payload: SpeakerTimelinePayload? = {
                        guard Features.speakerLabels,
                              !samples.isEmpty,
                              sortformerHolder.state == .loaded,
                              let diarizer = sortformerHolder.currentDiarizer()
                        else { return nil }
                        return try? SpeakerTimelineBuilder.buildTimeline(
                            samples: samples,
                            transcript: result.text,
                            duration: Double(samples.count) / 16_000.0,
                            diarizer: diarizer
                        )
                    }()
                    if let payload, let data = try? JSONEncoder().encode(payload) {
                        recording.speakerTimeline = data
                    } else {
                        recording.speakerTimeline = nil
                    }
                    try? context.save()
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

    /// Decode an audio file to 16 kHz mono Float32 samples. Mirrors
    /// `Transcriber.readMono16kFloat` (kept private there); duplicated as
    /// a static helper so re-transcribe can run Sortformer over the same
    /// PCM buffer without exposing the Transcriber internals.
    /// `nonisolated` so `Task.detached` in `retranscribe()` can call it
    /// off the main actor — the function touches no shared mutable state
    /// (it allocates locals and returns a `[Float]`), so it's safe to
    /// run on any executor.
    nonisolated private static func readMono16kFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        let processingFormat = file.processingFormat

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        if processingFormat.sampleRate == targetFormat.sampleRate,
           processingFormat.channelCount == 1,
           processingFormat.commonFormat == .pcmFormatFloat32,
           !processingFormat.isInterleaved {
            guard let buf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else { return [] }
            try file.read(into: buf)
            return Self.floats(from: buf)
        }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else { return [] }
        try file.read(into: inBuf)
        guard let converter = AVAudioConverter(from: processingFormat, to: targetFormat) else { return [] }
        let outCap = AVAudioFrameCount(Double(frameCount) * targetFormat.sampleRate / processingFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return [] }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if err != nil { return [] }
        return Self.floats(from: outBuf)
    }

    nonisolated private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let ptr = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: frames))
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

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
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
