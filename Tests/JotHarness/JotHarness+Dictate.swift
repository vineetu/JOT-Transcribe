@preconcurrency import AVFoundation
import Foundation
@testable import Jot

extension JotHarness {

    /// Drive the toggle hotkey path end-to-end. `audio` is decoded into raw
    /// 16 kHz mono Float32 samples, fed to the stub `AudioCapture`, and
    /// replayed through the live `RecorderController` as if the user had
    /// pressed start, spoken, and pressed stop.
    ///
    /// Spec source: `docs/plans/agentic-testing.md` §0.3.
    func dictate(
        audio: AudioSource,
        autoPaste: Bool = true,
        cleanup: CleanupSeed? = nil
    ) async throws -> DictationResult {
        let testStart = Date()

        // 1. Decode the audio into raw samples and queue the stub
        //    capture. `.file(URL)` decoding lives here, NOT in the
        //    actor stub, so AVFoundation stays out of the
        //    `Tests/JotHarness/Stubs/` actor isolation domain.
        let samples = try Self.decodedSamples(from: audio)
        await stubAudioCapture.enqueue(audio: .samples(samples))

        // 2. Queue a canned transcription result. Phase 1.4 happy-path
        //    contract: stubTranscriber returns "hello world".
        //    Phase 1.5/1.6/1.7 callers can override by enqueuing
        //    different responses before calling `dictate(...)`.
        if await !stubTranscriberHasQueuedResponse() {
            await stubTranscriber.enqueue(asrSeed: StubTranscriber.canned(text: "hello world"))
        }

        // 3. Wire cleanup if the test requested it. For Phase 1.4 the
        //    happy path skips cleanup entirely (LLMConfiguration's
        //    `transformEnabled` defaults to false in a clean
        //    UserDefaults suite, so RecorderController's `runFlow`
        //    does not enter the `.transforming` branch).
        _ = cleanup // Phase 1.5+: enqueue ProviderSeed responses against StubURLProtocol / StubAppleIntelligence.

        // 4. Override `autoPaste` for the run via DeliveryService's
        //    `@AppStorage`-backed property. Even though our ephemeral
        //    UserDefaults suite is isolated from production preferences,
        //    `@AppStorage` reads from `.standard` — so we mutate
        //    `DeliveryService.shared.autoPaste` directly. This is a
        //    test-only writer; production never flips it from outside
        //    Settings.
        services.delivery.autoPaste = autoPaste

        // 5. Drive the toggle pair. The first toggle starts the flow
        //    task and transitions through `.idle → .recording`. We
        //    wait for `.recording` before issuing the second toggle so
        //    the two `toggle()` calls don't race. The second toggle
        //    resumes the flow task's stop continuation, which calls
        //    `pipeline.stopAndTranscribe` (which calls
        //    `stubAudioCapture.stop()`).
        await services.recorder.toggle()
        try await Self.awaitState(services.recorder, isRecording: true, timeout: .seconds(5))
        await services.recorder.toggle()
        try await services.recorder.awaitTerminalState(timeout: .seconds(30))

        // The deliveryBridge's `Task { await delivery.deliver(text) }`
        // is fire-and-forget — `awaitTerminalState` returning when
        // `state == .idle` doesn't guarantee the paste has landed yet.
        // Spin until either the stub pasteboard records the write or
        // we time out.
        try await Self.awaitPasteboardWrite(stubPasteboard, expectedText: services.recorder.lastTranscript ?? "", timeout: .seconds(5))

        // 6. Snapshot the pill state and assemble the result.
        //    `OverlayWindowController` doesn't expose its `PillViewModel`
        //    publicly, and we deliberately did NOT install the overlay panel
        //    in `JotHarness.init` (no AppKit windows during tests). For
        //    Phase 1.4 the dictate happy path's pill state is derivable
        //    from `recorder.state` at terminal — `.idle` after delivery
        //    maps to the success linger, but for harness purposes we
        //    surface `.success(preview:)` directly when the run produced a
        //    transcript, otherwise mirror the recorder's terminal state.
        //    Phase 3 follow-up: thread a public `pillState` accessor onto
        //    `OverlayWindowController` so flow tests can assert against
        //    the production view model directly.
        let pillState = Self.derivePillState(
            recorderState: services.recorder.state,
            transcript: services.recorder.lastTranscript
        )
        let log = await capturingLogSink.entries(since: testStart)

        return DictationResult(
            transcript: services.recorder.lastTranscript ?? "",
            pillState: pillState,
            pasteboardHistory: stubPasteboard.history,
            transformError: nil,
            log: log
        )
    }

    // MARK: - Helpers

    private func stubTranscriberHasQueuedResponse() async -> Bool {
        // The stub doesn't expose its queue depth publicly; rely on
        // the convention that callers either enqueue explicitly or
        // accept the harness's "hello world" default.
        false
    }

