import AVFoundation
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                playbackBlock
                transcriptBlock
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .toolbar { toolbarContent }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $recording.title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
            HStack(spacing: 8) {
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(recording.formattedDuration)
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    // MARK: - Playback

    private var playbackBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            WaveformView()
            HStack(spacing: 12) {
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
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
                .disabled(!player.isReady)

                Text("\(format(player.currentTime)) / \(format(player.duration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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
    /// solo-detected or pre-feature. Cached per view-render so the JSON
    /// decode doesn't repeat on every layout pass.
    private var speakerSegments: [SpeakerTimelineSegment]? {
        guard let data = recording.speakerTimeline,
              let payload = try? JSONDecoder().decode(SpeakerTimelinePayload.self, from: data),
              !payload.segments.isEmpty
        else { return nil }
        return payload.segments
    }

    /// Stable palette assigned to speaker labels in order of first appearance.
    /// Keeps each speaker visually consistent without depending on enrollment.
    private func color(for label: String, in segments: [SpeakerTimelineSegment]) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]
        var ordered: [String] = []
        for seg in segments {
            if !ordered.contains(seg.speakerLabel) { ordered.append(seg.speakerLabel) }
        }
        let idx = ordered.firstIndex(of: label) ?? 0
        return palette[idx % palette.count]
    }

    private var transcriptBlock: some View {
        GroupBox {
            ScrollView {
                if let segments = speakerSegments, !showRawTranscript {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(seg.speakerLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(color(for: seg.speakerLabel, in: segments))
                                Text(seg.text)
                                    .font(.system(size: 13, design: .monospaced))
                                    .lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(4)
                } else {
                    Text(displayedTranscript.isEmpty ? "(empty transcript)" : displayedTranscript)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(4)
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
        } label: {
            HStack {
                Text(speakerSegments != nil && !showRawTranscript ? "Transcript (labeled)" : "Transcript")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if hasTransformedTranscript || speakerSegments != nil {
                    Spacer()
                    Toggle(speakerSegments != nil ? "Show plain" : "Show original", isOn: $showRawTranscript)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                }
            }
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
                let result = try await transcriber.transcribeFile(url)
                // Decode audio once for the diarization pass. Done off the
                // main actor since the file read + AVAudioConverter work
                // shouldn't block UI.
                let samples = (try? Self.readMono16kFloat(url: url)) ?? []
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
                    let payload: SpeakerTimelinePayload? = {
                        guard !samples.isEmpty,
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
    private static func readMono16kFloat(url: URL) throws -> [Float] {
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

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
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