    /// Decode an `AudioSource` to raw 16 kHz mono Float32 samples.
    /// `.silence` and `.samples` round-trip through the stub directly;
    /// `.file(URL)` reads + (if needed) resamples the `.wav` to the
    /// canonical AudioFormat via `AVAudioFile` + `AVAudioConverter`.
    /// `Tests/JotHarness/Fixtures/audio/hello-world.wav` is the
    /// shipped happy-path fixture (Phase 1 acceptance §3).
    static func decodedSamples(from source: AudioSource) throws -> [Float] {
        switch source {
        case .samples(let pcm):
            return pcm
        case .silence(let duration):
            let secs = Double(duration.components.seconds) +
                       Double(duration.components.attoseconds) / 1e18
            let count = Int(secs * 16_000)
            return Array(repeating: 0, count: max(count, 0))
        case .file(let url):
            return try decodeFile(url)
        }
    }

    /// Decode a `.wav` URL into raw 16 kHz mono Float32 samples. Fast
    /// path when the file already matches the canonical `AudioFormat`
    /// the live `AudioCapture` writes; otherwise runs a one-shot
    /// `AVAudioConverter` resample. Mirrors `Transcriber.transcribeFile`
    /// so harness tests exercise the same decode shape the production
    /// re-transcribe flow uses.
    private static func decodeFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let inBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: frameCount
        ) else {
            throw HarnessDecodeError.bufferAllocationFailed
        }
        try file.read(into: inBuffer)

        // Fast path: already canonical 16 kHz mono Float32.
        if processingFormat.sampleRate == 16_000,
           processingFormat.channelCount == 1,
           processingFormat.commonFormat == .pcmFormatFloat32,
           !processingFormat.isInterleaved {
            return floats(from: inBuffer)
        }

        // Slow path: one-shot resample via AVAudioConverter.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw HarnessDecodeError.targetFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: processingFormat, to: target) else {
            throw HarnessDecodeError.converterUnavailable
        }
        let ratio = 16_000.0 / processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: outCapacity
        ) else {
            throw HarnessDecodeError.bufferAllocationFailed
        }

        var supplied = false
        var convertError: NSError?
        let status = converter.convert(to: outBuffer, error: &convertError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error, let convertError {
            throw HarnessDecodeError.conversion(convertError)
        }
        return floats(from: outBuffer)
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// Wait until `recorder.state` equals `.recording(...)` (or any
    /// other state matching the predicate). Bounded poll — recorder
    /// settles on `.recording` within a few main-actor hops after the
    /// first `toggle()`.
    static func awaitState(
        _ recorder: RecorderController,
        isRecording: Bool,
        timeout: Duration
    ) async throws {
        if isRecordingState(recorder.state) == isRecording { return }

        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                var iterator = recorder.$state.values.makeAsyncIterator()
                while let next = await iterator.next() {
                    if isRecordingState(next) == isRecording { return true }
                }
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw HarnessTimeoutError.timedOut
            }
            group.cancelAll()
            if !first { throw HarnessTimeoutError.timedOut }
        }
    }

    private static func isRecordingState(_ state: RecorderController.State) -> Bool {
        if case .recording = state { return true }
        return false
    }

    static func awaitPasteboardWrite(
        _ pasteboard: StubPasteboard,
        expectedText: String,
        timeout: Duration
    ) async throws {
        let start = ContinuousClock.now
        let limit = start.advanced(by: timeout)
        while ContinuousClock.now < limit {
            if !expectedText.isEmpty,
               pasteboard.history.contains(where: { $0.text == expectedText }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Don't throw on no-text-yet — caller may not require a paste
        // event (e.g. autoPaste=false). Caller asserts on
        // `pasteboardHistory` directly.
    }
}

// MARK: - Pill state derivation

extension JotHarness {
    /// Map `RecorderController.State` → `PillViewModel.PillState` for the
    /// dictation flow. Production drives this via Combine subscriptions
    /// inside `PillViewModel`, but the harness doesn't install the
    /// overlay (no AppKit window during tests), so we synthesize the
    /// terminal pill state from the recorder's settled state.
    static func derivePillState(
        recorderState: RecorderController.State,
        transcript: String?
    ) -> PillViewModel.PillState {
        switch recorderState {
        case .idle:
            if let preview = transcript, !preview.isEmpty {
                return .success(preview: preview)
            }
            return .hidden
        case .recording(let startedAt):
            return .recording(elapsed: Date().timeIntervalSince(startedAt))
        case .transcribing:
            return .transcribing
        case .transforming:
            return .transforming
        case .error(let msg):
            return .error(message: msg)
        }
    }
}

// MARK: - Errors

enum HarnessDecodeError: Error {
    case bufferAllocationFailed
    case targetFormatUnavailable
    case converterUnavailable
    case conversion(Error)
}
